import Foundation
import Combine
import TranscriberCore

/// Observable bridge between SwiftUI and the Rust core. Owns the
/// `TranscriberCore` instance, forwards events onto the main thread, and
/// exposes published state the UI binds to. This is the single integration
/// point the UI and audio layers talk to.
@MainActor
final class Engine: ObservableObject {
    // Live state
    @Published var state: SessionState = .idle
    @Published var metrics: MetricsSnapshot?
    @Published var models: [ModelStatus] = []
    @Published var lastError: String = ""
    /// Recent committed intervals (most recent first), for the live feed.
    @Published var liveFeed: [IntervalRecord] = []
    /// Per-model download progress, keyed by model id.
    @Published var modelProgress: [String: ModelStatus] = [:]
    /// Выбранная в UI, но ЕЩЁ НЕ применённая модель. Смена модели требует
    /// перезапуска сессии, поэтому выбор лишь «ставится в очередь», а реальное
    /// применение происходит по кнопке «Применить» (`applyModelRestart`).
    /// `nil` означает «совпадает с активной моделью» (применять нечего).
    @Published var pendingModel: ModelSelection?
    /// Идёт ли сейчас перезапуск из-за смены модели (для блокировки кнопки в UI).
    @Published private(set) var isApplyingModel = false
    /// Долгоживущая rolling-история метрик для sparkline'ов дашборда (#1).
    /// Раньше жила в самой `DashboardView` и сбрасывалась при пересоздании
    /// вью (переоткрытие раздела). Теперь хранится в Engine (переживает
    /// переоткрытие), наполняется в `handle(.metrics)`, капится по `metricHistoryCap`.
    @Published private(set) var metricHistory: [MetricSample] = []
    /// True when the recording pipeline stopped making progress and capture
    /// has been torn down.  This is intentionally sticky until the app is
    /// relaunched: a hidden retry can otherwise lose audio again.
    @Published private(set) var pipelineStalled = false
    @Published private(set) var needsRestart = false
    /// Monotonically increases for activity events, including voice events
    /// that do not commit an interval yet.  Views use it as a query revision.
    @Published private(set) var activityRevision: UInt = 0
    /// Revision for committed intervals only.  The menu-bar activity chart
    /// uses this narrower signal so a voice-activity event cannot trigger a
    /// duplicate SQLite reload before the enclosing interval is committed.
    @Published private(set) var intervalRevision: UInt = 0
    /// Last metric/update timestamps are published so the UI can show the
    /// age of the live stream instead of presenting an old row as current.
    @Published private(set) var lastMetricsAt: Date?
    @Published private(set) var lastMetricAgeS: TimeInterval?
    @Published private(set) var lastLiveUpdateAt: Date?
    /// Кап истории метрик: ~600 сэмплов ≈ 10 мин при частоте событий ~1/с.
    private let metricHistoryCap = 600

    /// Базовый RSS процесса, снятый на старте ДО загрузки модели (якорь для
    /// разбора памяти — категория «приложение/UI/ОС»). 0 = ещё не снят.
    private(set) var bootRssBytes: UInt64 = 0
    /// Мемоизация размера весов модели на диске по её id (диск дёргаем редко).
    private var modelWeightsCache: (id: String, bytes: UInt64)?
    private var memoryBreakdownCache:
        (total: UInt64, baseline: UInt64, weights: UInt64, modelId: String,
         searchLoaded: Bool, text: String)?
    /// Фоновый обход каталога активной модели. UI никогда не запускает этот
    /// рекурсивный обход из body вью или выражения тултипа.
    private var modelWeightsTask: Task<Void, Never>?

    /// Последний завершённый снимок активности за 24 часа. Намеренно не
    /// `@Published`: DayActivity обновляет своё видимое состояние после
    /// запроса, а вновь смонтированная панель сразу использует этот снимок
    /// перед запуском обновления.
    private(set) var cachedActivityWindow: Window24h?

    /// Последний собранный снимок ленты панели меню-бара. Тоже намеренно НЕ
    /// `@Published`: вновь открытая панель сразу показывает прошлый снимок и
    /// не мигает пустотой, пока идёт фоновый запрос хвоста истории.
    private(set) var cachedJournalFeed: [JournalFeedItem]?

    let storagePath: String
    let modelsPath: String

    private var core: TranscriberCore?
    /// Потокобезопасный держатель ядра для realtime-аудиопути (см. `CoreBox`).
    /// `nonisolated let`, чтобы nonisolated `pushFrame` читал его без изоляции
    /// на главном акторе.
    nonisolated let coreBox = CoreBox()
    private var listener: Listener?
    private(set) var config: CoreConfig
    /// Audio capture lifecycle is owned here so the UI only toggles record.
    private let captureFactory: (() -> CaptureControlling)?
    private lazy var capture: CaptureControlling = {
        let capture = captureFactory?() ?? CaptureManager(engine: self)
        if let reporting = capture as? CaptureFailureReporting {
            reporting.failureHandler = { [weak self] error, generation in
                Task { @MainActor [weak self] in
                    self?.captureDidFail(error, generation: generation)
                }
            }
        }
        if let degrading = capture as? CaptureDegradationReporting {
            degrading.degradationHandler = { [weak self] error, generation in
                Task { @MainActor [weak self] in
                    self?.captureDidDegrade(error, generation: generation)
                }
            }
        }
        return capture
    }()
    /// Lifecycle guards prevent overlapping start/stop tasks and make retry
    /// after a failed capture atomic from the UI's perspective.
    private var isStarting = false
    private var coreSessionRunning = false
    /// Держим detached load/start-задачу до её завершения. Stop инвалидирует
    /// поколение, но retry ждёт завершения этой задачи: иначе её устаревший
    /// callback мог бы вызвать `core.stop()` уже для новой сессии.
    private var coreStartTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt = 0
    private var coreStopTask: Task<Void, Never>?
    private var coreStopToken: UInt = 0
    private var activeSessionGeneration: UInt?
    private var activeSessionStartedAt: Date?
    private var watchdogTask: Task<Void, Never>?
    private var lastMetricHeartbeatMono: UInt64?
    private var lastMetricProgressMono: UInt64?
    private var lastMetricSnapshot: MetricsSnapshot?
    private var queueDropWarningCount = 0
    private var queueSaturationStartedMono: UInt64?
    private let watchdogTimeoutS: TimeInterval
    private let watchdogPollS: TimeInterval
    private let clock: () -> Date
    private let monotonicClock: () -> UInt64
    private let watchdogSleep: @Sendable (UInt64) async -> Void
    private var restartApplicationHandler: (() -> Void)?
    private var relaunchApplicationHandler: ((@escaping (Bool) -> Void) -> Void)?
    private var relaunchInFlight = false
    /// Проверка разрешения микрофона. Вынесена за протокол, чтобы TCC-диалог
    /// запрашивался асинхронно (без семафора на главном потоке), а тесты
    /// проходили без реального разрешения.
    private let micPermission: MicPermissionProviding
    private var isRequestingMicPermission = false
    /// Задержка между попытками поднять захват после пробуждения системы.
    private let wakeRetryDelayS: TimeInterval
    private var wakeResumeTask: Task<Void, Never>?

