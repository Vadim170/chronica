import XCTest
@testable import Chronica

/// Поведенческие тесты связки «пикер периода → границы запроса» и выбора
/// гранулярности графика активности.
///
/// Контракт: пикеры дают ДНИ, а границы запроса — это локальная полночь суток
/// пользователя (начало дня «от» и начало дня, следующего за «по»). Времена в
/// хранилище лежат как ISO-8601 со смещением той же локальной зоны, поэтому
/// граница обязана нести смещение своей зоны, а не быть пересчитанной в UTC.
///
/// Зона задаётся ЯВНО и каждый инвариант прогоняется в нескольких зонах —
/// положительной, нулевой и отрицательной. Зона машины прогона (у CI это UTC,
/// у разработчика — Europe/Moscow) на результат не влияет, и нулевое смещение
/// (`Z`) само по себе ошибкой не считается: для зоны UTC это правильный ответ.
final class JournalPeriodTests: XCTestCase {

    /// Зоны прогона: +03:00, нулевая, −08/−07 (знак смещения) и +14:00
    /// (крайний восток — ловит переполнение суток).
    private static let zones: [TimeZone] = [
        TimeZone(identifier: "Europe/Moscow")!,
        TimeZone(identifier: "UTC")!,
        TimeZone(identifier: "America/Los_Angeles")!,
        TimeZone(identifier: "Pacific/Kiritimati")!,
    ]

