import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

/// Чистые правила «делать ли тик наблюдения» и «пора ли чистить журнал».
///
/// Вынесены из `ScreenObserver`, чтобы проверять решение без SCK, Ollama и
/// реального простоя системы: провайдеры idle/locked инжектируются.
enum ScreenTickPolicy {
    /// Решение о конкретном тике.
    enum Decision: Equatable {
        case observe
        /// Экран заблокирован — смотреть нечего.
        case skipLocked
        /// Пользователь не касался устройства дольше периода наблюдения.
        case skipIdle
    }

    /// Интервал между чистками журнала по сроку хранения (сутки).
    static let retentionIntervalS: TimeInterval = 86_400

    static func decide(locked: Bool, idleSeconds: TimeInterval, periodS: Double) -> Decision {
        if locked { return .skipLocked }
        // Период может прийти из UserDefaults «снаружи» — страхуемся от NaN.
        let threshold = periodS.isFinite ? max(periodS, 1) : 60
        if idleSeconds.isFinite, idleSeconds > threshold { return .skipIdle }
        return .observe
    }

    static func shouldRunRetention(lastRunAt: Date?, now: Date,
                                   intervalS: TimeInterval = retentionIntervalS) -> Bool {
        guard let lastRunAt else { return true }
        return now.timeIntervalSince(lastRunAt) >= intervalS
    }
}

/// Оркестратор наблюдения экрана: по таймеру снимает скриншот (SCK), решает по
/// perceptual-hash, менялся ли кадр, зовёт vision-LLM за описанием работы,
/// сессионизирует наблюдения в «дела» (Sessionizer) и пишет в ActivityStore.
///
/// Вся I/O-часть здесь; правила слития/хэш/промпт — чистые (ScreenContext.swift),
/// LLM — за протоколом VisionDescriber. Требует TCC «Запись экрана» (как и
/// захват системного звука — разрешение у приложения уже есть).
@MainActor
final class ScreenObserver: ObservableObject {
    /// Результат захвата одного кадра. Храним только компактное представление,
    /// нужное для hash/LLM; сам `CGImage` после выхода из capture сразу
    /// освобождается.
    struct CapturedFrame: Sendable {
        var jpegBase64: String
        var luma64: [UInt8]
    }

    /// Test seam для lifecycle-тестов без Screen Recording/SCK.
    typealias FrameProvider = @Sendable () async throws -> CapturedFrame

