import XCTest
@testable import Chronica

/// Поведенческие тесты ЧИСТОЙ логики разбора расхода памяти по категориям.
///
/// Названия категорий берём из каталога строк (`L(...)`), а не из русских
/// литералов: разбор памяти локализован вместе со всем интерфейсом.
final class MemoryBreakdownTests: XCTestCase {

    private let mb: UInt64 = 1_048_576
    private let gb: UInt64 = 1_073_741_824

    /// Категории в сумме не превышают total, а остаток уходит в рабочую память.
    func testCategoriesSumToTotal() {
        let total: UInt64 = 1_600 * mb
        let cats = MemoryBreakdownLogic.categories(
            totalBytes: total, baselineBytes: 80 * mb,
            modelWeightsBytes: 652 * mb, modelTitle: "parakeet", searchLoaded: false)
        let sum = cats.reduce(UInt64(0)) { $0 + $1.bytes }
        XCTAssertEqual(sum, total, "категории должны точно покрывать total (остаток — рабочая память)")
    }

    /// Рабочая память = total − приложение − веса (когда поиск не загружен).
    func testRuntimeMemoryIsRemainder() {
        let total: UInt64 = 1_600 * mb
        let cats = MemoryBreakdownLogic.categories(
            totalBytes: total, baselineBytes: 80 * mb,
            modelWeightsBytes: 652 * mb, modelTitle: "parakeet", searchLoaded: false)
        let runtime = cats.first { $0.title == L("memory.cat.runtime") }!
        XCTAssertEqual(runtime.bytes, total - 80 * mb - 652 * mb)
    }

    /// Загруженный поиск получает свою долю и уменьшает остаток рабочей памяти.
    func testSearchLoadedTakesShareFromRuntimeMemory() {
        let total: UInt64 = 1_900 * mb
        let off = MemoryBreakdownLogic.categories(
            totalBytes: total, baselineBytes: 80 * mb,
            modelWeightsBytes: 652 * mb, modelTitle: "p", searchLoaded: false)
        let on = MemoryBreakdownLogic.categories(
            totalBytes: total, baselineBytes: 80 * mb,
            modelWeightsBytes: 652 * mb, modelTitle: "p", searchLoaded: true)
        let searchOn = on.first { $0.title == L("memory.cat.search") }!
        let searchOff = off.first { $0.title == L("memory.cat.search") }!
        XCTAssertTrue(searchOn.present)
        XCTAssertFalse(searchOff.present)
        XCTAssertEqual(searchOn.bytes, MemoryBreakdownLogic.searchModelEstimateBytes)
        XCTAssertEqual(searchOff.bytes, 0)
        let runtimeOn = on.first { $0.title == L("memory.cat.runtime") }!.bytes
        let runtimeOff = off.first { $0.title == L("memory.cat.runtime") }!.bytes
        XCTAssertEqual(runtimeOff - runtimeOn, MemoryBreakdownLogic.searchModelEstimateBytes,
                       "доля поиска вычитается из остатка рабочей памяти")
    }

    /// Веса модели зажимаются остатком: не уходим в минус и сумма не превышает total.
    func testWeightsClampedWhenTotalSmall() {
        // total меньше, чем app + заявленные веса.
        let total: UInt64 = 400 * mb
        let cats = MemoryBreakdownLogic.categories(
            totalBytes: total, baselineBytes: 80 * mb,
            modelWeightsBytes: 652 * mb, modelTitle: "p", searchLoaded: false)
        let sum = cats.reduce(UInt64(0)) { $0 + $1.bytes }
        XCTAssertLessThanOrEqual(sum, total, "сумма не превышает total при зажатии весов")
        let runtime = cats.first { $0.title == L("memory.cat.runtime") }!
        XCTAssertEqual(runtime.bytes, 0, "остатка рабочей памяти нет, когда веса уже забрали всё")
    }

    /// Текст подсказки содержит итог и все категории; «не загружена» для поиска.
    func testSummaryTextStructure() {
        let text = MemoryBreakdownLogic.summaryText(
            totalBytes: 1_600 * mb, baselineBytes: 80 * mb,
            modelWeightsBytes: 652 * mb, modelTitle: "parakeet-tdt", searchLoaded: false)
        XCTAssertTrue(text.contains(L("memory.total",
                                      MemoryBreakdownLogic.fmtBytes(1_600 * mb))))
        XCTAssertTrue(text.contains(L("memory.cat.model", "parakeet-tdt")))
        XCTAssertTrue(text.contains(L("memory.cat.runtime")))
        XCTAssertTrue(text.contains(L("memory.cat.app")))
        // Поиск выключен → строка про ленивую загрузку вместо числа.
        XCTAssertTrue(text.contains(
            L("memory.notLoaded", L("memory.cat.search.detail"),
              MemoryBreakdownLogic.fmtBytes(MemoryBreakdownLogic.searchModelEstimateBytes))),
                      "поиск выключен → строка про лень-загрузку")
    }

    /// Форматирование размеров: МБ до 1 ГБ, дальше — ГБ.
    func testFmtBytes() {
        XCTAssertEqual(MemoryBreakdownLogic.fmtBytes(652 * mb),
                       "652 \(L("unit.megabytes"))")
        XCTAssertEqual(MemoryBreakdownLogic.fmtBytes(gb + gb / 2),
                       "1.5 \(L("unit.gigabytes"))")
    }
}