    private func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12,
                     in zone: TimeZone) -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    /// Прогоняет проверку во всех зонах. Имя зоны идёт в сообщение каждого
    /// ассерта, поэтому по падению видно, какая именно зона сломалась.
    private func inEachZone(_ body: (TimeZone, Calendar) -> Void) {
        for zone in Self.zones { body(zone, calendar(zone)) }
    }

    // MARK: границы периода

    func testPeriodStartsAtBeginningOfFirstDay() {
        inEachZone { zone, calendar in
            let bounds = JournalPeriod.bounds(from: day(2026, 6, 19, hour: 17, in: zone),
                                              to: day(2026, 6, 19, hour: 23, in: zone),
                                              calendar: calendar)
            XCTAssertEqual(bounds.start,
                           calendar.startOfDay(for: day(2026, 6, 19, in: zone)),
                           zone.identifier)
        }
    }

    func testPeriodIncludesTheWholeLastDay() {
        // Верхняя граница — начало СЛЕДУЮЩЕГО дня: полуинтервал [start, end).
        inEachZone { zone, calendar in
            let bounds = JournalPeriod.bounds(from: day(2026, 6, 18, in: zone),
                                              to: day(2026, 6, 19, hour: 1, in: zone),
                                              calendar: calendar)
            XCTAssertEqual(bounds.end,
                           calendar.startOfDay(for: day(2026, 6, 20, in: zone)),
                           zone.identifier)
            XCTAssertTrue(bounds.end > day(2026, 6, 19, hour: 23, in: zone), zone.identifier)
        }
    }

    func testReversedSelectionStillYieldsNonEmptyPeriod() {
        // «по» раньше «от» — пользователь мог покрутить пикеры в любом порядке.
        inEachZone { zone, calendar in
            let bounds = JournalPeriod.bounds(from: day(2026, 6, 20, in: zone),
                                              to: day(2026, 6, 18, in: zone),
                                              calendar: calendar)
            XCTAssertLessThan(bounds.start, bounds.end, zone.identifier)
            XCTAssertEqual(bounds.start,
                           calendar.startOfDay(for: day(2026, 6, 18, in: zone)),
                           zone.identifier)
            XCTAssertEqual(bounds.end,
                           calendar.startOfDay(for: day(2026, 6, 21, in: zone)),
                           zone.identifier)
        }
    }

    func testSingleDayPeriodCoversExactlyOneDay() {
        inEachZone { zone, calendar in
            let bounds = JournalPeriod.bounds(from: day(2026, 6, 19, in: zone),
                                              to: day(2026, 6, 19, in: zone),
                                              calendar: calendar)
            let hours = bounds.end.timeIntervalSince(bounds.start) / 3600
            // Сутки; в дни перевода часов — 23 или 25 часов, это норма.
            XCTAssertTrue((23...25).contains(hours),
                          "\(zone.identifier): ожидались сутки, получили \(hours) ч")
        }
    }

    // MARK: ISO-границы

    /// Главный инвариант: граница — это ЛОКАЛЬНАЯ полночь заданной зоны,
    /// записанная со смещением этой же зоны. Пересчёт в UTC («2026-06-18T21:00»
    /// вместо «2026-06-19T00:00+03:00») ломает выборку суток — исторический баг
    /// «нет голосовой активности».
    func testIsoBoundsAreLocalMidnightOfTheGivenZone() {
        inEachZone { zone, calendar in
            let iso = JournalPeriod.isoBounds(from: day(2026, 6, 19, in: zone),
                                              to: day(2026, 6, 19, in: zone),
                                              calendar: calendar)
            // Стенные часы в строке — ровно полночь нужных суток.
            XCTAssertTrue(iso.start.hasPrefix("2026-06-19T00:00:00"),
                          "\(zone.identifier): начало периода не полночь — \(iso.start)")
            XCTAssertTrue(iso.end.hasPrefix("2026-06-20T00:00:00"),
                          "\(zone.identifier): конец периода не полночь — \(iso.end)")
            // …и это та же точка времени, что и Date-граница: значит смещение
            // в строке — смещение ЭТОЙ зоны, а не чужой.
            let bounds = JournalPeriod.bounds(from: day(2026, 6, 19, in: zone),
                                              to: day(2026, 6, 19, in: zone),
                                              calendar: calendar)
            XCTAssertEqual(Fmt.date(iso.start), bounds.start, zone.identifier)
            XCTAssertEqual(Fmt.date(iso.end), bounds.end, zone.identifier)
            XCTAssertLessThan(Fmt.date(iso.start)!, Fmt.date(iso.end)!, zone.identifier)
        }
    }

    /// Нулевое смещение — законный ответ для зоны UTC (и `Z`, и `+00:00`
    /// разбираются в ту же точку). Ошибкой считается только чужое смещение.
    func testZeroOffsetZoneKeepsMidnightAndIsNotAnError() {
        let utc = TimeZone(identifier: "UTC")!
        let iso = JournalPeriod.isoBounds(from: day(2026, 6, 19, in: utc),
                                          to: day(2026, 6, 19, in: utc),
                                          calendar: calendar(utc))
        XCTAssertEqual(Fmt.date(iso.start),
                       calendar(utc).startOfDay(for: day(2026, 6, 19, in: utc)))
        XCTAssertTrue(iso.start.hasSuffix("Z") || iso.start.hasSuffix("+00:00"),
                      "нулевая зона обязана писать нулевое смещение — \(iso.start)")
    }

    func testIsoBoundsMatchDateBounds() {
        inEachZone { zone, calendar in
            let bounds = JournalPeriod.bounds(from: day(2026, 1, 5, in: zone),
                                              to: day(2026, 1, 7, in: zone),
                                              calendar: calendar)
            let iso = JournalPeriod.isoBounds(from: day(2026, 1, 5, in: zone),
                                              to: day(2026, 1, 7, in: zone),
                                              calendar: calendar)
            XCTAssertEqual(iso.start, Fmt.queryBound(bounds.start, timeZone: zone),
                           zone.identifier)
            XCTAssertEqual(iso.end, Fmt.queryBound(bounds.end, timeZone: zone),
                           zone.identifier)
        }
    }

    /// Зона пользователя — дефолт: без явного аргумента обе перегрузки
    /// `Fmt.queryBound` обязаны давать одну строку.
    func testDefaultZoneIsTheUserZone() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(Fmt.queryBound(date),
                       Fmt.queryBound(date, timeZone: TimeZone.current))
    }

    // MARK: гранулярность графика

    func testShortPeriodsAreCharedByHour() {
        inEachZone { zone, calendar in
            XCTAssertTrue(JournalPeriod.isHourly(from: day(2026, 6, 19, in: zone),
                                                 to: day(2026, 6, 19, in: zone),
                                                 calendar: calendar), zone.identifier)
            // Двое суток — ещё по часам (48 столбцов читаются).
            XCTAssertTrue(JournalPeriod.isHourly(from: day(2026, 6, 18, in: zone),
                                                 to: day(2026, 6, 19, in: zone),
                                                 calendar: calendar), zone.identifier)
        }
    }

    func testLongPeriodsSwitchToDays() {
        inEachZone { zone, calendar in
            XCTAssertFalse(JournalPeriod.isHourly(from: day(2026, 6, 17, in: zone),
                                                  to: day(2026, 6, 19, in: zone),
                                                  calendar: calendar), zone.identifier)
            XCTAssertFalse(JournalPeriod.isHourly(from: day(2026, 5, 19, in: zone),
                                                  to: day(2026, 6, 19, in: zone),
                                                  calendar: calendar), zone.identifier)
        }
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