    enum Status: Equatable {
        case off
        case running
        /// Нет разрешения «Запись экрана» или SCK недоступен.
        case noPermission(String)
        /// Vision-бэкенд недоступен (Ollama не запущена / модель не скачана).
        case backendUnavailable(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastObservation: ScreenObservation?
    /// Дела за сегодня (для секции «Дела» и popover) — обновляется после
    /// каждого тика.
    @Published private(set) var todayActivities: [Activity] = []
    /// Счётчик изменений журнала дел: растёт после каждого обновления.
    /// Панель меню-бара берёт его в ключ перезагрузки ленты — так новое дело
    /// доезжает до открытой панели, не заставляя её перечитывать хранилище на
    /// каждый кадр интерфейса.
    @Published private(set) var activityRevision: UInt = 0
    @Published private(set) var lastError: String = ""

    private let prefs: Prefs
    private var store: ActivityStore?
    /// Путь к файлу журнала — нужен фоновому читателю.
    private let storeFilePath: String
    /// Отдельное соединение для фоновых чтений (панель). Создаётся лениво:
    /// при выключенном журнале экрана оно не открывается вовсе.
    private var reader: ActivityReader?
    private var describer: VisionDescriber
    private let usesInjectedDescriber: Bool
    private var tickTask: Task<Void, Never>?
    /// Поколение запуска. Любой await старого поколения обязан отбрасывать
    /// результат перед изменением состояния/хранилища.
    private var lifecycleGeneration: UInt64 = 0
    /// Поколение, владеющее текущим дорогим тиком. После stop() старый SCK/
    /// Ollama await может игнорировать cancellation, поэтому новое поколение
    /// должно иметь право начать свой тик; defer старого тика не должен
    /// очищать ownership нового поколения.
    private var inFlightGeneration: UInt64?
    private var current: Activity?
    private var lastHash: UInt64?
    private var lastContext: (app: String, title: String)?
    /// Системный запрос «Запись экрана» показываем РОВНО один раз за запуск
    /// (иначе SCK при каждом тике повторял бы диалог).
    private var didRequestScreenAccess = false

    /// Пауза между наблюдениями, после которой блок дела рвётся принудительно.
    private var mergeGap: TimeInterval { max(prefs.screenPeriodS * 3, 180) }

    private let frameProvider: FrameProvider?
    private let contextProvider: (() -> (app: String, title: String))?
    private let nowProvider: () -> Date
    private let enabledProvider: (() -> Bool)?
    private let periodProvider: (() -> Double)?
    private let idleSecondsProvider: () -> TimeInterval
    private let screenLockedProvider: () -> Bool
    /// Когда последний раз чистили журнал по сроку хранения.
    private var lastRetentionAt: Date?

    /// Создаёт наблюдатель экрана.
    ///
    /// Дополнительные замыкания — внутренние test seams: production использует
    /// SCK/NSWorkspace и `Prefs`, а тесты подставляют детерминированный кадр,
    /// контекст, часы и флаг включения без системных разрешений.
    init(storagePath: String,
         prefs: Prefs? = nil,
         describer: VisionDescriber? = nil,
         frameProvider: FrameProvider? = nil,
         contextProvider: (() -> (app: String, title: String))? = nil,
         nowProvider: @escaping () -> Date = Date.init,
         enabledProvider: (() -> Bool)? = nil,
         periodProvider: (() -> Double)? = nil,
         idleSecondsProvider: (() -> TimeInterval)? = nil,
         screenLockedProvider: (() -> Bool)? = nil,
         autoStart: Bool = true) {
        let prefs = prefs ?? Prefs.shared
        self.prefs = prefs
        self.frameProvider = frameProvider
        self.contextProvider = contextProvider
        self.nowProvider = nowProvider
        self.enabledProvider = enabledProvider
        self.periodProvider = periodProvider
        // Системные запросы idle/lock ходят в WindowServer, поэтому в прогонах
        // с подменённым кадром (тесты) по умолчанию считаем пользователя
        // активным, а экран — разблокированным; проверки политики подставляют
        // провайдеры явно.
        self.idleSecondsProvider = idleSecondsProvider
            ?? (frameProvider == nil ? ScreenObserver.systemIdleSeconds : { 0 })
        self.screenLockedProvider = screenLockedProvider
            ?? (frameProvider == nil ? ScreenObserver.systemScreenLocked : { false })
        self.usesInjectedDescriber = describer != nil
        self.describer = describer ?? OllamaDescriber(
            baseURL: URL(string: prefs.ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!,
            model: prefs.visionModel
        )
        let storeFilePath = storagePath + "/screen.sqlite"
        self.storeFilePath = storeFilePath
        do {
            let store = try ActivityStore(path: storeFilePath)
            self.store = store
            self.current = try store.lastActivity()
            // Срок хранения 0 дней означает «всегда»: чистку в этом случае не
            // запускаем вовсе, иначе она снесла бы весь журнал.
            if prefs.screenRetentionDays > 0 {
                try? store.deleteOlderThan(days: prefs.screenRetentionDays)
            }
            self.lastRetentionAt = nowProvider()
        } catch {
            lastError = Engine.humanMessage(error)
        }
        if autoStart, prefs.screenEnabled { start() }
    }

    // MARK: lifecycle

    func start() {
        guard tickTask == nil else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        status = .running
        lastError = ""
        if !usesInjectedDescriber { rebuildDescriber() }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(generation: generation)
                guard !Task.isCancelled else { return }
                let period = self.observationPeriod()
                do {
                    try await Task.sleep(nanoseconds: Self.periodNanoseconds(period))
                } catch {
                    return
                }
            }
        }
        refreshToday()
    }

    func stop() {
        lifecycleGeneration &+= 1
        tickTask?.cancel()
        tickTask = nil
        status = .off
    }

