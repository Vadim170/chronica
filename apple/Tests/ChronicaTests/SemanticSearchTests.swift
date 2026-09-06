import XCTest
import TranscriberCore
@testable import Chronica

/// Поведенческие тесты ЧИСТОЙ логики комбинирования/ранжирования
/// семантического поиска. NLEmbedding НЕ тестируем — сигналы инъектируем
/// напрямую через `SearchSignals`.
final class SemanticSearchTests: XCTestCase {

    // MARK: helpers

    private func signals(exact: Double = 0, fuzzy: Double = 0, semantic: Double = 0) -> SearchSignals {
        SearchSignals(exact: exact, fuzzy: fuzzy, semantic: semantic)
    }

    // MARK: combinedScore — монотонность по каждому сигналу

    func testCombinedScoreMonotonicInExact() {
        let lo = SemanticRanking.combinedScore(signals(exact: 0, fuzzy: 0.5, semantic: 0.5))
        let hi = SemanticRanking.combinedScore(signals(exact: 1, fuzzy: 0.5, semantic: 0.5))
        XCTAssertGreaterThan(hi, lo)
    }

    func testCombinedScoreMonotonicInFuzzy() {
        let lo = SemanticRanking.combinedScore(signals(exact: 0, fuzzy: 0.2, semantic: 0.5))
        let hi = SemanticRanking.combinedScore(signals(exact: 0, fuzzy: 0.8, semantic: 0.5))
        XCTAssertGreaterThan(hi, lo)
    }

    func testCombinedScoreMonotonicInSemantic() {
        let lo = SemanticRanking.combinedScore(signals(exact: 0, fuzzy: 0.5, semantic: 0.1))
        let hi = SemanticRanking.combinedScore(signals(exact: 0, fuzzy: 0.5, semantic: 0.9))
        XCTAssertGreaterThan(hi, lo)
    }

    // MARK: exact доминирует над чисто-семантическим

    func testExactOutranksPurelySemantic() {
        // id=1: только семантика (максимальная). id=2: только дословное.
        // Дословное обязано встать выше — вне зависимости от силы семантики.
        let order = SemanticRanking.rank([
            (id: 1, signals: signals(semantic: 1.0)),
            (id: 2, signals: signals(exact: 1.0)),
        ])
        XCTAssertEqual(order, [2, 1])
    }

    func testExactOutranksMaxFuzzyAndSemanticCombined() {
        // Даже при максимальных fuzzy И semantic у соперника — exact выше.
        let order = SemanticRanking.rank([
            (id: 1, signals: signals(fuzzy: 1.0, semantic: 1.0)),
            (id: 2, signals: signals(exact: 1.0)),
        ])
        XCTAssertEqual(order.first, 2)
    }

    // MARK: при равном exact — выше тот, у кого больше fuzzy/semantic

    func testEqualExactBreaksOnFuzzy() {
        let order = SemanticRanking.rank([
            (id: 1, signals: signals(exact: 1.0, fuzzy: 0.2)),
            (id: 2, signals: signals(exact: 1.0, fuzzy: 0.9)),
        ])
        XCTAssertEqual(order, [2, 1])
    }

    func testEqualExactBreaksOnSemanticWhenFuzzyEqual() {
        let order = SemanticRanking.rank([
            (id: 1, signals: signals(exact: 1.0, fuzzy: 0.5, semantic: 0.1)),
            (id: 2, signals: signals(exact: 1.0, fuzzy: 0.5, semantic: 0.9)),
        ])
        XCTAssertEqual(order, [2, 1])
    }

    // MARK: нулевые сигналы → отфильтрованы

    func testZeroSignalsFilteredOut() {
        let order = SemanticRanking.rank([
            (id: 1, signals: signals()),                 // всё ноль — выпадает
            (id: 2, signals: signals(semantic: 0.3)),    // остаётся
            (id: 3, signals: signals()),                 // всё ноль — выпадает
        ])
        XCTAssertEqual(order, [2])
    }

    func testAllZeroSignalsGivesEmptyResult() {
        let order = SemanticRanking.rank([
            (id: 1, signals: signals()),
            (id: 2, signals: signals()),
        ])
        XCTAssertTrue(order.isEmpty)
    }

