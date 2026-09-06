import SwiftUI
import AppKit
import TranscriberCore

// MARK: - Первый запуск: что мешает начать запись

/// Что показывать вместо кнопки «Начать запись».
///
/// На первом запуске кнопка «Начать запись» бесполезна: модели ещё нет на
/// диске, а разрешение на микрофон могло быть отклонено. Вместо тупика панель
/// показывает ровно одно понятное действие.
enum PopoverOnboardingState: Equatable {
    /// Активная модель не скачана. `progress` — доля 0…1, если загрузка идёт.
    case needsModel(modelId: String, progress: Double?)
    /// Доступ к микрофону запрещён пользователем.
    case micDenied
    /// Всё готово — показываем обычную кнопку записи.
    case ready
}

/// Чистое решение «что показать в панели» (тестируется без UI и без ядра).
enum PopoverOnboarding {
    /// - parameters:
    ///   - models: список моделей из ядра (`engine.models`);
    ///   - progress: снимки прогресса загрузки (`engine.modelProgress`);
    ///   - activeModelId: id активной модели (`engine.currentModelId`);
    ///   - micStatus: статус разрешения микрофона;
    ///   - micRequired: включён ли захват микрофона (при выключенном источнике
    ///     отказ в доступе записи не мешает).
    static func decide(models: [ModelStatus],
                       progress: [String: ModelStatus],
                       activeModelId: String,
                       micStatus: MicPermissionStatus,
                       micRequired: Bool) -> PopoverOnboardingState {
        // Прогресс — более свежий источник, чем список: во время загрузки
        // ядро шлёт снимки чаще, чем перечитывается реестр.
        let status = progress[activeModelId] ?? models.first { $0.id == activeModelId }
        // Пустой список моделей — ядро ещё не поднялось; не пугаем «нет модели».
        if let status, !status.installed {
            return .needsModel(modelId: activeModelId,
                               progress: downloadFraction(status))
        }
        if status == nil, !models.isEmpty {
            return .needsModel(modelId: activeModelId, progress: nil)
        }
        if micRequired, micStatus == .denied { return .micDenied }
        return .ready
    }

    /// Доля загрузки 0…1 или `nil`, если загрузка не идёт.
    /// Проценты из ядра приходят в диапазоне 0…100 и зажимаются.
    static func downloadFraction(_ status: ModelStatus) -> Double? {
        guard status.downloading else { return nil }
        let pct = Double(status.progressPct)
        guard pct.isFinite else { return 0 }
        return min(1, max(0, pct / 100))
    }
}

// MARK: - Источники ленты панели

/// Сбор источников ЕДИНОЙ ленты панели меню-бара — без SwiftUI, поэтому
/// проверяется тестом целиком.
///
/// Панель показывает то же, что и окно (реплики транскрипции и дела с экрана
/// вперемешку по времени), но платит за это меньше: не период, а хвост
/// истории; все запросы — асинхронные; дела берутся ровно за тот диапазон,
/// который покрывает загруженный хвост. `activities == nil` означает
/// «журнал экрана выключен»: тогда запрос НЕ уходит вовсе — при выключенном
/// журнале панель не открывает SQLite ради нуля строк.
@MainActor
struct PopoverFeedSources {
    /// Хвост интервалов из хранилища ядра.
    let recentIntervals: @MainActor (UInt32) async -> [IntervalRecord]
    /// Последние сессии записи (разделители ленты).
    let recentSessions: @MainActor (UInt32) async -> [SessionRecord]
    /// Живые события текущей сессии (в памяти, без похода в хранилище).
    let live: @MainActor () -> [IntervalRecord]
    /// Дела с экрана за диапазон — или `nil`, если журнал экрана выключен.
    let activities: (@MainActor (Date, Date) async -> [Activity])?

    /// Окно дел, когда интервалов не загрузилось ни одного.
    ///
    /// Речи может не быть вовсе (запись выключена), но дела с экрана при этом
    /// пишутся — и панель обязана их показать. Тянуть ради этого всю историю
    /// незачем, поэтому берём последние сутки.
    static let fallbackActivityWindowS: TimeInterval = 24 * 3600