    /// Настройки бэкенда меняются в Settings — пересобрать клиент.
    func rebuildDescriber() {
        describer = OllamaDescriber(
            baseURL: URL(string: prefs.ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!,
            model: prefs.visionModel
        )
    }

    func probeBackend() async -> VisionProbe {
        await describer.probe()
    }

    // MARK: querying (для UI)

    func activities(from: Date, to: Date) -> [Activity] {
        (try? store?.activities(from: from, to: to)) ?? []
    }

    /// Отдаёт ли наблюдатель дела прямо сейчас: журнал включён в настройках И
    /// наблюдение запущено.
    ///
    /// Панель меню-бара спрашивает это ПЕРЕД запросом: при выключенном журнале
    /// экрана она не должна ни ходить в SQLite, ни показывать пустую секцию.
    var providesActivities: Bool { isEnabled && status != .off }

    /// Дела за период БЕЗ обращения к SQLite с главного актора.
    ///
    /// Окну синхронный `activities(from:to:)` по карману — оно и так грузится;
    /// панели меню-бара нет: она открывается по клику и не имеет права ждать
    /// хранилище. Поэтому запрос уходит на utility-поток по ОТДЕЛЬНОМУ
    /// read-only соединению (`ActivityReader`) — тем же приёмом, что и
    /// `Engine.recentIntervalsAsync`. Отмена задачи вызывающим отбрасывает
    /// устаревший результат.
    func activitiesAsync(from: Date, to: Date) async -> [Activity] {
        guard let reader = backgroundReader() else { return [] }
        return await Task.detached(priority: .utility) {
            reader.activities(from: from, to: to)
        }.value
    }

    /// Ленивое соединение для фоновых чтений: до первого запроса панели файл
    /// журнала вторым хендлом не открывается.
    private func backgroundReader() -> ActivityReader? {
        if let reader { return reader }
        reader = ActivityReader(path: storeFilePath)
        return reader
    }

    func observations(of activity: Activity) -> [ScreenObservation] {
        (try? store?.observations(activityId: activity.id)) ?? []
    }

    // MARK: tick

    private func tick(generation: UInt64) async {
        // stop/restart can leave a previous await in flight. Do not overlap
        // expensive SCK/Ollama work, and never let an old generation mutate UI.
        guard isCurrent(generation), isEnabled else { return }
        guard inFlightGeneration != generation else { return }
        inFlightGeneration = generation
        defer {
            // A newer generation may have taken ownership while this await was
            // still running. Never clear that newer ownership from an old defer.
            if inFlightGeneration == generation { inFlightGeneration = nil }
        }

        guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }

        // Ретеншн журнала — раз в сутки прямо из тика: у агента, который живёт
        // неделями, конструктор отрабатывает ровно один раз, и без этого база
        // росла неограниченно.
        runRetentionIfDue()

        // Пропускаем дорогой тик, когда смотреть нечего: экран заблокирован
        // или пользователь не касался устройства дольше периода наблюдения.
        // Это экономит скриншот + вызов vision-LLM и не плодит пустые «дела».
        switch ScreenTickPolicy.decide(locked: screenLockedProvider(),
                                       idleSeconds: idleSecondsProvider(),
                                       periodS: observationPeriod()) {
        case .observe:
            break
        case .skipLocked, .skipIdle:
            return
        }

        // Разрешение «Запись экрана» проверяем БЕЗ подсказки: CGPreflight… не
        // показывает системный диалог. Раньше каждый тик сразу звал SCK, а SCK
        // при отсутствии доступа сам показывает запрос — отсюда «диалог каждую
        // минуту». Теперь: если доступа нет — запрашиваем РОВНО один раз и
        // выходим (SCK не трогаем → повторных диалогов нет).
        //
        // ВАЖНО (macOS): выданное разрешение НЕ применяется к уже запущенному
        // процессу — после выдачи Chronica нужно перезапустить. До перезапуска
        // preflight остаётся false, поэтому мы лишь показываем понятный статус,
        // а не спамим запросами.
        // Injected providers are used only by tests and do not need TCC/SCK;
        // production always goes through the real preflight gate.
        if frameProvider == nil, !CGPreflightScreenCaptureAccess() {
            guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
            if !didRequestScreenAccess {
                didRequestScreenAccess = true
                _ = CGRequestScreenCaptureAccess()
            }
            guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
            status = .noPermission(L("screen.noPermission"))
            return
        }

        // 1. Кадр + контекст фронтального окна.
        let frame: Frame
        do {
            frame = try await captureFrame()
        } catch {
            guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
            // Доступ есть (preflight прошёл) — значит это НЕ про разрешение:
            // нет дисплея, сбой кодирования и т.п. Не сбрасываем статус в
            // noPermission, чтобы не путать.
            lastError = L("screen.captureFailed", Engine.humanMessage(error))
            return
        }
        guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
        let (app, title) = contextProvider?() ?? frontWindowContext()
        guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }

        // 2. Кадр не менялся и контекст тот же → продлеваем дело без LLM.
        let hash = FrameHash.aHash(luma64: frame.luma64)
        let unchanged = lastHash.map { FrameHash.hamming($0, hash) < FrameHash.unchangedThreshold } ?? false
        let sameContext = lastContext.map { $0.app == app && $0.title == title } ?? false

        var summary = ""
        if !(unchanged && sameContext) {
            do {
                summary = try await describer.describe(
                    jpegBase64: frame.jpegBase64, app: app, windowTitle: title
                )
                guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
                if case .backendUnavailable = status { status = .running }
                lastError = ""
            } catch {
                guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
                // LLM недоступна — наблюдение всё равно фиксируем (app+title
                // сами по себе ценный лог), статус подсказывает, что чинить.
                let text = Engine.humanMessage(error)
                status = .backendUnavailable(L("screen.visionUnavailable", text))
                lastError = text
            }
        }