    func testIsEmptyDetectsZeroSignals() {
        XCTAssertTrue(SemanticRanking.isEmpty(signals()))
        XCTAssertFalse(SemanticRanking.isEmpty(signals(fuzzy: 0.01)))
    }

    // MARK: чистые exact/fuzzy/токенизация

    func testExactSignalCaseInsensitive() {
        XCTAssertEqual(SemanticRanking.exactSignal(text: "Привет Мир", query: "привет"), 1.0)
        XCTAssertEqual(SemanticRanking.exactSignal(text: "Привет Мир", query: "пицца"), 0.0)
        XCTAssertEqual(SemanticRanking.exactSignal(text: "что угодно", query: "   "), 0.0)
    }

    func testFuzzySignalIsFractionOfQueryTokensFound() {
        // 1 из 2 токенов запроса встречается в тексте → 0.5.
        XCTAssertEqual(SemanticRanking.fuzzySignal(text: "сегодня релиз", query: "релиз завтра"), 0.5)
        // оба токена есть → 1.0.
        XCTAssertEqual(SemanticRanking.fuzzySignal(text: "сегодня релиз завтра", query: "релиз завтра"), 1.0)
        // ни одного → 0.
        XCTAssertEqual(SemanticRanking.fuzzySignal(text: "сегодня релиз", query: "пицца суши"), 0.0)
    }

    func testTokensSplitsAndLowercases() {
        XCTAssertEqual(SemanticRanking.tokens("Hello, World! раз-два"), ["hello", "world", "раз", "два"])
    }

    // MARK: cosine (чистая числовая)

    func testCosineIdenticalVectorsIsOne() {
        XCTAssertEqual(SemanticSearchEngine.cosine([1, 2, 3], [1, 2, 3]), 1.0, accuracy: 1e-9)
    }

    func testCosineOrthogonalIsZero() {
        XCTAssertEqual(SemanticSearchEngine.cosine([1, 0], [0, 1]), 0.0, accuracy: 1e-9)
    }

    func testCosineMismatchedOrZeroNormIsZero() {
        XCTAssertEqual(SemanticSearchEngine.cosine([1, 2], [1, 2, 3]), 0.0)
        XCTAssertEqual(SemanticSearchEngine.cosine([0, 0], [0, 0]), 0.0)
    }

    // MARK: жизненный цикл моделей (загрузка по требованию / выгрузка / кэш)

    /// Один HistoryEntry для прогона поиска через движок.
    @MainActor
    private func entry(id: Int64 = 1, text: String = "сегодня релиз") -> HistoryEntry {
        HistoryEntry(id: id, startAt: "", endAt: "", durationS: 0, totalWords: 2, fullText: text)
    }

    /// Потокобезопасный счётчик вызовов загрузчика. Загрузчик `@Sendable`
    /// вызывается на фоновом исполнителе, поэтому счётчик под локом.
    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Поиск с непустым запросом грузит модели РОВНО один раз в активном окне:
    /// второй вызов до выгрузки модели не перезагружает. Загрузка асинхронная —
    /// ждём её завершения тестовым seam'ом.
    @MainActor
    func testLoaderInvokedOnceWithinActiveWindow() async {
        let counter = LoadCounter()
        let engine = SemanticSearchEngine(loadEmbeddings: {
            counter.bump()
            return (nil, nil)   // стаб без реального NLEmbedding
        })
        let entries = [entry()]
        _ = engine.rankedEntries(entries, query: "релиз")
        await engine.awaitEmbeddingLoadForTesting()
        XCTAssertEqual(counter.count, 1)
        // Повторный поиск в том же активном окне — без перезагрузки.
        _ = engine.rankedEntries(entries, query: "релиз завтра")
        await engine.awaitEmbeddingLoadForTesting()
        XCTAssertEqual(counter.count, 1)
    }