    /// Which sources to capture (wired to Settings by the UI layer).
    ///
    /// `@Published`, потому что тумблеры источников доступны и во время
    /// записи. Набор источников — снимок старта сессии (переустановка tap'ов
    /// посреди сессии теряет аудио), поэтому изменение лишь поднимает
    /// `sourceChangeRequiresRestart`, а UI честно сообщает, что новое значение
    /// применится со следующего старта.
    @Published var captureMic = true { didSet { noteSourceSelectionChanged() } }
    @Published var captureSystem = true { didSet { noteSourceSelectionChanged() } }
    /// Набор источников, с которым реально стартовала активная сессия.
    private var activeCaptureMic = true
    private var activeCaptureSystem = true
    /// Выбранные источники отличаются от источников активной сессии.
    @Published private(set) var sourceChangeRequiresRestart = false
    /// Сессия приостановлена на время сна системы: захват снят, ядро живо.
    @Published private(set) var isSuspendedForSleep = false
    /// Один из источников не поднялся, но запись продолжается на остальных.
    @Published private(set) var captureDegraded = false

    /// The two product channels. macOS captures mic + system audio.
    static let micChannel = "mic"
    static let remoteChannel = "remote"

    /// Боевой каталог данных: реальный `Application Support` плюс одноразовый
    /// перенос со прежнего имени продукта (`Transcriber` → `Chronica`).
    ///
    /// Вынесено в отдельный метод НАМЕРЕННО: это единственное место, которое
    /// трогает пользовательские каталоги, и его вызывает только продовый
    /// `Engine()` без аргументов. Прогоны тестов передают свой `dataRoot` и
    /// поэтому физически не могут переименовать папку с данными пользователя
    /// (см. `EngineDataIsolationTests`).
    static func productionDataRoot() -> SupportFolderMigration.Outcome {
        SupportFolderMigration.prepare(
            inApplicationSupport: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!)
    }

    /// Основной конструктор приложения. Необязательные параметры — внутренние
    /// seams для поведенческих тестов без реального Rust/аудиоустройства.
    ///
    /// - Parameters:
    ///   - dataRoot: каталог данных. `nil` — продовый путь
    ///     (`Engine.productionDataRoot()`: реальный `Application Support` +
    ///     миграция). Заданный каталог используется КАК ЕСТЬ, без миграции.
    ///   - prefs: настройки оболочки. `nil` — продовый `Prefs.shared`
    ///     (`UserDefaults.standard`). Тесты передают изолированный экземпляр.
    init(dataRoot: URL? = nil,
         prefs: Prefs? = nil,
         core: TranscriberCore? = nil,
         captureFactory: (() -> CaptureControlling)? = nil,
         watchdogTimeoutS: TimeInterval = 12,
         watchdogPollS: TimeInterval = 1,
         clock: @escaping () -> Date = Date.init,
         monotonicClock: @escaping () -> UInt64 = {
             DispatchTime.now().uptimeNanoseconds
         },
         watchdogSleep: @escaping @Sendable (UInt64) async -> Void = { ns in
             try? await Task.sleep(nanoseconds: ns)
         },
         restartHandler: (() -> Void)? = nil,
         relaunchHandler: ((@escaping (Bool) -> Void) -> Void)? = nil,
         micPermission: MicPermissionProviding? = nil,
         wakeRetryDelayS: TimeInterval = 1.5) {
        // Каталог данных переехал вместе с именем продукта
        // (`Application Support/Transcriber` → `.../Chronica`). Перенос
        // выполняется ОДИН раз и ДО создания ядра: базы и веса моделей должны
        // лежать по новому пути раньше, чем ядро их откроет. Сбой переноса не
        // фатален — тогда работаем со старой папкой и показываем ошибку.
        //
        // Явный `dataRoot` (тесты) означает «каталог уже выбран»: ни миграции,
        // ни обращения к реальному `Application Support` не происходит.
        let migration = dataRoot.map {
            SupportFolderMigration.Outcome(url: $0, error: nil, moved: false)
        } ?? Engine.productionDataRoot()
        let support = migration.url
        self.storagePath = support.appendingPathComponent("store", isDirectory: true).path
        self.modelsPath = support.appendingPathComponent("Models", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: storagePath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: modelsPath, withIntermediateDirectories: true)
        // Срок хранения расшифровок — настройка оболочки (UserDefaults), но
        // чистит базу само ядро, поэтому значение уезжает в `CoreConfig` уже
        // на старте, до первого `boot()`. `??` с автозамыканием: продовый
        // `Prefs.shared` не создаётся, когда настройки переданы явно.
        self.config = Engine.defaultConfig(
            storagePath: storagePath,
            modelsPath: modelsPath,
            retentionDays: Engine.retentionDays(
                (prefs ?? Prefs.shared).transcriptRetentionDays))
        self.core = core
        self.captureFactory = captureFactory
        self.watchdogTimeoutS = max(0.01, watchdogTimeoutS)
        self.watchdogPollS = max(0.01, watchdogPollS)
        self.clock = clock
        self.monotonicClock = monotonicClock
        self.watchdogSleep = watchdogSleep
        self.restartApplicationHandler = restartHandler
        self.relaunchApplicationHandler = relaunchHandler
        // Production (реальный CaptureManager) всегда идёт через настоящий TCC;
        // прогоны с подменённым захватом — через «доступ есть», чтобы статус
        // разрешения у хоста тестов не влиял на lifecycle-тесты.
        self.micPermission = micPermission
            ?? (captureFactory == nil ? SystemMicPermission() : GrantedMicPermission())
        self.wakeRetryDelayS = max(0.01, wakeRetryDelayS)
        // The realtime sink is attached only after a session has started.
        // Keeping an injected core here must not make pre-session audio look
        // like an active recording.
        if let message = migration.error {
            // Сообщение показывает обычный баннер ошибок: запись при этом
            // возможна, просто данные остались по старому пути.
            lastError = message
            NSLog("Chronica: data folder migration failed: %@", message)
        } else if migration.moved {
            NSLog("Chronica: data folder migrated to %@", support.path)
        }
    }

    /// Подключает действие полного перезапуска приложения. Реализация UI
    /// передаёт сюда `NSWorkspace`, а тесты — простой счётчик вызовов.
    func setRestartApplicationHandler(_ handler: @escaping () -> Void) {
        restartApplicationHandler = handler
    }

    /// Подключает idempotent seam полного перезапуска с подтверждением того,
    /// что новый процесс действительно запущен. При `false` текущий процесс
    /// остаётся на экране и показывает ошибку.
    func setRelaunchApplicationHandler(_ handler: @escaping (@escaping (Bool) -> Void) -> Void) {
        relaunchApplicationHandler = handler
    }

    /// Явное действие восстановления после зависания конвейера. Авто-
    /// перезапуск намеренно не выполняется: пользователь должен видеть, что
    /// запись была остановлена и запускать новый процесс осознанно.
    func restartApplication() {
        guard needsRestart, !relaunchInFlight else { return }
        relaunchInFlight = true
        if let relaunchApplicationHandler {
            relaunchApplicationHandler { [weak self] success in
                Task { @MainActor [weak self] in
                    self?.finishRelaunch(success: success)
                }
            }
        } else if let restartApplicationHandler {
            // Legacy test seam has no result callback; one invocation is still
            // enough to verify idempotence without launching a process.
            restartApplicationHandler()
        } else {
            finishRelaunch(success: false)
        }
    }

    private func finishRelaunch(success: Bool) {
        relaunchInFlight = false
        guard !success else { return }
        lastError = L("error.relaunchFailed")
        state = .error
    }

    // MARK: lifecycle

    func boot() {
        guard core == nil else { return }
        // Базовый RSS ДО загрузки модели — якорь для разбора памяти (категория
        // «приложение/UI/ОС»). Снимаем один раз на старте.
        if bootRssBytes == 0 { bootRssBytes = ProcessMemory.currentRSSBytes() ?? 0 }
        let listener = Listener(engine: self)
        self.listener = listener
        do {
            let core = try TranscriberCore(config: config, listener: listener)
            try core.registerChannel(channel: ChannelSpec(id: Engine.micChannel,
                                                          label: L("channel.mic")))
            try core.registerChannel(channel: ChannelSpec(id: Engine.remoteChannel,
                                                          label: L("channel.system")))
            self.core = core
            refreshModels()
            scheduleModelWeightsScan()
        } catch {
            lastError = Engine.humanMessage(error)
        }
    }

