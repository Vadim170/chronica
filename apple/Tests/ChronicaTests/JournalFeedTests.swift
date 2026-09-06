import XCTest
@testable import Chronica
@testable import TranscriberCore

/// Поведенческие тесты ЕДИНОЙ ленты журнала.
///
/// Проверяется наблюдаемое поведение: что и в каком порядке видит человек,
/// где встают разделители сессий и что происходит с пустотой и лимитом.
/// Формулировки подписей здесь не проверяются — они живут в каталоге строк.
final class JournalFeedTests: XCTestCase {

    // MARK: инструменты

    /// Календарь с фиксированной зоной: заголовки дней не должны зависеть от
    /// настроек машины, на которой идёт прогон.
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// ISO-строка «того же дня» по времени `ЧЧ:ММ:СС` (зона UTC).
    private func iso(_ time: String, day: String = "2026-06-19") -> String {
        "\(day)T\(time)Z"
    }

    private func date(_ time: String, day: String = "2026-06-19") -> Date {
        Fmt.date(iso(time, day: day))!
    }

    private func interval(id: Int64, at time: String, day: String = "2026-06-19",
                          text: String = "речь",
                          channel: String = Channels.mic,
                          words: UInt32? = nil) -> IntervalRecord {
        IntervalRecord(
            id: id,
            startAt: iso(time, day: day),
            endAt: iso(time, day: day),
            durationS: 30,
            channels: [ChannelText(channelId: channel, text: text,
                                   words: words ?? (text.isEmpty ? 0 : 1),
                                   language: "ru")])
    }

    private func session(id: Int64, from: String, to: String = "",
                         day: String = "2026-06-19",
                         reason: String = SessionStopReason.user) -> SessionRecord {
        SessionRecord(id: id,
                      startedAt: iso(from, day: day),
                      endedAt: to.isEmpty ? "" : iso(to, day: day),
                      stopReason: to.isEmpty ? "" : reason)
    }

    private func activity(id: Int64, at time: String, day: String = "2026-06-19",
                          app: String = "Xcode", title: String = "JournalFeed.swift",
                          summary: String = "правит ленту журнала") -> Activity {
        Activity(id: id,
                 startAt: date(time, day: day),
                 endAt: date(time, day: day),
                 app: app, title: title, summary: summary)
    }

    private func build(intervals: [IntervalRecord] = [],
                       activities: [Activity] = [],
                       sessions: [SessionRecord] = [],
                       now: Date? = nil) -> [JournalFeedItem] {
        JournalFeed.build(intervals: intervals, activities: activities,
                          sessions: sessions,
                          now: now ?? date("23:59:59"),
                          calendar: utc)
    }

    /// Виды разделителей ленты сверху вниз.
    private func separatorKinds(_ items: [JournalFeedItem]) -> [JournalSeparator.Kind] {
        items.compactMap { if case .separator(let s) = $0 { return s.kind } else { return nil } }
    }

    /// Идентификаторы содержательных элементов сверху вниз.
    private func contentIds(_ items: [JournalFeedItem]) -> [String] {
        items.filter(\.isContent).map(\.id)
    }

    // MARK: порядок и смешение

    /// Реплики и дела идут ОДНОЙ лентой по времени, новое сверху.
    func testRepliesAndActivitiesShareOneTimeline() {
        let items = build(
            intervals: [interval(id: 1, at: "10:00:00"), interval(id: 2, at: "12:00:00")],
            activities: [activity(id: 7, at: "11:00:00")])

        XCTAssertEqual(contentIds(items),
                       ["line-2-mic", "activity-7", "line-1-mic"])
    }

    /// Интервал разворачивается в реплику НА КАЖДУЮ непустую дорожку.
    func testEveryNonEmptyChannelBecomesItsOwnLine() {
        let record = IntervalRecord(
            id: 5, startAt: iso("10:00:00"), endAt: iso("10:00:30"), durationS: 30,
            channels: [ChannelText(channelId: Channels.mic, text: "я", words: 1, language: "ru"),
                       ChannelText(channelId: Channels.remote, text: "он", words: 1, language: "ru"),
                       ChannelText(channelId: "other", text: "", words: 0, language: "ru")])

        let items = build(intervals: [record])

        XCTAssertEqual(Set(contentIds(items)), ["line-5-mic", "line-5-remote"])
    }