    /// Диапазон запроса дел: от начала самого старого загруженного интервала
    /// до `now`. Ровно то, что может попасть в ленту, — не вся история.
    static func activityRange(intervals: [IntervalRecord],
                              now: Date) -> (from: Date, to: Date) {
        let oldest = intervals.compactMap { Fmt.date($0.startAt) }.min()
        let from = oldest ?? now.addingTimeInterval(-fallbackActivityWindowS)
        return (min(from, now), now)
    }

    /// Загрузить источники и собрать ленту.
    ///
    /// - Returns: элементы ленты (новые сверху, не длиннее `rowLimit`) или
    ///   `nil`, если задачу отменили — панель скрыли, и результат уже никому
    ///   не нужен.
    func load(intervalLimit: UInt32, sessionLimit: UInt32, rowLimit: Int,
              now: Date = Date()) async -> [JournalFeedItem]? {
        let stored = await recentIntervals(intervalLimit)
        guard !Task.isCancelled else { return nil }
        let sessions = await recentSessions(sessionLimit)
        guard !Task.isCancelled else { return nil }
        let intervals = JournalFeed.mergedIntervals(stored: stored, live: live())

        var screenActivities: [Activity] = []
        if let activities {
            let range = Self.activityRange(intervals: intervals, now: now)
            screenActivities = await activities(range.from, range.to)
            guard !Task.isCancelled else { return nil }
        }

        // Лимит строк применяется к ОБЪЕДИНЁННОЙ ленте: панель ограничивает
        // свою высоту, а не каждый источник по отдельности.
        return JournalFeed.capped(
            JournalFeed.build(intervals: intervals, activities: screenActivities,
                              sessions: sessions, now: now),
            limit: rowLimit)
    }
}

// MARK: - Панель меню-бара

/// Мини-окно (панель), выпадающее ПОД иконкой меню-бара по левому клику.
///
/// Один экран без прокрутки всего окна: статус и таймер · тумблеры источников ·
/// активность за 24 часа · ЕДИНАЯ лента (реплики + дела с экрана вперемешку,
/// как в окне) · кнопка записи · ссылки в окно. Прокручивается ТОЛЬКО лента,
/// поэтому высота панели предсказуема и AppKit не выталкивает её на строку
/// меню-бара.
struct PopoverView: View {
    /// Лёгкая оболочка наблюдает только видимость. Engine внедряется в
    /// смонтированную ветку содержимого, поэтому скрытая панель не подписана
    /// на секундные метрики и изменения ленты.
    @EnvironmentObject private var visibility: PanelVisibilityModel
    /// Колбэк в AppDelegate: открыть окно на нужном разделе / закрыть панель.
    let openSection: (AppSection) -> Void

    /// Фиксированная ширина панели.
    static let popoverWidth: CGFloat = 344
    /// Фиксированная высота панели.
    static let popoverHeight: CGFloat = 480

    var body: some View {
        Group {
            if visibility.isPresented {
                PopoverContent(openSection: openSection)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.popoverWidth, height: Self.popoverHeight)
    }
}

/// Полное содержимое панели, монтируемое только пока она видима.
private struct PopoverContent: View {
    @EnvironmentObject private var engine: Engine
    /// Журнал дел с экрана — второй источник ЕДИНОЙ ленты. Наблюдатель
    /// внедряется в смонтированную ветку: скрытая панель на его тики не
    /// подписана.
    @EnvironmentObject private var screen: ScreenObserver
    let openSection: (AppSection) -> Void

    /// Статус разрешения микрофона: читается при показе панели и при
    /// возвращении в приложение (пользователь мог выдать доступ в Системных
    /// настройках, пока панель была открыта).
    @State private var micStatus: MicPermissionStatus = .authorized
    private let micPermission = SystemMicPermission()

    private var isRecording: Bool { engine.state == .recording }

    /// Потолок высоты прокручиваемой ленты реплик.
    private let liveFeedMaxHeight: CGFloat = 240
    /// Строки, которые реально нужны компактной панели.
    private let maxLiveRows = 80