    func loadModelAndStart() {
        guard let core, coreStartTask == nil,
              !isStarting, !coreSessionRunning, !capture.running,
              !needsRestart else { return }
        guard ensureMicPermissionBeforeStart() else { return }
        let mic = captureMic, system = captureSystem
        isStarting = true
        let generation = nextLifecycleGeneration()
        watchdogTask?.cancel()
        watchdogTask = nil
        coreBox.set(nil)
        state = .loading
        let previousStop = coreStopTask
        let task: Task<Void, Never> = Task.detached(priority: .userInitiated) {
            // A retry after a failed capture waits for the previous Rust stop;
            // otherwise load/start could race the old ASR worker teardown.
            _ = await previousStop?.value
            if previousStop != nil {
                await MainActor.run {
                    if self.lifecycleGeneration == generation { self.clearCompletedCoreStop() }
                }
            }
            do {
                let shouldContinue = await MainActor.run {
                    guard generation == self.lifecycleGeneration, self.isStarting else { return false }
                    // The listener token changes only after the previous core
                    // workers have joined. Late callbacks emitted while Stop
                    // was waiting therefore retain the old token.
                    self.listener?.setGeneration(generation)
                    return true
                }
                guard shouldContinue else {
                    await MainActor.run { self.coreStartTask = nil }
                    return
                }
                try core.loadModel()
                try core.start()
                await MainActor.run {
                    self.finishStart(core: core, generation: generation,
                                     captureMic: mic, captureSystem: system)
                }
            } catch {
                await MainActor.run {
                    self.failStart(core: core, generation: generation,
                                   message: Engine.humanMessage(error))
                }
            }
        }
        coreStartTask = task
    }

    /// Гейт разрешения микрофона ДО запуска захвата.
    ///
    /// Раньше разрешение спрашивал сам `MicSource` синхронно (семафор на
    /// главном потоке), поэтому UI полностью замирал на время TCC-диалога.
    /// Теперь: `.authorized` — стартуем сразу; `.notDetermined` — запрашиваем
    /// асинхронно и повторяем старт из completion; `.denied` — честная ошибка
    /// с подсказкой, где выдать доступ.
    private func ensureMicPermissionBeforeStart() -> Bool {
        guard captureMic else { return true }
        switch micPermission.status {
        case .authorized:
            return true
        case .denied:
            lastError = Engine.humanMessage(AudioCaptureError.micPermissionDenied)
            state = .error
            return false
        case .notDetermined:
            guard !isRequestingMicPermission else { return false }
            isRequestingMicPermission = true
            state = .loading
            let generation = lifecycleGeneration
            micPermission.request { [weak self] _ in
                guard let self else { return }
                self.isRequestingMicPermission = false
                // Пользователь мог нажать «Стоп», пока висел диалог TCC.
                guard self.lifecycleGeneration == generation else { return }
                if self.state == .loading { self.state = .idle }
                self.loadModelAndStart()
            }
            return false
        }
    }

    func stop() {
        _ = nextLifecycleGeneration()
        isStarting = false
        isApplyingModel = false
        isSuspendedForSleep = false
        sourceChangeRequiresRestart = false
        captureDegraded = false
        wakeResumeTask?.cancel()
        wakeResumeTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        activeSessionGeneration = nil
        activeSessionStartedAt = nil
        coreBox.set(nil)
        capture.stop()
        if !pipelineStalled {
            lastMetricsAt = nil
            lastMetricAgeS = nil
            lastMetricHeartbeatMono = nil
            lastMetricProgressMono = nil
            lastMetricSnapshot = nil
            queueSaturationStartedMono = nil
            lastLiveUpdateAt = nil
        }
        if pipelineStalled || needsRestart {
            // A stalled pipeline has already been torn down. Do not let a
            // later UI stop action hide the prominent recovery state.
            return
        }
        guard let core else {
            state = .idle
            return
        }

        // If start is still in the detached load/start phase, the stale
        // completion will stop the core once it reaches the MainActor. Calling
        // stop concurrently here can race core.start().
        guard coreSessionRunning || state == .recording || coreStopTask != nil else {
            state = .idle
            return
        }
        coreSessionRunning = false
        state = .stopping
        scheduleCoreStop(core, finalState: .idle)
    }

    /// Advances the generation token used to discard stale detached lifecycle
    /// completions (for example, a start that finishes after Stop was pressed).
    private func nextLifecycleGeneration() -> UInt {
        lifecycleGeneration &+= 1
        return lifecycleGeneration
    }

    /// Completes core.start on MainActor, then starts capture atomically. Any
    /// capture error rolls back both sources and the Rust session.
    private func finishStart(core: TranscriberCore, generation: UInt,
                             captureMic: Bool, captureSystem: Bool) {
        guard generation == lifecycleGeneration, isStarting else {
            coreStartTask = nil
            coreBox.set(nil)
            scheduleCoreStop(core)
            return
        }
        coreSessionRunning = true
        do {
            try capture.start(captureMic: captureMic, captureSystem: captureSystem,
                              generation: generation)
        } catch {
            failStart(core: core, generation: generation,
                      message: L("error.audioPrefix", Engine.humanMessage(error)))
            return
        }
        coreBox.set(core, generation: generation)
        activeSessionGeneration = generation
        activeSessionStartedAt = clock()
        activeCaptureMic = captureMic
        activeCaptureSystem = captureSystem
        sourceChangeRequiresRestart = false
        captureDegraded = false
        isSuspendedForSleep = false
        liveFeed = []
        lastLiveUpdateAt = nil
        activityRevision &+= 1
        intervalRevision &+= 1
        pipelineStalled = false
        queueDropWarningCount = 0
        queueSaturationStartedMono = nil
        lastError = ""
        armWatchdog(generation: generation)
        coreStartTask = nil
        isStarting = false
        state = .recording
    }

    /// Handles load/start or capture failures. The core is always stopped on
    /// the detached worker; stale completions never overwrite a newer UI state.
    private func failStart(core: TranscriberCore, generation: UInt, message: String) {
        capture.stop()
        coreBox.set(nil)
        isSuspendedForSleep = false
        wakeResumeTask?.cancel()
        wakeResumeTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        activeSessionGeneration = nil
        activeSessionStartedAt = nil
        lastMetricsAt = nil
        lastMetricAgeS = nil
        lastMetricHeartbeatMono = nil
        lastMetricProgressMono = nil
        lastMetricSnapshot = nil
        queueSaturationStartedMono = nil
        lastLiveUpdateAt = nil
        coreSessionRunning = false
        coreStartTask = nil
        if generation != lifecycleGeneration {
            scheduleCoreStop(core)
            return
        }
        isStarting = false
        lastError = message
        state = .error
        scheduleCoreStop(core)
    }

    /// The start task calls this only after awaiting the exact stop task it
    /// captured. A token invalidates the old completion callback so it cannot
    /// clear a newer stop task created by a subsequent session.
    private func clearCompletedCoreStop() {
        coreStopTask = nil
        coreStopToken &+= 1
    }