    /// Пустые интервалы скрыты по тому же правилу, что и в Истории.
    func testEmptyIntervalsAreHiddenByHistoryLogicRule() {
        let silent = interval(id: 1, at: "10:00:00", text: "")
        let bogus = interval(id: 2, at: "11:00:00", text: "", words: 5)
        let spoken = interval(id: 3, at: "12:00:00", text: "слово")

        let items = build(intervals: [silent, bogus, spoken])

        XCTAssertEqual(contentIds(items), ["line-3-mic"])
    }

    /// Элементы, попавшие на ОДНУ И ТУ ЖЕ секунду, не теряются и не
    /// схлопываются: раньше такое различалось только по времени.
    func testItemsSharingTheSameSecondAreAllKept() {
        let items = build(
            intervals: [interval(id: 1, at: "10:00:00", text: "первая"),
                        interval(id: 2, at: "10:00:00", text: "вторая"),
                        interval(id: 3, at: "10:00:00", text: "третья")],
            activities: [activity(id: 9, at: "10:00:00")])

        XCTAssertEqual(contentIds(items).count, 4)
        XCTAssertEqual(Set(contentIds(items)),
                       ["line-1-mic", "line-2-mic", "line-3-mic", "activity-9"])
    }

    // MARK: разделители сессий

    /// Разделитель встаёт РОВНО на границу: «включена» — под первой репликой
    /// сессии, «остановлена» — над последней, даже если секунда совпадает.
    func testSeparatorsSitExactlyOnTheSessionBoundary() {
        let items = build(
            intervals: [interval(id: 1, at: "12:00:00", text: "первая"),
                        interval(id: 2, at: "12:05:00", text: "последняя")],
            sessions: [session(id: 1, from: "12:00:00", to: "12:05:00")])

        let visible = items.filter { !$0.isDayHeader }.map(\.id)
        XCTAssertEqual(visible, ["session-1-stopped", "line-2-mic",
                                 "line-1-mic", "session-1-started"])
    }

    /// Незакрытая сессия, после которой была другая, — это «приложение
    /// закрылось»: процесс убили, штатной остановки никто не записал.
    func testUnclosedSessionYieldsAppClosedSeparator() {
        let items = build(
            intervals: [interval(id: 1, at: "10:05:00"), interval(id: 2, at: "12:05:00")],
            sessions: [session(id: 1, from: "10:00:00"),
                       session(id: 2, from: "12:00:00", to: "12:30:00")])

        XCTAssertTrue(separatorKinds(items).contains(.appClosed),
                      "у незакрытой сессии обязана быть граница «приложение закрылось»")
        // Граница стоит по последней записи мёртвой сессии — прямо над ней.
        let ids = items.filter { !$0.isDayHeader }.map(\.id)
        let closed = try? XCTUnwrap(ids.firstIndex(of: "session-1-appClosed"))
        let lastLine = try? XCTUnwrap(ids.firstIndex(of: "line-1-mic"))
        XCTAssertEqual(closed.map { $0 + 1 }, lastLine)
    }

    /// Сессия, оборванная аварийно, подписана «сбой записи», а не «остановлена».
    func testFailedSessionYieldsFailureSeparator() {
        let items = build(
            intervals: [interval(id: 1, at: "12:00:00")],
            sessions: [session(id: 1, from: "11:59:00", to: "12:01:00",
                               reason: SessionStopReason.error)])

        XCTAssertEqual(separatorKinds(items), [.failed, .started])
    }

    /// Идущая СЕЙЧАС запись (самая свежая незакрытая сессия) не подписывается
    /// «приложение закрылось»: она никуда не делась.
    func testCurrentUnclosedSessionHasNoEndSeparator() {
        let items = build(
            intervals: [interval(id: 1, at: "12:00:00")],
            sessions: [session(id: 1, from: "11:59:00")],
            now: date("12:01:00"))

        XCTAssertEqual(separatorKinds(items), [.started])
    }

    /// Две сессии подряд, между которыми ничего не записано, дают ОДНУ линию,
    /// а не четыре.
    func testBackToBackSessionsWithoutContentCollapseToOneSeparator() {
        let items = build(
            intervals: [interval(id: 1, at: "09:50:00", text: "до"),
                        interval(id: 2, at: "12:00:00", text: "после")],
            sessions: [session(id: 1, from: "10:00:00", to: "10:30:00"),
                       session(id: 2, from: "11:00:00", to: "11:30:00")])

        XCTAssertEqual(separatorKinds(items).count, 1,
                       "между двумя репликами не должно быть двух линий подряд")
        XCTAssertEqual(contentIds(items), ["line-2-mic", "line-1-mic"])
    }