    /// Хвост истории, который панель тянет из хранилища при показе.
    ///
    /// Раньше лента строилась ТОЛЬКО из `engine.liveFeed` (события в памяти),
    /// поэтому после перезапуска приложения панель была пуста: «старых
    /// транскрипций не видно». Теперь при показе панели асинхронно грузятся
    /// последние интервалы и сессии, а живые события текущей сессии
    /// накладываются поверх.
    private static let recentIntervalLimit: UInt32 = 50
    private static let recentSessionLimit: UInt32 = 10

    /// Собранная лента. `nil` — ещё ни одного завершённого запроса в этом
    /// показе панели: до него рисуем прошлый снимок из `Engine`.
    @State private var feed: [JournalFeedItem]?
    /// Схлопывание дублирующих обновлений и отсев устаревших результатов.
    @State private var feedGate = ActivityReloadGate()

    private var onboarding: PopoverOnboardingState {
        PopoverOnboarding.decide(models: engine.models,
                                 progress: engine.modelProgress,
                                 activeModelId: engine.currentModelId,
                                 micStatus: micStatus,
                                 micRequired: engine.captureMic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Color.hairline)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                sources
                DayActivity()
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Единственная прокручиваемая секция — лента реплик.
            liveFeed
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.m)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider().overlay(Theme.Color.hairline)
            footer
        }
        .frame(width: PopoverView.popoverWidth, height: PopoverView.popoverHeight)
        // Фон панели — прозрачный: стекло (или сплошная заливка при
        // «Уменьшить прозрачность») даёт обёртка в AppDelegate.
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .tint(Theme.Color.accent)
        .onAppear { micStatus = micPermission.status }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            micStatus = micPermission.status
        }
    }

    // MARK: шапка

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            StatusGlyph(state: engine.state)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(StateText.headerLabel(engine.state))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                // Единственный индикатор проблемы — короткой строкой под
                // статусом. Технических «Метрики: N с назад» больше нет.
                if let note = SessionHealth.note(engine: engine) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.Color.semWarning)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if isRecording, let m = engine.metrics {
                Text(Fmt.clock(m.currentIntervalElapsedS))
                    .font(.metric)
                    .foregroundStyle(Theme.Color.semRec)
                    .accessibilityLabel(L("popover.currentInterval.a11y"))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    // MARK: источники

    private var sources: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(L("popover.sources"))
            SourceToggle(engine: engine, channelId: Channels.mic)
            SourceToggle(engine: engine, channelId: Channels.remote)
            // Единственная подпись под тумблерами — и только когда она
            // действительно нужна (набор источников изменён во время сессии).
            if let hint = engine.sourceChangeHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: лента реплик (новые сверху)

    private var liveFeed: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionLabel(L("popover.lines"))
                Spacer()
                if isRecording {
                    Text(LiveTail.text(bgQueueDepth: engine.metrics?.bgQueueDepth ?? 0,
                                       channelsSilent: engine.metrics?.channelsSilent ?? false))
                        .font(.metricSmall)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                }
            }
            let items = feed ?? engine.cachedJournalFeed ?? []
            if items.isEmpty {
                Text(isRecording ? L("popover.lines.waiting") : L("popover.lines.idle"))
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(items) { feedRow($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: liveFeedMaxHeight)
            }
        }
        // Задача живёт ровно столько, сколько смонтирована панель: при скрытии
        // `PopoverContent` размонтируется и запрос отменяется.
        .task(id: feedRevision) {
            let revision = feedRevision
            let generation = feedGate.begin(revision: revision)
            // Схлопываем commit с callback, пришедшим сразу после него.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await reloadFeed(revision: revision, generation: generation)
        }
    }

    @ViewBuilder private func feedRow(_ item: JournalFeedItem) -> some View {
        switch item {
        case .day(let date):
            Text(Fmt.dayTitle(date))
                .font(.metricSmall)
                .foregroundStyle(Theme.Color.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .separator(let separator):
            JournalSeparatorRow(separator: separator, compact: true)
        case .line(let line):
            JournalLineRow(line: line, compact: true)
        case .activity(let activity):
            // Дело с экрана — такой же элемент хронологии, как реплика.
            // Разворота и вложенной расшифровки в панели нет: за подробностями
            // идут в окно.
            JournalActivityCompactRow(activity: activity)
        }
    }

    /// Ключ перезагрузки ленты.
    ///
    /// Источников два (реплики и дела), поэтому ключ учитывает обе ревизии.
    /// Оба счётчика только растут, значит их сумма меняется при любом
    /// изменении любого из них — этого достаточно, чтобы `.task(id:)`
    /// перезапустился ровно на новых данных и не дёргался на каждом кадре.
    private var feedRevision: UInt { engine.intervalRevision &+ screen.activityRevision }

    /// Хвост истории из хранилища + живые события текущей сессии + дела с
    /// экрана за тот же диапазон.
    ///
    /// Все запросы уходят на utility-поток (`recentIntervalsAsync` /
    /// `recentSessionsAsync` — тот же read-only путь, что и у `DayActivity`;
    /// `activitiesAsync` — отдельное read-only соединение журнала дел),
    /// поэтому открытие панели не трогает SQLite с главного актора. Устаревший
    /// или пришедший к уже скрытой панели результат отбрасывается гейтом.
    private func reloadFeed(revision: UInt, generation: UInt) async {
        // Выключенный журнал экрана — это ОТСУТСТВИЕ запроса, а не пустой
        // список: панель не открывает журнал дел ради нуля строк.
        var loadActivities: (@MainActor (Date, Date) async -> [Activity])?
        if screen.providesActivities {
            loadActivities = { from, to in await screen.activitiesAsync(from: from, to: to) }
        }
        let sources = PopoverFeedSources(
            recentIntervals: { await engine.recentIntervalsAsync(limit: $0) },
            recentSessions: { await engine.recentSessionsAsync(limit: $0) },
            live: { engine.liveFeed },
            activities: loadActivities)

        guard let items = await sources.load(intervalLimit: Self.recentIntervalLimit,
                                             sessionLimit: Self.recentSessionLimit,
                                             rowLimit: maxLiveRows) else { return }
        guard !Task.isCancelled,
              feedGate.accepts(generation: generation, revision: revision,
                               isPresented: true) else { return }
        feed = items
        engine.cacheJournalFeed(items)
    }

    // MARK: кнопка + футер

    private var footer: some View {
        VStack(spacing: Theme.Space.s) {
            primaryControl
            HStack(spacing: Theme.Space.l) {
                footerLink(AppSection.journal.title, "book.pages", .journal)
                footerLink(AppSection.settings.title, "gearshape", .settings)
            }
            if !engine.lastError.isEmpty {
                ErrorBanner(message: engine.lastError,
                            retry: { engine.pipelineStalled ? engine.restartApplication() : engine.loadModelAndStart() },
                            actionTitle: engine.pipelineStalled ? L("popover.restartApp") : L("popover.retry"))
            }
        }
        .padding(Theme.Space.m)
    }

    /// Главное действие панели: запись, скачивание модели или переход в
    /// системные настройки микрофона — ровно одно из трёх.
    @ViewBuilder private var primaryControl: some View {
        switch onboarding {
        case let .needsModel(modelId, progress):
            if let progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(Theme.Color.accent)
                    Text(L("popover.downloading", ModelCatalog.displayName(id: modelId))
                        + " — \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    engine.download(modelId: modelId)
                } label: {
                    Text(L("popover.downloadModel",
                           ModelCatalog.displayName(id: modelId),
                           ModelCatalog.approximateSize(id: modelId)))
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.accent)
            }

        case .micDenied:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    if let url = URL(string: AudioCaptureError.micPrivacySettingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(L("popover.openMicSettings"))
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.accent)
                Text(L("popover.micDenied"))
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }

        case .ready:
            RecordButton(state: engine.state, compact: true) {
                if engine.pipelineStalled { engine.restartApplication() }
                else if isRecording { engine.stop() } else { engine.loadModelAndStart() }
            }
        }
    }

    private func footerLink(_ title: String, _ icon: String, _ section: AppSection) -> some View {
        Button { openSection(section) } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("popover.openSection.a11y", title))
    }
}