    /// Schedules one idempotent Rust stop and optionally settles the UI state.
    /// Subsequent callers reuse the same task instead of invoking core.stop()
    /// twice (important for retry/stop races).
    private func scheduleCoreStop(_ core: TranscriberCore, finalState: SessionState? = nil) {
        let generation = lifecycleGeneration
        if let existing = coreStopTask {
            if let finalState {
                let token = coreStopToken
                Task { [weak self] in
                    _ = await existing.value
                    guard let self,
                          self.coreStopToken == token,
                          self.lifecycleGeneration == generation else { return }
                    self.state = finalState
                }
            }
            return
        }

        coreStopToken &+= 1
        let token = coreStopToken
        let task: Task<Void, Never> = Task.detached(priority: .userInitiated) {
            _ = try? core.stop()
        }
        coreStopTask = task
        Task { [weak self] in
            _ = await task.value
            guard let self else { return }
            guard self.coreStopToken == token else { return }
            self.coreStopTask = nil
            guard let finalState, self.lifecycleGeneration == generation else { return }
            self.state = finalState
        }
    }

    // MARK: сон / пробуждение системы

    /// Стратегия сна (выбрана осознанно, см. `resumeAfterWake`).
    ///
    /// Перед сном снимаем ТОЛЬКО захват аудио и watchdog: сессия ядра остаётся
    /// живой, поэтому уже накопленный, но ещё не закоммиченный хвост не
    /// теряется, а состояние «идёт запись» сохраняется. Останавливать ядро
    /// нельзя — это потеряло бы текущий интервал; ставить его «на паузу» ядро
    /// не умеет (FFI не расширяем).
    func suspendForSleep() {
        guard !isSuspendedForSleep, !pipelineStalled, !needsRestart,
              state == .recording, activeSessionGeneration != nil else { return }
        isSuspendedForSleep = true
        wakeResumeTask?.cancel()
        wakeResumeTask = nil
        // Watchdog обязан молчать во сне: метрики не идут не из-за зависания.
        watchdogTask?.cancel()
        watchdogTask = nil
        capture.stop()
    }

    /// Пробуждение: ре-арм захвата в ТОМ ЖЕ поколении сессии.
    ///
    /// Аудиоустройства после wake поднимаются не мгновенно, поэтому делаем
    /// несколько попыток с паузой. Если захват так и не встал — честно
    /// перезапускаем сессию целиком (стоп + старт), сохраняя намерение
    /// «идёт запись», вместо «залипшего» состояния «перезапустите приложение».
    func resumeAfterWake() {
        guard isSuspendedForSleep else { return }
        guard !pipelineStalled, !needsRestart, state == .recording,
              let generation = activeSessionGeneration else {
            isSuspendedForSleep = false
            return
        }
        wakeResumeTask?.cancel()
        // Поднимаем ИМЕННО тот набор источников, с которым сессия стартовала:
        // тумблеры, переключённые во время сна, применятся со следующего
        // старта (об этом и говорит `sourceChangeRequiresRestart`).
        let mic = activeCaptureMic, system = activeCaptureSystem
        let delayNs = UInt64(max(0.01, wakeRetryDelayS) * 1_000_000_000)
        let sleep = watchdogSleep
        wakeResumeTask = Task { [weak self] in
            for attempt in 0..<Engine.wakeResumeAttempts {
                if attempt > 0 {
                    await sleep(delayNs)
                    if Task.isCancelled { return }
                }
                guard let self, !Task.isCancelled, self.isSuspendedForSleep,
                      self.activeSessionGeneration == generation else { return }
                do {
                    try self.capture.start(captureMic: mic, captureSystem: system,
                                           generation: generation)
                    self.isSuspendedForSleep = false
                    self.armWatchdog(generation: generation)
                    self.wakeResumeTask = nil
                    return
                } catch {
                    self.lastError = L("error.wakeCapture", Engine.humanMessage(error))
                }
            }
            guard let self, !Task.isCancelled, self.isSuspendedForSleep,
                  self.activeSessionGeneration == generation else { return }
            self.restartSessionAfterFailedWake()
        }
    }

    /// Сколько раз пробуем поднять захват после пробуждения, прежде чем
    /// перезапустить сессию целиком.
    private static let wakeResumeAttempts = 3

    private func restartSessionAfterFailedWake() {
        isSuspendedForSleep = false
        wakeResumeTask = nil
        stop()
        loadModelAndStart()
    }

    /// Есть ли незавершённая работа ядра, которую нужно дождаться перед
    /// выходом (запись, загрузка модели или ещё не доехавшая остановка).
    /// Используется `applicationShouldTerminate`, чтобы не терять хвост.
    var hasPendingCoreWork: Bool {
        coreSessionRunning || isStarting || coreStopTask != nil ||
            state == .recording || state == .loading || state == .stopping
    }

    /// Подсказка для UI о том, что изменённый набор источников ещё не
    /// применён к текущей сессии.
    var sourceChangeHint: String? {
        sourceChangeRequiresRestart ? L("hint.sourceChangeRestart") : nil
    }

    /// Пересчитывает `sourceChangeRequiresRestart` после переключения тумблера.
    private func noteSourceSelectionChanged() {
        let sessionActive = activeSessionGeneration != nil || isStarting
        sourceChangeRequiresRestart = sessionActive &&
            (captureMic != activeCaptureMic || captureSystem != activeCaptureSystem)
    }

    /// Realtime hot path — called by the audio layer with 16k-or-any PCM.
    nonisolated func pushFrame(channel: String, pcm: [Int16], sampleRate: UInt32,
                               channels: UInt8, generation: UInt? = nil) {
        coreBox.pushFrame(channel: channel, pcm: pcm, sampleRate: sampleRate,
                          channels: channels, generation: generation)
    }

    func applyConfig(_ newConfig: CoreConfig) {
        let oldModelId = currentModelId
        config = newConfig
        if oldModelId != currentModelId {
            modelWeightsCache = nil
            memoryBreakdownCache = nil
            modelWeightsTask?.cancel()
            modelWeightsTask = nil
            scheduleModelWeightsScan()
        }
        guard let core else { return }
        do { try core.configure(config: newConfig) } catch { lastError = Engine.humanMessage(error) }
    }

    /// The active engine/model the UI should highlight, derived from config.
    var selection: ModelSelection { ModelSelection(modelSpec: config.model) }

    /// The selection the UI should show as «выбранная» — это `pendingModel`,
    /// если он задан и отличается от активной, иначе активная модель.
    var effectiveSelection: ModelSelection { pendingModel ?? selection }

    /// Есть ли несохранённый выбор модели, ожидающий применения (перезапуска).
    var hasPendingModel: Bool {
        guard let p = pendingModel else { return false }
        return p != selection
    }

    /// Short live-liveness label used by compact and full record cards.
    var metricsAgeText: String? {
        guard state == .recording || pipelineStalled else { return nil }
        if pipelineStalled { return L("metric.stopped") }
        guard lastMetricSnapshot != nil, let age = lastMetricAgeS else { return L("metric.waiting") }
        return L("metric.age", Int(age.rounded()))
    }

    /// Age of the most recent voice/interval event, shown beside the live
    /// feed so an old row is not mistaken for fresh transcription.
    var liveUpdateAgeText: String? {
        guard state == .recording, let lastLiveUpdateAt else { return nil }
        let age = max(0, clock().timeIntervalSince(lastLiveUpdateAt))
        return L("event.age", Int(age.rounded()))
    }

    /// Internal behavioral-test seam for delayed callback generation checks.
    var sessionGenerationForTesting: UInt? { activeSessionGeneration }

    /// Поставить модель/движок «в очередь» из выбора в UI. В ОТЛИЧИЕ от
    /// интервалов/VAD/языка смена модели НЕ применяется сама по себе — она лишь
    /// запоминается. Применение — только по кнопке «Применить»
    /// (`applyModelRestart`) с перезапуском сессии. Выбор, совпадающий с
    /// активной моделью, очищает очередь.
    func stageModel(_ selection: ModelSelection) {
        pendingModel = (selection == self.selection) ? nil : selection
    }

