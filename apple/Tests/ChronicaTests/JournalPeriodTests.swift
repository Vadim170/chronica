import XCTest
@testable import Chronica

/// Поведенческие тесты связки «пикер периода → границы запроса» и выбора
/// гранулярности графика активности.
///
/// Контракт хранилища: времена лежат как ISO-8601 со смещением ЛОКАЛЬНОЙ зоны,
/// а SQLite сравнивает границы лексикографически. Значит границы обязаны быть
/// в той же зоне и в том же формате — иначе сегодняшние записи выпадают из
/// диапазона (историческая причина бага «нет голосовой активности»).
final class JournalPeriodTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    // MARK: границы периода

    func testPeriodStartsAtBeginningOfFirstDay() {
        let bounds = JournalPeriod.bounds(from: day(2026, 6, 19, hour: 17),
                                          to: day(2026, 6, 19, hour: 23),
                                          calendar: calendar)
        XCTAssertEqual(bounds.start, calendar.startOfDay(for: day(2026, 6, 19)))
    }

    func testPeriodIncludesTheWholeLastDay() {
        // Верхняя граница — начало СЛЕДУЮЩЕГО дня: полуинтервал [start, end).
        let bounds = JournalPeriod.bounds(from: day(2026, 6, 18),
                                          to: day(2026, 6, 19, hour: 1),
                                          calendar: calendar)
        XCTAssertEqual(bounds.end, calendar.startOfDay(for: day(2026, 6, 20)))
        XCTAssertTrue(bounds.end > day(2026, 6, 19, hour: 23))
    }

    func testReversedSelectionStillYieldsNonEmptyPeriod() {
        // «по» раньше «от» — пользователь мог покрутить пикеры в любом порядке.
        let bounds = JournalPeriod.bounds(from: day(2026, 6, 20),
                                          to: day(2026, 6, 18),
                                          calendar: calendar)
        XCTAssertLessThan(bounds.start, bounds.end)
        XCTAssertEqual(bounds.start, calendar.startOfDay(for: day(2026, 6, 18)))
        XCTAssertEqual(bounds.end, calendar.startOfDay(for: day(2026, 6, 21)))
    }

    func testSingleDayPeriodCoversExactlyOneDay() {
        let bounds = JournalPeriod.bounds(from: day(2026, 6, 19),
                                          to: day(2026, 6, 19),
                                          calendar: calendar)
        let hours = bounds.end.timeIntervalSince(bounds.start) / 3600
        // Сутки; в дни перевода часов — 23 или 25 часов, это норма.
        XCTAssertTrue((23...25).contains(hours), "ожидались сутки, получили \(hours) ч")
    }

    // MARK: ISO-границы

    func testIsoBoundsUseLocalOffsetNotUtcZulu() {
        let iso = JournalPeriod.isoBounds(from: day(2026, 6, 19),
                                          to: day(2026, 6, 19),
                                          calendar: calendar)
        for bound in [iso.start, iso.end] {
            XCTAssertFalse(bound.hasSuffix("Z"),
                           "UTC-суффикс ломает лексикографическое сравнение в SQLite")
            XCTAssertEqual(bound, Fmt.queryBound(Fmt.date(bound)!))
        }
        XCTAssertLessThan(iso.start, iso.end, "строки сравнимы лексикографически")
    }

    func testIsoBoundsMatchDateBounds() {
        let bounds = JournalPeriod.bounds(from: day(2026, 1, 5), to: day(2026, 1, 7),
                                          calendar: calendar)
        let iso = JournalPeriod.isoBounds(from: day(2026, 1, 5), to: day(2026, 1, 7),
                                          calendar: calendar)
        XCTAssertEqual(iso.start, Fmt.queryBound(bounds.start))
        XCTAssertEqual(iso.end, Fmt.queryBound(bounds.end))
    }

    // MARK: гранулярность графика

    func testShortPeriodsAreCharedByHour() {
        XCTAssertTrue(JournalPeriod.isHourly(from: day(2026, 6, 19), to: day(2026, 6, 19),
                                             calendar: calendar))
        // Двое суток — ещё по часам (48 столбцов читаются).
        XCTAssertTrue(JournalPeriod.isHourly(from: day(2026, 6, 18), to: day(2026, 6, 19),
                                             calendar: calendar))
    }

    func testLongPeriodsSwitchToDays() {
        XCTAssertFalse(JournalPeriod.isHourly(from: day(2026, 6, 17), to: day(2026, 6, 19),
                                              calendar: calendar))
        XCTAssertFalse(JournalPeriod.isHourly(from: day(2026, 5, 19), to: day(2026, 6, 19),
                                              calendar: calendar))
    }

    // MARK: прореживание подписей оси

    func testThinningKeepsFirstAndLastLabels() {
        let labels = (0..<50).map { "L\($0)" }
        let out = ChartLabels.thinned(labels, maxVisible: 8)
        XCTAssertEqual(out.first, "L0")
        XCTAssertEqual(out.last, "L49")
        XCTAssertLessThanOrEqual(out.count, 9, "не больше цели плюс правый край")
    }

    func testShortLabelListIsNotThinned() {
        let labels = ["A", "B", "C"]
        XCTAssertEqual(ChartLabels.thinned(labels, maxVisible: 8), labels)
    }
}

