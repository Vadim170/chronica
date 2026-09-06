import XCTest
@testable import Chronica
@testable import TranscriberCore

/// Поведенческие тесты лёгких seams меню-бара. Они не поднимают SwiftUI окно,
/// не требуют весов ASR и не трогают пользовательские каталоги: хранилище —
/// временный каталог, настройки — отдельный домен.
@MainActor
final class PopoverPerformanceTests: XCTestCase {

    private func interval(id: Int64, text: String = "speech") -> IntervalRecord {
        IntervalRecord(
            id: id,
            startAt: "2026-06-19T12:00:00Z",
            endAt: "2026-06-19T12:00:30Z",
            durationS: 30,
            channels: [ChannelText(channelId: Channels.mic,
                                   text: text,
                                   words: text.isEmpty ? 0 : 1,
                                   language: "en")])
    }

    /// Панель кладёт живые события ПОВЕРХ хвоста из хранилища: один и тот же
    /// интервал не должен появиться в ленте дважды.
    func testPanelMergesLiveEventsOverStoredTailWithoutDuplicates() {
        let stored = [interval(id: 3, text: "stored 3"),
                      interval(id: 2, text: "stored 2"),
                      interval(id: 1, text: "stored 1")]
        let live = [interval(id: 4, text: "live 4"),
                    interval(id: 3, text: "live 3")]

        let merged = JournalFeed.mergedIntervals(stored: stored, live: live)

        XCTAssertEqual(merged.map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(merged.first { $0.id == 3 }?.channels.first?.text, "live 3",
                       "живая версия интервала свежее сохранённой")
    }

    func testActivityReloadGateCoalescesAndRejectsStaleOrHiddenResults() {
        var gate = ActivityReloadGate()
        let first = gate.begin(revision: 7)
        XCTAssertEqual(gate.begin(revision: 7), first,
                       "повторный callback того же revision не создаёт новое поколение")
        XCTAssertTrue(gate.accepts(generation: first, revision: 7, isPresented: true))

        let second = gate.begin(revision: 8)
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(gate.accepts(generation: first, revision: 7, isPresented: true),
                       "устаревший результат не должен перезаписывать свежий")
        XCTAssertFalse(gate.accepts(generation: second, revision: 8, isPresented: false),
                       "результат скрытой панели игнорируется")
        XCTAssertTrue(gate.accepts(generation: second, revision: 8, isPresented: true))
    }

    func testModelWeightsPolicyScansOncePerModelAndInvalidatesOnChange() {
        XCTAssertTrue(ModelWeightsCachePolicy.shouldScan(cachedModelId: nil,
                                                          requestedModelId: "parakeet"))
        XCTAssertFalse(ModelWeightsCachePolicy.shouldScan(cachedModelId: "parakeet",
                                                           requestedModelId: "parakeet"))
        XCTAssertTrue(ModelWeightsCachePolicy.shouldScan(cachedModelId: "parakeet",
                                                          requestedModelId: "whisper"))
    }

    func testTimeFormattingKeepsStableClockShape() {
        let value = Fmt.time("2026-06-19T09:07:08Z")
        XCTAssertEqual(value.count, 8)
        XCTAssertEqual(value.filter(\.isNumber).count, 6)
        XCTAssertEqual(value.filter { $0 == ":" }.count, 2)
    }

    // MARK: - Единая лента панели: реплики + дела с экрана

    /// Включённый журнал экрана: панель показывает ОДНУ ленту — дело стоит
    /// между репликами по времени, а не отдельной секцией.
    func testPanelFeedMixesScreenActivitiesWithLines() async {
        let now = Fmt.date("2026-06-19T12:10:00Z")!
        let asked = RangeRecorder()
        let sources = PopoverFeedSources(
            recentIntervals: { _ in [self.interval(id: 1, text: "сказал вслух")] },
            recentSessions: { _ in [] },
            live: { [] },
            activities: { from, to in
                asked.record(from: from, to: to)
                return [self.activity(id: 7, at: "2026-06-19T12:05:00Z")]
            })

        let items = await sources.load(intervalLimit: 50, sessionLimit: 10,
                                       rowLimit: 80, now: now)

        XCTAssertEqual(kinds(items), ["day", "activity", "line"],
                       "дело и реплика идут одной лентой, новое сверху")
        XCTAssertEqual(asked.calls, 1)
        XCTAssertEqual(asked.range?.from, Fmt.date("2026-06-19T12:00:00Z"),
                       "дела запрашиваются от самого старого загруженного интервала")
        XCTAssertEqual(asked.range?.to, now)
    }

    /// Без интервалов панель всё равно обязана показать дела (речи могло не
    /// быть вовсе), но тянет их за сутки, а не за всю историю.
    func testPanelFeedShowsActivitiesWithoutAnyTranscription() async {
        let now = Fmt.date("2026-06-19T12:10:00Z")!
        let asked = RangeRecorder()
        let sources = PopoverFeedSources(
            recentIntervals: { _ in [] },
            recentSessions: { _ in [] },
            live: { [] },
            activities: { from, to in
                asked.record(from: from, to: to)
                return [self.activity(id: 7, at: "2026-06-19T12:05:00Z")]
            })

        let items = await sources.load(intervalLimit: 50, sessionLimit: 10,
                                       rowLimit: 80, now: now)

        XCTAssertEqual(kinds(items), ["day", "activity"])
        XCTAssertEqual(asked.range?.from,
                       now.addingTimeInterval(-PopoverFeedSources.fallbackActivityWindowS),
                       "без интервалов диапазон ограничен сутками")
    }

    /// Выключенный журнал экрана: запроса дел нет вовсе, и лишних строк в
    /// панели тоже нет.
    func testPanelFeedSkipsActivitiesWhenScreenJournalIsOff() async {
        let now = Fmt.date("2026-06-19T12:10:00Z")!
        let sources = PopoverFeedSources(
            recentIntervals: { _ in [self.interval(id: 1, text: "сказал вслух")] },
            recentSessions: { _ in [] },
            live: { [] },
            activities: nil)

        let items = await sources.load(intervalLimit: 50, sessionLimit: 10,
                                       rowLimit: 80, now: now)

        XCTAssertEqual(kinds(items), ["day", "line"],
                       "выключенный журнал экрана не добавляет в ленту ничего")
    }

    /// Лимит строк применяется к ОБЪЕДИНЁННОЙ ленте, а не к каждому источнику.
    func testPanelFeedCapsTheMergedFeed() async {
        let now = Fmt.date("2026-06-19T12:30:00Z")!
        let sources = PopoverFeedSources(
            recentIntervals: { _ in (1...5).map { self.interval(id: Int64($0), text: "реплика \($0)") } },
            recentSessions: { _ in [] },
            live: { [] },
            activities: { _, _ in
                (1...5).map { self.activity(id: Int64(100 + $0),
                                            at: "2026-06-19T12:0\($0):00Z") }
            })

        let items = await sources.load(intervalLimit: 50, sessionLimit: 10,
                                       rowLimit: 4, now: now)

        XCTAssertEqual(items?.count, 4)
        XCTAssertTrue(kinds(items).contains("activity"))
    }

    /// Наблюдатель отдаёт дела ФОНОВЫМ запросом и только за нужный диапазон;
    /// пока журнал не запущен, панель его вообще не спрашивает.
    func testScreenObserverServesActivitiesOffMainActorOnlyWhileJournalRuns() async throws {
        let dir = makeTemporaryDirectory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try ActivityStore(path: dir.path + "/screen.sqlite")
        _ = try store.insert(Activity(startAt: now.addingTimeInterval(-600),
                                      endAt: now.addingTimeInterval(-300),
                                      app: "Xcode", title: "PopoverView.swift",
                                      summary: "правит панель"))
        _ = try store.insert(Activity(startAt: now.addingTimeInterval(-7200),
                                      endAt: now.addingTimeInterval(-7000),
                                      app: "Mail", title: "Входящие", summary: "разбирает почту"))
        let observer = makeObserver(storagePath: dir.path, now: now)

        XCTAssertFalse(observer.providesActivities,
                       "не запущенный наблюдатель дел панели не отдаёт")

        let loaded = await observer.activitiesAsync(from: now.addingTimeInterval(-1200), to: now)
        XCTAssertEqual(loaded.map(\.app), ["Xcode"],
                       "читается только запрошенный диапазон, а не вся история")

        observer.start()
        XCTAssertTrue(observer.providesActivities)
        observer.stop()
        XCTAssertFalse(observer.providesActivities)
        withExtendedLifetime(store) {}
    }

    /// Сквозная проверка проводки панели на НАСТОЯЩИХ источниках: движок в
    /// изоляции (ядра нет — реплик тоже) и живой наблюдатель с журналом дел.
    func testPanelFeedWiringShowsStoredActivitiesForRunningObserver() async throws {
        let dir = makeTemporaryDirectory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try ActivityStore(path: dir.path + "/screen.sqlite")
        _ = try store.insert(Activity(startAt: now.addingTimeInterval(-600),
                                      endAt: now.addingTimeInterval(-300),
                                      app: "Xcode", title: "PopoverView.swift",
                                      summary: "правит панель"))
        let engine = makeIsolatedEngine()
        let observer = makeObserver(storagePath: dir.path, now: now)
        observer.start()
        defer { observer.stop() }

        // Ровно та же проводка, что и в панели: запрос дел появляется только
        // при работающем журнале экрана.
        var loadActivities: (@MainActor (Date, Date) async -> [Activity])?
        if observer.providesActivities {
            loadActivities = { from, to in await observer.activitiesAsync(from: from, to: to) }
        }
        let sources = PopoverFeedSources(
            recentIntervals: { await engine.recentIntervalsAsync(limit: $0) },
            recentSessions: { await engine.recentSessionsAsync(limit: $0) },
            live: { engine.liveFeed },
            activities: loadActivities)
        let items = await sources.load(intervalLimit: 50, sessionLimit: 10,
                                       rowLimit: 80, now: now)

        XCTAssertEqual(kinds(items), ["day", "activity"])
        withExtendedLifetime(store) {}
    }

    // MARK: инструменты ленты

    private func activity(id: Int64, at iso: String, app: String = "Xcode",
                          title: String = "PopoverView.swift",
                          summary: String = "правит панель") -> Activity {
        let at = Fmt.date(iso)!
        return Activity(id: id, startAt: at, endAt: at.addingTimeInterval(60),
                        app: app, title: title, summary: summary)
    }

    /// Виды элементов ленты по порядку — читаемая форма наблюдаемого поведения.
    private func kinds(_ items: [JournalFeedItem]?) -> [String] {
        (items ?? []).map { item in
            switch item {
            case .day: return "day"
            case .separator: return "separator"
            case .line: return "line"
            case .activity: return "activity"
            }
        }
    }

    /// Наблюдатель экрана без SCK, TCC и Ollama: кадр не снимается (провайдер
    /// бросает), поэтому тик ничего не пишет и не ходит в сеть.
    private func makeObserver(storagePath: String, now: Date) -> ScreenObserver {
        let prefs = makeIsolatedPrefs()
        // «Всегда»: конструктор не должен вычистить подготовленные делами
        // строки по сроку хранения.
        prefs.screenRetentionDays = 0
        prefs.screenEnabled = true
        return ScreenObserver(
            storagePath: storagePath,
            prefs: prefs,
            describer: IdleDescriber(),
            frameProvider: { throw VisionError.backend("кадра в прогоне нет") },
            contextProvider: { (app: "TestApp", title: "") },
            nowProvider: { now },
            enabledProvider: { true },
            periodProvider: { 600 },
            autoStart: false
        )
    }
}

/// Запоминает, о каком диапазоне дел спросила панель.
private final class RangeRecorder {
    private(set) var range: (from: Date, to: Date)?
    private(set) var calls = 0

    func record(from: Date, to: Date) {
        range = (from, to)
        calls += 1
    }
}

/// Заглушка vision-бэкенда: в этих тестах кадр не снимается, поэтому её никто
/// не зовёт — она лишь избавляет наблюдателя от реального Ollama.
private struct IdleDescriber: VisionDescriber {
    func describe(jpegBase64: String, app: String, windowTitle: String) async throws -> String { "" }
    func probe() async -> VisionProbe { .ready }
}