// MARK: - Тумблер источника

private struct SourceToggle: View {
    @ObservedObject var engine: Engine
    let channelId: String
    @State private var on: Bool = true

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            TrackDot(channelId: channelId, size: 8)
            Text(Channels.label(channelId))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Toggle("", isOn: $on)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.trackColor(channelId))
                .accessibilityLabel(L("popover.source.a11y", Channels.label(channelId)))
                .onChange(of: on) { _, v in apply(v) }
        }
        .onAppear { on = (channelId == Channels.mic) ? engine.captureMic : engine.captureSystem }
    }

    private func apply(_ v: Bool) {
        if channelId == Channels.mic { engine.captureMic = v } else { engine.captureSystem = v }
    }
}

// MARK: - Активность за 24 часа

/// Тестируемый gate для отменяемых запросов DayActivity. Новый revision
/// увеличивает поколение, а устаревший/скрытый результат больше не может
/// перезаписать свежий снимок.
struct ActivityReloadGate: Equatable {
    private(set) var generation: UInt = 0
    private(set) var revision: UInt?

    mutating func begin(revision: UInt) -> UInt {
        if self.revision == revision { return generation }
        self.revision = revision
        generation &+= 1
        return generation
    }

    func accepts(generation: UInt, revision: UInt, isPresented: Bool) -> Bool {
        isPresented && self.generation == generation && self.revision == revision
    }
}

