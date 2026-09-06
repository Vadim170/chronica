import XCTest
@testable import Chronica
@testable import TranscriberCore

/// Поведенческие тесты чистых функций аналитики:
/// - кап истории метрик (#1, `Engine.appendCapped`)
/// - 24ч-бакетинг слов по часам (#6, `Activity24h.window`)
/// - покрытие (был ли интервал в часе) (#6)
/// Рантайм-движок/ASR не нужны — всё на чистых функциях.
@MainActor
final class Activity24hTests: XCTestCase {

    // MARK: - #1 кап истории метрик

    func testAppendCappedAddsSampleWhenUnderCap() {
        let h: [MetricSample] = []
        let s = MetricSample(cpu: 10, ramBytes: 100, ts: Date())
        let out = Engine.appendCapped(h, s, cap: 5)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first, s)
    }

    func testAppendCappedTrimsOldestKeepingNewest() {
        // Наполняем выше капа, проверяем что срезается с НАЧАЛА (старое уходит).
        var h: [MetricSample] = []
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<10 {
            let s = MetricSample(cpu: Float(i), ramBytes: UInt64(i),
                                 ts: base.addingTimeInterval(Double(i)))
            h = Engine.appendCapped(h, s, cap: 3)
        }
        XCTAssertEqual(h.count, 3)
        // Должны остаться последние три (cpu 7,8,9).
        XCTAssertEqual(h.map { $0.cpu }, [7, 8, 9])
    }

    func testAppendCappedExactlyAtCapKeepsAll() {
        var h: [MetricSample] = []
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<3 {
            h = Engine.appendCapped(h, MetricSample(cpu: Float(i), ramBytes: 0,
                                                    ts: base.addingTimeInterval(Double(i))), cap: 3)
        }
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.map { $0.cpu }, [0, 1, 2])
    }

    // MARK: - helpers для 24ч-тестов

    /// Календарь и зона зафиксированы для детерминизма (UTC).
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Интервал с одной дорожкой и заданным числом слов, начинающийся в `date`.
    private func interval(at date: Date, words: UInt32, parse: (Date) -> String) -> IntervalRecord {
        IntervalRecord(id: Int64(date.timeIntervalSinceReferenceDate),
                       startAt: parse(date),
                       endAt: parse(date.addingTimeInterval(30)),
                       durationS: 30,
                       channels: [ChannelText(channelId: "mic", text: "x", words: words, language: "ru")])
    }

    /// Стабильный ISO-парсер/форматер для тестов (UTC, без долей).
    private func makeIso() -> (fmt: (Date) -> String, parse: (String) -> Date?) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")!
        return ({ f.string(from: $0) }, { f.date(from: $0) })
    }

    // MARK: - #6 24ч-бакетинг

    func testWindowProduces24BucketsOldestToNewest() {
        let iso = makeIso()
        let now = iso.parse("2026-06-19T12:30:00Z")!
        let win = Activity24h.window(intervals: [], now: now,
                                     calendar: utcCalendar, parse: iso.parse)
        XCTAssertEqual(win.buckets.count, 24)
        // Старый→новый: каждый следующий бакет позже предыдущего на 1ч.
        for i in 1..<win.buckets.count {
            XCTAssertEqual(win.buckets[i].start.timeIntervalSince(win.buckets[i-1].start), 3600,
                           accuracy: 0.5)
        }
        // Последний бакет — текущий час (12:00).
        let lastHour = utcCalendar.dateInterval(of: .hour, for: now)!.start
        XCTAssertEqual(win.buckets.last!.start, lastHour)
    }

    func testWindowSumsWordsIntoCorrectHourBuckets() {
        let iso = makeIso()
        let now = iso.parse("2026-06-19T12:30:00Z")!
        // Два интервала в час 10:00 (5+7=12 слов) и один в час 12:00 (3 слова).
        let ivs = [
            interval(at: iso.parse("2026-06-19T10:05:00Z")!, words: 5, parse: iso.fmt),
            interval(at: iso.parse("2026-06-19T10:50:00Z")!, words: 7, parse: iso.fmt),
            interval(at: iso.parse("2026-06-19T12:10:00Z")!, words: 3, parse: iso.fmt),
        ]
        let win = Activity24h.window(intervals: ivs, now: now,
                                     calendar: utcCalendar, parse: iso.parse)
        XCTAssertEqual(win.totalWords, 15)
        XCTAssertEqual(win.totalIntervals, 3)

        // Час 10:00 → слова 12, активен.
        let h10 = win.buckets.first { utcCalendar.component(.hour, from: $0.start) == 10 }!
        XCTAssertEqual(h10.words, 12)
        XCTAssertTrue(h10.active)
        // Час 12:00 (последний) → слова 3.
        XCTAssertEqual(win.buckets.last!.words, 3)
        XCTAssertTrue(win.buckets.last!.active)
        // Час 11:00 → нет интервалов, неактивен, 0 слов (покрытие).
        let h11 = win.buckets.first { utcCalendar.component(.hour, from: $0.start) == 11 }!
        XCTAssertEqual(h11.words, 0)
        XCTAssertFalse(h11.active)
    }

    func testWindowCoverageReflectsActivePerHour() {
        let iso = makeIso()
        let now = iso.parse("2026-06-19T12:30:00Z")!
        let ivs = [interval(at: iso.parse("2026-06-19T09:30:00Z")!, words: 1, parse: iso.fmt)]
        let win = Activity24h.window(intervals: ivs, now: now,
                                     calendar: utcCalendar, parse: iso.parse)
        // Ровно один активный час.
        XCTAssertEqual(win.buckets.filter { $0.active }.count, 1)
        let active = win.buckets.first { $0.active }!
        XCTAssertEqual(utcCalendar.component(.hour, from: active.start), 9)
    }

    func testWindowExcludesIntervalsOutside24hWindow() {
        let iso = makeIso()
        let now = iso.parse("2026-06-19T12:30:00Z")!
        // Окно: [2026-06-18T13:00Z … 2026-06-19T13:00Z). Этот интервал — раньше.
        let old = interval(at: iso.parse("2026-06-18T08:00:00Z")!, words: 99, parse: iso.fmt)
        let win = Activity24h.window(intervals: [old], now: now,
                                     calendar: utcCalendar, parse: iso.parse)
        XCTAssertEqual(win.totalWords, 0)
        XCTAssertEqual(win.totalIntervals, 0)
        XCTAssertTrue(win.buckets.allSatisfy { !$0.active })
    }
}