        // 3. Сессионизация + запись.
        guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
        // Обновляем hash/context только после успешного (для текущего
        // поколения) долгого await. Иначе stop во время Ollama мог оставить
        // «новый» hash: после restart такой же кадр ошибочно пропускал бы LLM и
        // создавал пустое описание.
        lastHash = hash
        lastContext = (app, title)
        let obs = ScreenObservation(ts: nowProvider(), app: app, windowTitle: title, summary: summary)
        lastObservation = obs
        guard let store else { return }
        guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
        do {
            switch Sessionizer.merge(last: current, obs: obs, gap: mergeGap) {
            case .extend(let updated):
                try store.update(updated)
                try store.appendObservation(obs, activityId: updated.id)
                current = updated
            case .start(let fresh):
                let saved = try store.insert(fresh)
                try store.appendObservation(obs, activityId: saved.id)
                current = saved
            }
            guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
            if status != .off, case .backendUnavailable = status {} else { status = .running }
            refreshToday()
        } catch {
            guard !Task.isCancelled, isCurrent(generation), isEnabled else { return }
            lastError = L("screen.storeError", Engine.humanMessage(error))
        }
    }

    private var isEnabled: Bool { enabledProvider?() ?? prefs.screenEnabled }

    /// Чистит журнал по сроку хранения не чаще раза в сутки.
    /// При выбранном «всегда» (0 дней) чистка не выполняется.
    private func runRetentionIfDue() {
        let now = nowProvider()
        guard ScreenTickPolicy.shouldRunRetention(lastRunAt: lastRetentionAt, now: now) else { return }
        lastRetentionAt = now
        let days = prefs.screenRetentionDays
        guard days > 0 else { return }
        try? store?.deleteOlderThan(days: days)
    }

    /// Секунды с последнего пользовательского ввода (клавиатура/мышь/трекпад).
    ///
    /// Используем `kCGAnyInputEventType` (`~0`), а НЕ `.null`: последний
    /// отдаёт время с последнего служебного события и в реальности выдаёт
    /// десятки часов даже на активной машине.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                       eventType: anyInput)
    }

    /// Заблокирован ли экран сессии.
    nonisolated static func systemScreenLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func observationPeriod() -> Double {
        periodProvider?() ?? prefs.screenPeriodS
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == lifecycleGeneration
    }

    private static func periodNanoseconds(_ period: Double) -> UInt64 {
        // UserDefaults can be edited/imported outside the slider. Clamp before
        // converting to UInt64 so NaN/negative values cannot trap the scheduler.
        let safe = period.isFinite ? min(max(period, 0.1), 600) : 60
        return UInt64(safe * 1_000_000_000)
    }

    private func refreshToday() {
        let now = nowProvider()
        let start = Calendar.current.startOfDay(for: now)
        todayActivities = activities(from: start, to: now)
        // Ревизия — сигнал «журнал изменился» для тех, кто держит СВОЙ снимок
        // (панель меню-бара грузит свой диапазон, а не эти сутки).
        activityRevision &+= 1
    }

    // MARK: capture

    private typealias Frame = CapturedFrame

    private func captureFrame() async throws -> Frame {
        if let frameProvider {
            return try await frameProvider()
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw VisionError.backend(L("screen.error.noDisplays"))
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // ~1024pt по ширине достаточно маленькой VLM; сильно экономит токены.
        let scale = min(1.0, 1024.0 / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
        guard let jpeg = Self.jpegData(image, quality: 0.6) else {
            throw VisionError.backend(L("screen.error.encodeFailed"))
        }
        return Frame(jpegBase64: jpeg.base64EncodedString(), luma64: Self.luma8x8(image))
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Сетка яркости 8×8 для perceptual-hash: рисуем кадр в grayscale 8×8.
    private static func luma8x8(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 64)
        let cs = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 8, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return pixels
    }

    /// Фронтальное приложение + заголовок его верхнего окна (CGWindowList;
    /// имена окон видны только при выданном разрешении «Запись экрана»).
    private func frontWindowContext() -> (app: String, title: String) {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "?"
        guard let pid = app?.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                  as? [[String: Any]]
        else { return (appName, "") }
        let title = info.first { w in
            (w[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (w[kCGWindowLayer as String] as? Int) == 0
        }?[kCGWindowName as String] as? String ?? ""
        return (appName, title)
    }
}