    /// Схлопывание сохраняет САМУЮ ГОВОРЯЩУЮ границу: сбой объясняет пропуск в
    /// ленте, а «запись включена» рядом с ним — уже подробность.
    func testCollapsingKeepsTheMostTellingSeparator() {
        let items = build(
            intervals: [interval(id: 1, at: "09:00:00", text: "до"),
                        interval(id: 2, at: "13:00:00", text: "после")],
            sessions: [session(id: 1, from: "09:30:00", to: "10:00:00",
                               reason: SessionStopReason.error),
                       session(id: 2, from: "12:00:00", to: "12:30:00")])

        XCTAssertEqual(separatorKinds(items), [.failed])
    }

    // MARK: пустота, дни, лимит

    /// Ничего нет — лента пуста, и вью показывает пустое состояние. Одинокие
    /// разделители лентой не считаются: это границы МЕЖДУ записями.
    func testEmptyInputGivesEmptyFeed() {
        XCTAssertTrue(build().isEmpty)
        XCTAssertTrue(build(sessions: [session(id: 1, from: "10:00:00", to: "11:00:00")]).isEmpty)
        XCTAssertTrue(build(intervals: [interval(id: 1, at: "10:00:00", text: "")]).isEmpty)
    }

    /// На стыке суток остаётся заголовок дня.
    func testDayHeaderAppearsOnEveryDayBoundary() {
        let items = build(intervals: [interval(id: 1, at: "23:00:00", day: "2026-06-18"),
                                      interval(id: 2, at: "01:00:00", day: "2026-06-19")])

        let days = items.compactMap { item -> Date? in
            if case .day(let date) = item { return date } else { return nil }
        }
        XCTAssertEqual(days, [utc.startOfDay(for: date("01:00:00", day: "2026-06-19")),
                              utc.startOfDay(for: date("23:00:00", day: "2026-06-18"))])
        XCTAssertTrue(items.first?.isDayHeader == true, "день открывает свою группу")
    }

    /// Лимит панели режет ХВОСТ (старое), а не голову: открывают панель ради
    /// свежих реплик.
    func testPanelLimitCutsTheTailNotTheHead() {
        let intervals = (1...30).map {
            interval(id: Int64($0), at: String(format: "10:%02d:00", $0), text: "строка \($0)")
        }
        let full = build(intervals: intervals)

        let capped = JournalFeed.capped(full, limit: 5)

        XCTAssertEqual(capped.count, 5)
        XCTAssertEqual(capped, Array(full.prefix(5)))
        XCTAssertEqual(contentIds(capped).first, "line-30-mic", "голова — самое свежее")
        XCTAssertFalse(contentIds(capped).contains("line-1-mic"), "хвост обрезан")
    }

    /// Лимит не оставляет висящий заголовок дня без единой записи под ним.
    func testCappingDropsADanglingDayHeader() {
        let items = build(intervals: [interval(id: 1, at: "23:00:00", day: "2026-06-18"),
                                      interval(id: 2, at: "01:00:00", day: "2026-06-19")])
        // Прямо на границе суток: срез пришёлся бы на заголовок второго дня.
        let capped = JournalFeed.capped(items, limit: 3)

        XCTAssertFalse(capped.last?.isDayHeader ?? true)
        XCTAssertTrue(capped.last?.isContent ?? false)
    }

    /// Лента короче лимита остаётся нетронутой; нулевой лимит — пусто.
    func testCappingIsANoOpBelowTheLimit() {
        let items = build(intervals: [interval(id: 1, at: "10:00:00")])
        XCTAssertEqual(JournalFeed.capped(items, limit: 100), items)
        XCTAssertTrue(JournalFeed.capped(items, limit: 0).isEmpty)
    }

    // MARK: поиск по делам

    func testActivitySearchLooksAtAppTitleAndSummary() {
        let item = activity(id: 1, at: "10:00:00", app: "Safari",
                            title: "Pull request #12", summary: "читает ревью")

        XCTAssertTrue(JournalFeed.matches(item, query: ""))
        XCTAssertTrue(JournalFeed.matches(item, query: "   "))
        XCTAssertTrue(JournalFeed.matches(item, query: "safari"))
        XCTAssertTrue(JournalFeed.matches(item, query: "PULL"))
        XCTAssertTrue(JournalFeed.matches(item, query: "ревью"))
        XCTAssertFalse(JournalFeed.matches(item, query: "терминал"))
    }
}