    /// Применить выбранную модель с ПЕРЕЗАПУСКОМ сессии.
    ///
    /// Если идёт запись: стоп → дождаться полной остановки ядра → loadModel →
    /// start → возобновить захват (с теми же источниками). Если простаиваем —
    /// просто сохраняем модель в конфиг; она применится на следующем старте.
    /// Бесшовной смены модели нет: модель — снимок старта.
    func applyModelRestart() {
        guard let target = pendingModel, target != selection else { return }
        var c = config
        c.model = target.toModelSpec()
        applyConfig(c)            // сохраняем модель в конфиг (для следующего старта)
        pendingModel = nil

        guard let core else { return }
        // Если не пишем — ничего перезапускать не нужно.
        guard state == .recording, !needsRestart else { return }

        let mic = captureMic, system = captureSystem
        isApplyingModel = true
        watchdogTask?.cancel()
        watchdogTask = nil
        activeSessionGeneration = nil
        activeSessionStartedAt = nil
        coreBox.set(nil)
        capture.stop()
        coreSessionRunning = false
        isStarting = true
        state = .loading
        _ = nextLifecycleGeneration()
        // Reuse the same idempotent stop task used by normal Stop. The new
        // model must not load while old ASR threads are still unwinding.
        scheduleCoreStop(core)
        let generation = lifecycleGeneration
        let previousStop = coreStopTask
        let task: Task<Void, Never> = Task.detached(priority: .userInitiated) {
            _ = await previousStop?.value
            if previousStop != nil {
                await MainActor.run {
                    if self.lifecycleGeneration == generation { self.clearCompletedCoreStop() }
                }
            }
            do {
                let shouldContinue = await MainActor.run {
                    guard generation == self.lifecycleGeneration, self.isStarting else { return false }
                    self.listener?.setGeneration(generation)
                    return true
                }
                guard shouldContinue else {
                    await MainActor.run {
                        self.coreStartTask = nil
                        self.isApplyingModel = false
                    }
                    return
                }
                try core.loadModel()
                try core.start()
                await MainActor.run {
                    guard generation == self.lifecycleGeneration, self.isStarting else {
                        self.coreStartTask = nil
                        self.scheduleCoreStop(core)
                        self.isApplyingModel = false
                        return
                    }
                    self.coreSessionRunning = true
                    do {
                        try self.capture.start(captureMic: mic, captureSystem: system,
                                               generation: generation)
                    } catch {
                        self.failStart(core: core, generation: generation,
                                       message: L("error.audioPrefix",
                                                  Engine.humanMessage(error)))
                        self.isApplyingModel = false
                        return
                    }
                    self.coreBox.set(core, generation: generation)
                    self.activeSessionGeneration = generation
                    self.activeSessionStartedAt = self.clock()
                    self.liveFeed = []
                    self.lastLiveUpdateAt = nil
                    self.activityRevision &+= 1
                    self.intervalRevision &+= 1
                    self.queueDropWarningCount = 0
                    self.queueSaturationStartedMono = nil
                    self.armWatchdog(generation: generation)
                    self.coreStartTask = nil
                    self.isStarting = false
                    self.state = .recording
                    self.isApplyingModel = false
                }
            } catch {
                await MainActor.run {
                    self.failStart(core: core, generation: generation,
                                   message: Engine.humanMessage(error))
                    self.isApplyingModel = false
                }
            }
        }
        coreStartTask = task
    }

    // MARK: models

    func refreshModels() {
        models = core?.listModels() ?? []
    }
    func download(modelId: String) {
        guard let core else { return }
        // Сбой загрузки обязан быть виден: раньше `try?` съедал ошибку, и
        // пользователь видел только «зависший» прогресс без объяснения.
        Task.detached {
            do {
                try core.downloadModel(id: modelId)
                await MainActor.run {
                    self.refreshModels()
                    self.syncModelProgress(modelId)
                    if self.currentModelId == modelId {
                        self.modelWeightsCache = nil
                        self.memoryBreakdownCache = nil
                        self.scheduleModelWeightsScan()
                    }
                }
            }
            catch {
                await MainActor.run {
                    self.lastError = L("error.modelDownload", modelId,
                                       Engine.humanMessage(error))
                    self.refreshModels()
                    self.syncModelProgress(modelId)
                }
            }
        }
    }
    func delete(modelId: String) {
        guard let core else { return }
        do {
            try core.deleteModel(id: modelId)
            refreshModels()
            if currentModelId == modelId {
                modelWeightsCache = nil
                memoryBreakdownCache = nil
                scheduleModelWeightsScan()
            }
        } catch { lastError = Engine.humanMessage(error) }
    }

    /// Приводит запись прогресса к финальному состоянию из `listModels()`.
    /// Без этого после успешной или провалившейся загрузки в `modelProgress`
    /// оставался «вечный» downloading-снимок, и UI показывал незавершённый бар.
    private func syncModelProgress(_ modelId: String) {
        if let status = models.first(where: { $0.id == modelId }) {
            modelProgress[modelId] = status
        } else {
            modelProgress.removeValue(forKey: modelId)
        }
    }

    // MARK: queries

    func intervals(from: String, to: String) -> [IntervalRecord] {
        queryOrEmpty("intervals") { core in try core.queryIntervals(from: from, to: to) }
    }

    /// Асинхронный запрос интервалов для компактных UI-блоков.
    ///
    /// FFI-объект ядра держится в отдельном `@unchecked Sendable` read-only
    /// wrapper и вызывается с utility-потока.  `CoreBox` аудиопути здесь не
    /// используется: его короткий lock никогда не удерживается на время
    /// SQLite-запроса.  Возврат всё равно приходит на главный актор,
    /// поскольку `Engine` изолирован `@MainActor`.
    func intervalsAsync(from: String, to: String) async -> [IntervalRecord] {
        guard let core else { return [] }
        let reader = CoreQueryBox(core: core)
        return await Task.detached(priority: .utility) {
            do {
                return try reader.core.queryIntervals(from: from, to: to)
            } catch {
                NSLog("Chronica: async store query 'intervals' failed: %@", "\(error)")
                return []
            }
        }.value
    }
    /// Последние интервалы БЕЗ выбора периода (хвост истории), новые первыми.
    ///
    /// Панели меню-бара нужна не «текущая сессия», а именно хвост: события
    /// живут в памяти и после перезапуска приложения лента была пуста. Запрос
    /// идёт тем же путём, что и `intervalsAsync` — read-only FFI-wrapper на
    /// utility-потоке, поэтому открытие панели не трогает главный актор.
    func recentIntervalsAsync(limit: UInt32) async -> [IntervalRecord] {
        guard let core else { return [] }
        let reader = CoreQueryBox(core: core)
        return await Task.detached(priority: .utility) {
            do {
                return try reader.core.recentIntervals(limit: limit)
            } catch {
                NSLog("Chronica: async store query 'recentIntervals' failed: %@", "\(error)")
                return []
            }
        }.value
    }

    /// Последние сессии записи, новые первыми — разделители ленты панели.
    func recentSessionsAsync(limit: UInt32) async -> [SessionRecord] {
        guard let core else { return [] }
        let reader = CoreQueryBox(core: core)
        return await Task.detached(priority: .utility) {
            do {
                return try reader.core.recentSessions(limit: limit)
            } catch {
                NSLog("Chronica: async store query 'recentSessions' failed: %@", "\(error)")
                return []
            }
        }.value
    }