/// Настройки журнала экрана: частота и срок хранения выбираются пунктами
/// пикера, а хранятся числами — проверяем обе стороны отображения.
final class ScreenSettingsChoiceTests: XCTestCase {

    func testPeriodChoiceMapsToSeconds() {
        XCTAssertEqual(ScreenPeriodChoice.oneMinute.seconds, 60)
        XCTAssertEqual(ScreenPeriodChoice.twoMinutes.seconds, 120)
        XCTAssertEqual(ScreenPeriodChoice.fiveMinutes.seconds, 300)
        XCTAssertEqual(ScreenPeriodChoice.tenMinutes.seconds, 600)
    }

    func testSavedSecondsSelectTheirOwnChoice() {
        for choice in ScreenPeriodChoice.allCases {
            XCTAssertEqual(ScreenPeriodChoice.nearest(toSeconds: choice.seconds), choice)
        }
    }

    func testLegacySliderValueSnapsToNearestChoice() {
        // Старый слайдер писал произвольные секунды — показываем ближайший пункт.
        XCTAssertEqual(ScreenPeriodChoice.nearest(toSeconds: 90), .oneMinute)
        XCTAssertEqual(ScreenPeriodChoice.nearest(toSeconds: 100), .twoMinutes)
        XCTAssertEqual(ScreenPeriodChoice.nearest(toSeconds: 540), .tenMinutes)
    }

    func testBrokenPeriodValueFallsBackInsteadOfCrashing() {
        XCTAssertEqual(ScreenPeriodChoice.nearest(toSeconds: .nan), .oneMinute)
    }

    func testRetentionChoiceMapsToDaysWithForeverAsZero() {
        XCTAssertEqual(ScreenRetentionChoice.month.days, 30)
        XCTAssertEqual(ScreenRetentionChoice.quarter.days, 90)
        XCTAssertEqual(ScreenRetentionChoice.halfYear.days, 180)
        XCTAssertEqual(ScreenRetentionChoice.forever.days, 0,
                       "0 дней = «всегда»: чистка журнала не запускается")
    }

    func testSavedRetentionSelectsItsOwnChoice() {
        for choice in ScreenRetentionChoice.allCases {
            XCTAssertEqual(ScreenRetentionChoice.nearest(toDays: choice.days), choice)
        }
    }

    func testUnknownRetentionSnapsToNearestFiniteChoice() {
        XCTAssertEqual(ScreenRetentionChoice.nearest(toDays: 45), .month)
        XCTAssertEqual(ScreenRetentionChoice.nearest(toDays: 200), .halfYear)
        XCTAssertEqual(ScreenRetentionChoice.nearest(toDays: -5), .forever)
    }
}