    /// Пустой запрос НЕ грузит модели (поиск неактивен).
    @MainActor
    func testEmptyQueryDoesNotLoadModels() async {
        let counter = LoadCounter()
        let engine = SemanticSearchEngine(loadEmbeddings: {
            counter.bump()
            return (nil, nil)
        })
        _ = engine.rankedEntries([entry()], query: "   ")
        await engine.awaitEmbeddingLoadForTesting()   // загрузки нет → no-op
        XCTAssertEqual(counter.count, 0)
    }

    /// `unloadEmbeddings()` освобождает МОДЕЛИ, но СОХРАНЯЕТ кэш векторов.
    ///
    /// Память держат именно модели (сотни МБ); вектор — обычный массив на
    /// килобайты, и он не ссылается на выгруженную модель. Прежняя очистка
    /// кэша заставляла следующий поиск пересчитывать эмбеддинги всех
    /// интервалов заново — самая дорогая часть поиска.
    @MainActor
    func testUnloadKeepsVectorCacheButReloadsModels() async {
        let counter = LoadCounter()
        let engine = SemanticSearchEngine(loadEmbeddings: {
            counter.bump()
            return (nil, nil)
        })
        let entries = [entry()]
        _ = engine.rankedEntries(entries, query: "релиз")
        await engine.awaitEmbeddingLoadForTesting()
        XCTAssertEqual(counter.count, 1)
        // Засеваем кэш напрямую (с nil-моделями реальные векторы не считаются).
        engine.seedCacheForTesting(id: 1, vector: [0.1, 0.2, 0.3])
        let cachedBefore = engine.cachedCount
        XCTAssertGreaterThan(cachedBefore, 0)

        engine.unloadEmbeddings()
        XCTAssertEqual(engine.cachedCount, cachedBefore,
                       "кэш векторов переживает выгрузку моделей")

        // Но сами модели выгружены: следующий активный поиск грузит их заново.
        _ = engine.rankedEntries(entries, query: "релиз")
        await engine.awaitEmbeddingLoadForTesting()
        XCTAssertEqual(counter.count, 2)
    }

    // MARK: двухфазность (быстрый exact+fuzzy сразу, семантика в фоне)

    /// Непустой запрос НЕМЕДЛЕННО публикует быструю фазу (exact+fuzzy) в
    /// `results` — синхронно, ещё до загрузки моделей, чтобы UI не ждал.
    @MainActor
    func testFastPassPublishedSynchronously() async {
        let engine = SemanticSearchEngine(loadEmbeddings: { (nil, nil) })
        let entries = [entry(id: 1, text: "сегодня релиз"),
                       entry(id: 2, text: "обед и кофе")]
        let returned = engine.rankedEntries(entries, query: "релиз")
        // Возврат и опубликованный results совпадают и содержат дословное совпадение.
        XCTAssertEqual(returned.map(\.id), [1])
        XCTAssertEqual(engine.results.map(\.id), [1])
        // Семантика ещё считается в фоне → индикатор поиска включён.
        XCTAssertTrue(engine.isSearching)
    }

    /// После завершения фоновой фазы (модели + эмбеддинги) `isSearching` гаснет,
    /// даже если модель недоступна (nil) — семантика просто деградирует до 0.
    @MainActor
    func testIsSearchingClearsAfterBackgroundPhase() async {
        let engine = SemanticSearchEngine(loadEmbeddings: { (nil, nil) })
        let entries = [entry(id: 1, text: "сегодня релиз")]
        _ = engine.rankedEntries(entries, query: "релиз")
        XCTAssertTrue(engine.isSearching)
        await engine.awaitEmbeddingLoadForTesting()
        await engine.awaitSemanticForTesting()
        XCTAssertFalse(engine.isSearching)
        XCTAssertEqual(engine.results.map(\.id), [1])
    }

    /// Пустой запрос показывает список как есть и не держит индикатор поиска.
    @MainActor
    func testEmptyQueryPublishesEntriesWithoutSearching() async {
        let engine = SemanticSearchEngine(loadEmbeddings: { (nil, nil) })
        let entries = [entry(id: 1, text: "a"), entry(id: 2, text: "b")]
        _ = engine.rankedEntries(entries, query: "   ")
        XCTAssertEqual(engine.results.map(\.id), [1, 2])
        XCTAssertFalse(engine.isSearching)
    }
}