    /// Сессии записи за период — разделители ленты в окне (раздел «Журнал»).
    /// Границы — локальный ISO (`Fmt.queryBound`), как у `intervalsAsync`.
    func sessionsAsync(from: String, to: String) async -> [SessionRecord] {
        guard let core else { return [] }
        let reader = CoreQueryBox(core: core)
        return await Task.detached(priority: .utility) {
            do {
                return try reader.core.querySessions(from: from, to: to)
            } catch {
                NSLog("Chronica: async store query 'sessions' failed: %@", "\(error)")
                return []
            }
        }.value
    }

    /// Сводка по хранилищу (размер на диске, число записей) для Настроек.
    ///
    /// Идёт тем же путём, что и `intervalsAsync`: read-only FFI-wrapper на
    /// utility-потоке, чтобы `PRAGMA`/`COUNT(*)` не подвешивали интерфейс.
    /// Ошибка (нет ядра, недоступна база) — это `nil`: строка со сводкой
    /// просто не показывается, ругаться на пользователя здесь нечем.
    func storeInfoAsync() async -> StoreInfo? {
        guard let core else { return nil }
        let reader = CoreQueryBox(core: core)
        return await Task.detached(priority: .utility) {
            do {
                return try reader.core.storeInfo()
            } catch {
                NSLog("Chronica: async store query 'storeInfo' failed: %@", "\(error)")
                return nil
            }
        }.value
    }

    func voiceActivity(kind: ActivityKind, from: String, to: String) -> [ActivityBucket] {
        queryOrEmpty("voiceActivity") { core in try core.voiceActivity(kind: kind, from: from, to: to) }
    }

    /// Асинхронные агрегаты голосовой активности (по образцу `intervalsAsync`).
    ///
    /// Синхронный `voiceActivity` дёргает SQLite прямо на главном акторе, из-за
    /// чего перерисовка графика подвешивала интерфейс при длинном периоде.
    /// Здесь запрос уходит на utility-поток через read-only FFI-wrapper, а
    /// результат возвращается уже на главный актор (Engine изолирован
    /// `@MainActor`). Отмена задачи вызывающим отбрасывает устаревший результат.
    func voiceActivityAsync(kind: ActivityKind, from: String, to: String) async -> [ActivityBucket] {
        guard let core else { return [] }
        let reader = CoreQueryBox(core: core)
        return await Task.detached(priority: .utility) {
            do {
                return try reader.core.voiceActivity(kind: kind, from: from, to: to)
            } catch {
                NSLog("Chronica: async store query 'voiceActivity' failed: %@", "\(error)")
                return []
            }
        }.value
    }
    /// Ошибка store-запроса для UI эквивалентна пустому результату, но НЕ должна
    /// теряться бесследно (проблемы с БД иначе невидимы) — пишем в unified log.
    private func queryOrEmpty<T>(_ label: String, _ body: (TranscriberCore) throws -> [T]) -> [T] {
        guard let core else { return [] }
        do { return try body(core) }
        catch {
            NSLog("Chronica: store query '%@' failed: %@", label, "\(error)")
            return []
        }
    }
    func setApi(enabled: Bool) {
        guard let core else { return }
        do { try core.setApiEnabled(enabled: enabled) } catch { lastError = Engine.humanMessage(error) }
    }

    // MARK: memory breakdown

    /// id активной модели (для подписи и поиска весов на диске).
    var currentModelId: String {
        switch config.model {
        case .parakeet(let id): return id
        case .whisper(let id): return id
        }
    }

    /// Кэшированный размер весов активной модели на диске.
    ///
    /// Вызов из View/body только читает готовое значение. Если фоновый обход
    /// ещё не завершён, возвращается `0`; сам обход запускается из `boot()`,
    /// после смены модели или после завершения загрузки модели.
    func modelWeightsBytes() -> UInt64 {
        let id = currentModelId
        return modelWeightsCache?.id == id ? modelWeightsCache?.bytes ?? 0 : 0
    }