/// Активность за последние 24 часа: спарклайн слов по часам и одно число —
/// сколько слов распознано за сутки.
///
/// Источник — НЕ живая лента, а асинхронный запрос интервалов из хранилища за
/// окно [now-24ч … now] (`engine.intervalsAsync`, границы через
/// `Fmt.queryBound`): картина остаётся верной и после перезапуска.
struct DayActivity: View {
    @EnvironmentObject private var engine: Engine
    @State private var win: Window24h?
    @State private var reloadGate = ActivityReloadGate()

    var body: some View {
        let displayedWindow = win ?? engine.cachedActivityWindow
        // Счётчик слов показываем ТОЛЬКО когда данные есть: «0 сл» рядом с
        // «Недостаточно данных» выглядело как сбой, а не как пустой день.
        let ready = displayedWindow.map(hasData) ?? false
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                SectionLabel(L("popover.activity24h"))
                Spacer()
                if ready, let displayedWindow {
                    Text(L("popover.words.short", displayedWindow.totalWords))
                        .font(.metricSmall)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                        .accessibilityLabel(L("popover.words.a11y",
                                              displayedWindow.totalWords))
                }
            }
            if ready, let displayedWindow {
                Sparkline(values: displayedWindow.buckets.map { Double($0.words) },
                          color: Theme.Color.accent)
                    .frame(height: 34)
            } else {
                Text(L("popover.notEnoughData"))
                    .font(.metricSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .frame(height: 34, alignment: .center)
            }
        }
        .task(id: engine.intervalRevision) {
            let revision = engine.intervalRevision
            let generation = reloadGate.begin(revision: revision)
            // Схлопываем commit с callback, пришедшим сразу после него;
            // отмена задачи отбрасывает устаревшую работу до вызова FFI.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await reload(revision: revision, generation: generation)
        }
    }

    /// Есть ли что показывать: бакеты заполнены и хоть где-то ненулевые слова.
    private func hasData(_ w: Window24h) -> Bool {
        !w.buckets.isEmpty && w.totalWords > 0
    }

    /// Пересчёт окна 24ч из хранилища интервалов вне главного актора.
    private func reload(revision: UInt, generation: UInt) async {
        let to = Date()
        let from = to.addingTimeInterval(-24 * 3600)
        let ivs = await engine.intervalsAsync(from: Fmt.queryBound(from),
                                              to: Fmt.queryBound(to))
        guard !Task.isCancelled,
              reloadGate.accepts(generation: generation, revision: revision,
                                 isPresented: true) else { return }
        let next = Activity24h.window(intervals: ivs, now: to)
        guard !Task.isCancelled,
              reloadGate.accepts(generation: generation, revision: revision,
                                 isPresented: true) else { return }
        win = next
        engine.cacheActivityWindow(next)
    }
}
