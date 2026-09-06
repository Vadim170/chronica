import XCTest
@testable import Chronica

/// Тесты чистых форматтеров метрик (#4): CPU «текущий · мед · p90», RAM
/// «текущий · пик» и подпись потерь аудио. Рантайм-движок не требуется.
///
/// Тексты собираются из ключей каталога (`L(...)`), а не из русских литералов:
/// интерфейс локализован, и тест не должен зависеть от языка сборки. Формы
/// русской плюрализации проверяет `LocalizationLookupTests`.
final class MetricFormatTests: XCTestCase {

    // MARK: CPU

    func testCpuLineFormatsCurrentMedianAndP90() {
        XCTAssertEqual(Fmt.cpuLine(current: 38, p50: 22, p90: 61),
                       "38% · \(L("metric.median.short")) 22% · p90 61%")
    }

    func testCpuLineRoundsAndClampsNegativesToZero() {
        XCTAssertEqual(Fmt.cpuLine(current: 37.6, p50: -1, p90: 60.4),
                       "38% · \(L("metric.median.short")) 0% · p90 60%")
    }

    // MARK: RAM

    func testRamLineShowsPeakOnlyWhenGreater() {
        // Пик строго больше текущего — показываем оба.
        let s = Fmt.ramLine(current: 1_181_116_006 /* ~1.1 ГБ */,
                            peak: 1_503_238_553 /* ~1.4 ГБ */)
        XCTAssertEqual(s, "1.1 \(L("unit.gigabytes")) · \(L("metric.peak.short")) "
                       + "1.4 \(L("unit.gigabytes"))")
    }

    func testRamLineHidesPeakWhenNotGreater() {
        // Пик == текущему → дублировать бессмысленно, показываем только текущий.
        let cur: UInt64 = 1_181_116_006
        XCTAssertEqual(Fmt.ramLine(current: cur, peak: cur), "1.1 \(L("unit.gigabytes"))")
        // Пик меньше (теоретически) → тоже только текущий.
        XCTAssertEqual(Fmt.ramLine(current: cur, peak: cur - 1000),
                       "1.1 \(L("unit.gigabytes"))")
    }

    func testMemBytesUsesMegabytesBelowOneGigabyte() {
        XCTAssertEqual(Fmt.memBytes(524_288_000 /* 500 МБ */), "500 \(L("unit.megabytes"))")
        XCTAssertEqual(Fmt.memBytes(0), "0 \(L("unit.megabytes"))")
    }

    // MARK: потери аудио

    func testDroppedAudioHiddenWhenZero() {
        // 0 потерь → показатель скрываем совсем (#4).
        XCTAssertNil(Fmt.droppedAudioSeconds(0))
        XCTAssertNil(Fmt.droppedAudioLine(0))
    }

    func testDroppedAudioConvertsSamplesToSeconds() {
        // 32000 сэмплов при 16 кГц = 2 с.
        XCTAssertEqual(Fmt.droppedAudioSeconds(32_000), 2)
        XCTAssertEqual(Fmt.droppedAudioLine(32_000), L("metric.droppedAudio", 2))
    }

    func testDroppedAudioNeverRoundsNonZeroLossToZero() {
        // Меньше половины секунды потерь — всё равно показываем минимум 1с,
        // чтобы ненулевые потери не «исчезали» из-за округления.
        XCTAssertEqual(Fmt.droppedAudioSeconds(100), 1)
        XCTAssertEqual(Fmt.droppedAudioLine(8_000), L("metric.droppedAudio", 1)) // 0.5с → 1с
    }

    // MARK: потерянные интервалы

    func testDroppedIntervalsHiddenWhenZero() {
        // В норме потерь нет — строки в диагностике быть не должно вовсе.
        XCTAssertNil(Fmt.droppedIntervalsLine(0))
    }

    func testDroppedIntervalsAreNamedWithTheirCount() throws {
        let line = try XCTUnwrap(Fmt.droppedIntervalsLine(3))
        XCTAssertEqual(line, L("metric.droppedIntervals", 3))
        XCTAssertTrue(line.contains(L10nTestSupport.localizedNumber(3)),
                      "число потерянных интервалов обязано быть в строке")
    }

    // MARK: сводка по хранилищу

    func testStoreLineShowsSizeAndRecordCount() {
        let line = Fmt.storeLine(sizeBytes: 44_040_192 /* 42 МБ */,
                                 walBytes: 0, intervals: 137)
        XCTAssertEqual(line, L("metric.storeLine",
                               "42 \(L("unit.megabytes"))",
                               L("metric.records", 137)))
        // «42» приходит из `memBytes` (не локализуется), «137» — через
        // локализованный формат, поэтому его цифры региональные.
        XCTAssertTrue(line.contains("42"))
        XCTAssertTrue(line.contains(L10nTestSupport.localizedNumber(137)))
    }

    func testStoreLineCountsWalTowardsDiskUsage() {
        // WAL лежит рядом с базой и занимает место — пользователь видит сумму.
        let withWal = Fmt.storeLine(sizeBytes: 1_048_576, walBytes: 1_048_576, intervals: 1)
        let withoutWal = Fmt.storeLine(sizeBytes: 1_048_576, walBytes: 0, intervals: 1)
        XCTAssertNotEqual(withWal, withoutWal)
        XCTAssertEqual(withWal, L("metric.storeLine",
                                  "2 \(L("unit.megabytes"))",
                                  L("metric.records", 1)))
    }

    /// Форма слова у числа приходит из plural-варианта каталога, а не из
    /// самописной функции: 1 запись · 2 записи · 5 записей.
    func testRecordCountUsesPluralVariations() throws {
        for count: Int64 in [0, 1, 2, 5, 11, 21, 112] {
            let line = Fmt.storeLine(sizeBytes: 0, walBytes: 0, intervals: count)
            XCTAssertTrue(line.contains(L("metric.records", Int(count))),
                          "«\(line)» не содержит форму для \(count)")
        }
        // Разные числа дают разные формы хотя бы для 1 и 5.
        XCTAssertNotEqual(try L10nTestSupport.format("metric.records", language: "ru", 1),
                          try L10nTestSupport.format("metric.records", language: "ru", 5))
    }

    func testEmptyStoreIsStillReadable() {
        XCTAssertEqual(Fmt.storeLine(sizeBytes: 0, walBytes: 0, intervals: 0),
                       L("metric.storeLine",
                         "0 \(L("unit.megabytes"))",
                         L("metric.records", 0)))
    }
}