    /// Запускает ровно один фоновый обход каталога весов для текущей модели.
    /// Повторные вызовы при тиках прогресса/метрик не создают новые обходы.
    private func scheduleModelWeightsScan() {
        let id = currentModelId
        guard ModelWeightsCachePolicy.shouldScan(cachedModelId: modelWeightsCache?.id,
                                                 requestedModelId: id) else { return }
        modelWeightsTask?.cancel()
        let modelDirectory = URL(fileURLWithPath: modelsPath)
            .appendingPathComponent(id, isDirectory: true)
        modelWeightsTask = Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                Engine.directorySizeBytes(modelDirectory)
            }.value
            guard !Task.isCancelled, let self, self.currentModelId == id else { return }
            self.modelWeightsCache = (id, bytes)
            self.memoryBreakdownCache = nil
            self.modelWeightsTask = nil
        }
    }

    /// Обновляет сохранённый снимок активности после фонового запроса.
    func cacheActivityWindow(_ window: Window24h) {
        cachedActivityWindow = window
    }

    /// Обновляет сохранённый снимок ленты панели меню-бара.
    func cacheJournalFeed(_ items: [JournalFeedItem]) {
        cachedJournalFeed = items
    }

    /// Готовый текст разбора расхода памяти по категориям (для `.help` на RAM).
    /// Текущий RSS берём из метрик (во время записи) или читаем напрямую.
    var memoryBreakdownText: String {
        let total = metrics?.memoryRssBytes ?? (ProcessMemory.currentRSSBytes() ?? 0)
        let modelId = currentModelId
        let weights = modelWeightsBytes()
        let searchLoaded = SearchMemoryProbe.shared.loaded
        if let cached = memoryBreakdownCache,
           cached.total == total,
           cached.baseline == bootRssBytes,
           cached.weights == weights,
           cached.modelId == modelId,
           cached.searchLoaded == searchLoaded {
            return cached.text
        }
        let text = MemoryBreakdownLogic.summaryText(
            totalBytes: total,
            baselineBytes: bootRssBytes,
            modelWeightsBytes: weights,
            modelTitle: modelId,
            searchLoaded: searchLoaded)
        memoryBreakdownCache = (total, bootRssBytes, weights, modelId, searchLoaded, text)
        return text
    }

    /// Суммарный размер файлов в каталоге (рекурсивно).
    nonisolated static func directorySizeBytes(_ dir: URL) -> UInt64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in en {
            if let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(sz)
            }
        }
        return total
    }

    // MARK: event handling

    func receive(_ event: CoreEvent, generation: UInt? = nil) {
        // Поколение проверяем ТОЛЬКО у сессионных событий. `.modelProgress` и
        // общие ошибки приходят и в простое (скачивание модели идёт без
        // сессии), а прежний общий guard молча отбрасывал их — прогресс
        // загрузки не доходил до UI вообще.
        let sessionScoped = isCurrentSessionEvent(generation)
        switch event {
        case .stateChanged(let s):
            guard sessionScoped else { return }
            switch s {
            case .recording:
                guard coreSessionRunning, activeSessionGeneration != nil,
                      state == .recording || state == .loading else { return }
                state = .recording
            case .loading:
                guard isStarting, activeSessionGeneration == nil,
                      state == .loading else { return }
                state = .loading
            case .stopping:
                guard state == .stopping, !coreSessionRunning else { return }
                state = .stopping
            case .idle:
                guard state == .stopping, !coreSessionRunning,
                      activeSessionGeneration == nil else { return }
                state = .idle
                metrics = nil
                metricHistory = []
            case .error:
                if coreSessionRunning, activeSessionGeneration != nil {
                    markPipelineStalled(reason: lastError.isEmpty ? L("stall.coreError") : lastError)
                } else {
                    guard isStarting || state == .error else { return }
                    state = .error
                }
            }
        case .metrics(let snap):
            guard sessionScoped, activeSessionGeneration != nil, coreSessionRunning,
                  state == .recording else { return }
            metrics = snap
            let now = clock()
            let monotonicNow = monotonicClock()
            lastMetricsAt = now
            lastMetricAgeS = 0
            lastMetricHeartbeatMono = monotonicNow
            if snap.bgQueueDepth < snap.bgQueueCapacity {
                queueSaturationStartedMono = nil
            }
            if let previous = lastMetricSnapshot,
               metricProgressed(from: previous, to: snap) {
                lastMetricProgressMono = monotonicNow
            } else if lastMetricSnapshot == nil {
                lastMetricProgressMono = monotonicNow
            }
            lastMetricSnapshot = snap
            // #1: наполняем долгоживущую историю для sparkline'ов дашборда.
            // Копим ТОЛЬКО во время записи (события метрик вне записи не шлются,
            // но guard защищает от любого «хвоста» после остановки).
            recordMetricSample(snap)
        case .intervalCommitted(let iv):
            guard sessionScoped, activeSessionGeneration != nil,
                  state == .recording else { return }
            if let started = activeSessionStartedAt,
               let date = Fmt.date(iv.startAt), date < started {
                return
            }
            liveFeed.insert(iv, at: 0)
            if liveFeed.count > 200 { liveFeed.removeLast(liveFeed.count - 200) }
            lastLiveUpdateAt = clock()
            activityRevision &+= 1
            intervalRevision &+= 1
        case .modelProgress(let st):
            modelProgress[st.id] = st
            refreshModels()
        case .error(let code, let message):
            if isQueueDropWarning(code: code, message: message) {
                // Предупреждение об очереди и «стоп конвейера» — сессионные:
                // событие устаревшей сессии не должно глушить новую запись.
                guard sessionScoped else { return }
                if activeSessionGeneration != nil, queueSaturationStartedMono == nil {
                    queueSaturationStartedMono = monotonicClock()
                }
                queueDropWarningCount += 1
                lastError = L("error.queueDrop", queueDropWarningCount)
            } else if isStallError(code: code, message: message) {
                guard sessionScoped else { return }
                markPipelineStalled(reason: message)
            } else {
                // Остальные ошибки не привязаны к сессии (например, сбой
                // скачивания модели в простое) — показываем всегда.
                lastError = message
            }
        case .voiceActivity(_, let at):
            guard sessionScoped, activeSessionGeneration != nil,
                  state == .recording else { return }
            if let started = activeSessionStartedAt,
               let date = Fmt.date(at), date < started {
                return
            }
            activityRevision &+= 1
            lastLiveUpdateAt = clock()
        }
    }

    fileprivate func handle(_ event: CoreEvent) { receive(event) }

    /// Относится ли событие с меткой поколения к активной (или стартующей)
    /// сессии. Событие без метки считается актуальным.
    private func isCurrentSessionEvent(_ generation: UInt?) -> Bool {
        guard let generation else { return true }
        let expected = activeSessionGeneration ?? (isStarting ? lifecycleGeneration : nil)
        return generation == expected
    }

    private func armWatchdog(generation: UInt) {
        watchdogTask?.cancel()
        let now = clock()
        let monotonicNow = monotonicClock()
        lastMetricsAt = now
        lastMetricAgeS = 0
        lastMetricHeartbeatMono = monotonicNow
        lastMetricProgressMono = monotonicNow
        lastMetricSnapshot = nil
        let pollNs = UInt64(max(0.01, watchdogPollS) * 1_000_000_000)
        let sleep = watchdogSleep
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(pollNs)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.checkWatchdog(generation: generation)
                if self.activeSessionGeneration != generation { return }
            }
        }
    }

    private func checkWatchdog(generation: UInt) {
        guard activeSessionGeneration == generation,
              state == .recording, coreSessionRunning else { return }
        let monotonicNow = monotonicClock()
        let metricAge = monotonicElapsed(since: lastMetricHeartbeatMono, now: monotonicNow)
        let queueAge = monotonicElapsed(since: queueSaturationStartedMono, now: monotonicNow)
        lastMetricAgeS = metricAge.isFinite ? metricAge : nil
        if metricAge > watchdogTimeoutS {
            markPipelineStalled(reason: L("stall.noMetrics"))
        } else if queueAge > watchdogTimeoutS {
            markPipelineStalled(reason: L("stall.queueSaturated"))
        }
    }

    private func monotonicElapsed(since start: UInt64?, now: UInt64) -> TimeInterval {
        guard let start, now >= start else { return 0 }
        return TimeInterval(now - start) / 1_000_000_000
    }

    private func captureDidFail(_ error: Error, generation: UInt) {
        guard activeSessionGeneration == generation, state == .recording else { return }
        markPipelineStalled(reason: L("stall.captureFailed", Engine.humanMessage(error)))
    }

    /// Один из источников не поднялся, но сессия жива на оставшихся. Это НЕ
    /// повод глушить запись: показываем понятную причину и продолжаем.
    private func captureDidDegrade(_ error: Error, generation: UInt) {
        guard activeSessionGeneration == generation, state == .recording else { return }
        captureDegraded = true
        lastError = Engine.humanMessage(error)
    }

    /// Ignores volatile CPU/RSS samples when deciding whether the DSP/ASR
    /// pipeline made progress. A metrics ticker can remain alive while the
    /// actual interval, queue, or transcript is frozen.
    private func metricProgressed(from old: MetricsSnapshot, to new: MetricsSnapshot) -> Bool {
        old.currentIntervalElapsedS != new.currentIntervalElapsedS ||
            old.currentIntervalStartAt != new.currentIntervalStartAt ||
            old.lastWriteAt != new.lastWriteAt ||
            old.totalWords != new.totalWords ||
            old.totalIntervals != new.totalIntervals ||
            old.bgQueueDepth != new.bgQueueDepth ||
            old.sources != new.sources
    }

    // Классификация ошибок ЯДРА по тексту. Русские подстроки ниже — НЕ
    // пользовательский интерфейс: это фрагменты сообщений, которые присылает
    // Rust-ядро (часть его текстов русскоязычная). Локализовать их нельзя —
    // сравнение идёт с тем, что реально приходит по FFI. Английские варианты
    // покрывают сообщения рантаймов (sherpa/ORT/whisper.cpp).
    private func isStallError(code: ErrorCode, message: String) -> Bool {
        let text = "\(code) \(message)".lowercased()
        return text.contains("stall") || text.contains("завис") || text.contains("dsp") ||
            text.contains("asr disconnected") || text.contains("asr worker stopped") ||
            text.contains("receiver disconnected")
    }

    private func isQueueDropWarning(code: ErrorCode, message: String) -> Bool {
        let text = "\(code) \(message)".lowercased()
        return text.contains("queue full") || text.contains("interval dropped") ||
            (text.contains("очеред") && text.contains("потер")) ||
            (text.contains("переполн") && text.contains("очеред"))
    }

    private func markPipelineStalled(reason: String) {
        guard !pipelineStalled, activeSessionGeneration != nil else { return }
        pipelineStalled = true
        needsRestart = true
        isSuspendedForSleep = false
        wakeResumeTask?.cancel()
        wakeResumeTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        coreBox.set(nil)
        capture.stop()
        coreSessionRunning = false
        isStarting = false
        activeSessionGeneration = nil
        activeSessionStartedAt = nil
        lastError = L("error.pipelineStalled", reason)
        state = .error
        if let core { scheduleCoreStop(core) }
    }

    /// Добавляет сэмпл метрик в `metricHistory`, поддерживая кап (#1).
    /// Текущие значения: cpuPercent и memoryRssBytes (для sparkline'ов CPU/RAM).
    private func recordMetricSample(_ snap: MetricsSnapshot) {
        let sample = MetricSample(cpu: snap.cpuPercent,
                                  ramBytes: snap.memoryRssBytes,
                                  ts: clock())
        metricHistory = Engine.appendCapped(metricHistory, sample, cap: metricHistoryCap)
    }

    /// Чистая функция добавления с капом (тестируема): добавляет `sample`,
    /// затем срезает с начала так, чтобы длина не превышала `cap`.
    static func appendCapped(_ history: [MetricSample], _ sample: MetricSample,
                             cap: Int) -> [MetricSample] {
        var out = history
        out.append(sample)
        if out.count > cap { out.removeFirst(out.count - cap) }
        return out
    }

    // MARK: человекочитаемые ошибки

    /// Предел длины технической детали, которую ещё уместно показать в UI.
    private nonisolated static let errorDetailLimit = 120

    /// Превращает ошибку ядра/аудио в короткую фразу на языке интерфейса.
    ///
    /// UniFFI отдаёт `CoreError` в виде `ModelLoad("sherpa: ...")` — печатать
    /// такое пользователю нельзя. Возвращается человекочитаемое действие, а
    /// техническая причина добавляется в скобках, только если она короткая и
    /// однострочная. Функция чистая (не читает состояние Engine), поэтому её
    /// маппинг проверяется тестами напрямую.
    nonisolated static func humanMessage(_ error: Error) -> String {
        // CoreError проверяем ДО LocalizedError: UniFFI подмешивает ему
        // `errorDescription = String(reflecting:)`, то есть сырой дамп кейса.
        if let core = error as? CoreError {
            switch core {
            case let .Config(detail):
                return compose(L("error.core.config"), detail)
            case let .ModelLoad(detail):
                return compose(L("error.core.modelLoad"), detail)
            case let .ModelDownload(detail):
                return compose(L("error.core.modelDownload"), detail)
            case let .Audio(detail):
                return compose(L("error.core.audio"), detail)
            case let .Backend(detail):
                return compose(L("error.core.backend"), detail)
            case let .Store(detail):
                return compose(L("error.core.store"), detail)
            case let .Api(detail):
                return compose(L("error.core.api"), detail)
            case let .Internal(detail):
                return compose(L("error.core.internal"), detail)
            }
        }
        if let audio = error as? AudioCaptureError, let text = audio.errorDescription {
            return text
        }
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return compose(L("error.unexpected"), "\(error)")
    }

    /// Склеивает короткую фразу с технической деталью — только если деталь
    /// однострочная и достаточно короткая; иначе деталь опускается.
    private nonisolated static func compose(_ message: String, _ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\n"),
              trimmed.count <= errorDetailLimit else { return message }
        return L("error.detail", message, trimmed)
    }

    /// Нормализует срок хранения из настроек UI в поле ядра.
    ///
    /// Отрицательные значения (испорченный UserDefaults) означают «хранить
    /// всегда», а не «удалить всё»: потеря истории необратима.
    nonisolated static func retentionDays(_ days: Int) -> UInt32 {
        days > 0 ? UInt32(min(days, Int(UInt32.max))) : 0
    }

    static func defaultConfig(storagePath: String, modelsPath: String,
                              retentionDays: UInt32 = 0) -> CoreConfig {
        CoreConfig(
            model: .parakeet(id: "parakeet-tdt-0.6b-v3-int8"),
            language: .auto,
            // CPU-провайдер держит одну резидентную копию модели (CoreML
            // дублирует её в памяти и течёт на не-Cocoa ASR-потоке).
            acceleration: .cpu,
            minIntervalS: 30,
            maxIntervalS: 300,
            silenceCutMs: 2000,
            vad: VadConfig(sileroThreshold: 0.5, rmsFallback: 0.008),
            nThreads: 4,
            // Очередь 4 ограничивает worst-case объём аудио в ожидании обработки.
            bgQueueSize: 4,
            // Синхронизировано с дефолтом ядра (config.rs: 160_000 = 10 с
            // аудио при 16 кГц). Прежние 48 000 (3 с) перетирали кольцевой
            // буфер и теряли сэмплы (`droppedChunks`) при загрузке модели и
            // всплесках обработки. Контракт Engine не меняется.
            audioQueueSize: 160000,
            storagePath: storagePath,
            modelsPath: modelsPath,
            api: ApiConfig(enabled: false, host: "127.0.0.1", port: 8765, token: ""),
            retentionDays: retentionDays
        )
    }
}

/// Потокобезопасный держатель ядра для realtime-аудиопути. Ядро (`TranscriberCore`)
/// внутри Arc + lock-free ring, его можно звать с аудиопотока напрямую — без
/// прыжка на главный актор. Ссылка ставится один раз в `boot()`; чтение в
/// `pushFrame` под коротким неконтендящимся локом.
final class CoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var core: TranscriberCore?
    private var activeGeneration: UInt?

    func set(_ c: TranscriberCore?, generation: UInt? = nil) {
        lock.lock()
        core = c
        activeGeneration = c == nil ? nil : generation
        lock.unlock()
    }

    func pushFrame(channel: String, pcm: [Int16], sampleRate: UInt32,
                   channels: UInt8, generation: UInt? = nil) {
        lock.lock()
        let c = core
        let active = activeGeneration
        lock.unlock()
        guard let c, generation == nil || generation == active else { return }
        c.pushAudioFrame(channelId: channel, pcm: pcm, sampleRate: sampleRate, channels: channels)
    }
}

/// FFI-дескриптор только для чтения для запросов хранилища вне главного
/// актора. Rust-ядро само сериализует SQLite-соединение; wrapper отделён от
/// `CoreBox`, чей lock зарезервирован для realtime-пути отправки аудио.
private final class CoreQueryBox: @unchecked Sendable {
    let core: TranscriberCore

    init(core: TranscriberCore) {
        self.core = core
    }
}

// Значения UniFFI копируются при переходе через detached-задачу запроса. В
// сгенерированном модуле пока нет Sendable, поэтому граница явно отмечена для
// проверок конкурентности Swift.
extension ChannelText: @unchecked Sendable {}
extension IntervalRecord: @unchecked Sendable {}
extension ChannelCount: @unchecked Sendable {}
extension ActivityBucket: @unchecked Sendable {}
extension ActivityKind: @unchecked Sendable {}
extension StoreInfo: @unchecked Sendable {}
extension SessionRecord: @unchecked Sendable {}

/// Один сэмпл истории метрик для sparkline'ов дашборда (#1).
/// Содержит текущие значения CPU и RSS на момент `ts`.
struct MetricSample: Equatable {
    let cpu: Float
    let ramBytes: UInt64
    let ts: Date
}

/// Поведенческая политика кэша размера весов. Вынесена отдельно, чтобы
/// тестировать «один обход на модель» и инвалидацию при смене id без доступа к
/// приватному состоянию Engine или к реальным весам.
enum ModelWeightsCachePolicy {
    static func shouldScan(cachedModelId: String?, requestedModelId: String) -> Bool {
        cachedModelId != requestedModelId
    }
}

/// Bridges Rust callbacks (arbitrary threads) onto the main actor.
private final class Listener: CoreEventListener {
    weak var engine: Engine?
    private let lock = NSLock()
    private var generation: UInt = 0
    init(engine: Engine) { self.engine = engine }

    func setGeneration(_ generation: UInt) {
        lock.lock()
        self.generation = generation
        lock.unlock()
    }

    func onEvent(event: CoreEvent) {
        lock.lock()
        let eventGeneration = generation
        lock.unlock()
        DispatchQueue.main.async { [weak engine] in
            engine?.receive(event, generation: eventGeneration)
        }
    }
}
