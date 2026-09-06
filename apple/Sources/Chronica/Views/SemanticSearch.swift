import Foundation
import NaturalLanguage

/// Семантический поиск по репликам ленты журнала.
///
/// Поиск комбинирует ТРИ независимых сигнала на каждый интервал:
///   1. дословный (exact) — подстрока запроса встречается в тексте
///      (регистронезависимо). НАИБОЛЬШИЙ вес: пользователь, набравший точную
///      фразу, ожидает её увидеть выше «по смыслу похожих».
///   2. нечёткий (fuzzy) — доля токенов запроса, встретившихся в тексте.
///      Средний вес: ловит частичные совпадения и разный порядок слов.
///   3. семантический (semantic) — cosine similarity эмбеддингов запроса и
///      текста (Apple NaturalLanguage, on-device). Меньший вес: «по смыслу».
///
/// Чистая логика ранжирования (`combinedScore`, `rank`, токенизация, exact/fuzzy)
/// вынесена в `SemanticRanking` и покрыта тестами без рантайма NLEmbedding.
/// Сам эмбеддинг считается лениво и кэшируется по interval id.

// MARK: - Чистые сигналы и веса (тестируемо)

/// Три сигнала релевантности одного интервала запросу. Все в диапазоне 0..1
/// (exact и fuzzy — доли; semantic — нормированный 0..1 cosine).
struct SearchSignals: Equatable {
    /// Дословное совпадение: 1, если подстрока запроса найдена, иначе 0.
    /// (Можно расширить до доли, но для подстроки бинарного хватает.)
    var exact: Double
    /// Доля токенов запроса, встретившихся в тексте (0..1).
    var fuzzy: Double
    /// Семантическая близость (нормированный cosine, 0..1).
    var semantic: Double
}

/// Веса комбинирования сигналов. Подобраны так, чтобы ЛЮБОЙ ненулевой exact
/// гарантированно перевешивал максимально возможный вклад fuzzy+semantic
/// (`exact > fuzzy + semantic`), т.е. дословные совпадения всегда выше
/// чисто-семантических.
struct SearchWeights {
    var exact: Double
    var fuzzy: Double
    var semantic: Double

    /// Дефолт: exact доминирует. При max fuzzy+semantic = 4.0 + 2.0 = 6.0,
    /// а ненулевой exact даёт минимум 10.0 — строго больше любого
    /// чисто-fuzzy/semantic результата.
    static let `default` = SearchWeights(exact: 10.0, fuzzy: 4.0, semantic: 2.0)
}

/// Чистые функции ранжирования — без NLEmbedding, без UI, без ядра.
enum SemanticRanking {

    /// Взвешенная сумма сигналов. Монотонна по каждому сигналу (веса > 0).
    static func combinedScore(_ s: SearchSignals, weights: SearchWeights = .default) -> Double {
        s.exact * weights.exact + s.fuzzy * weights.fuzzy + s.semantic * weights.semantic
    }

    /// Сигнал считается «пустым», если все три компоненты равны нулю —
    /// такие интервалы не показываются (порог отсечения).
    static func isEmpty(_ s: SearchSignals) -> Bool {
        s.exact == 0 && s.fuzzy == 0 && s.semantic == 0
    }

    /// Ранжирование: отбрасываем пустые сигналы, сортируем по убыванию
    /// combinedScore. При равенстве score порядок стабилизируем по id
    /// (детерминизм в тестах). Возвращаем id по убыванию релевантности.
    static func rank(_ entries: [(id: Int64, signals: SearchSignals)],
                     weights: SearchWeights = .default) -> [Int64] {
        entries
            .filter { !isEmpty($0.signals) }
            .map { (id: $0.id, score: combinedScore($0.signals, weights: weights)) }
            .sorted { a, b in a.score != b.score ? a.score > b.score : a.id > b.id }
            .map(\.id)
    }

    // MARK: токенизация / exact / fuzzy (чисто)

    /// Регистронезависимая разбивка на словесные токены (буквы/цифры).
    /// Возвращает lowercase-токены без пунктуации и пробелов.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Дословный сигнал: 1.0, если обрезанный запрос встречается в тексте как
    /// подстрока (регистронезависимо); иначе 0.0. Пустой запрос → 0.
    static func exactSignal(text: String, query: String) -> Double {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return 0 }
        return text.localizedCaseInsensitiveContains(q) ? 1.0 : 0.0
    }

    /// Нечёткий сигнал: доля УНИКАЛЬНЫХ токенов запроса, встретившихся среди
    /// токенов текста (0..1). Пустой запрос → 0.
    static func fuzzySignal(text: String, query: String) -> Double {
        let qTokens = Set(tokens(query))
        guard !qTokens.isEmpty else { return 0 }
        let textTokens = Set(tokens(text))
        let hits = qTokens.filter { textTokens.contains($0) }.count
        return Double(hits) / Double(qTokens.count)
    }
}

// MARK: - Движок с кэшем эмбеддингов

/// Движок семантического поиска по репликам ленты журнала.
///
/// Держит кэш эмбеддингов по interval id — пересчитываются ТОЛЬКО новые
/// интервалы. Семантический сигнал считается через Apple `NLEmbedding`
/// (on-device, без скачиваний). Если модель недоступна (`sentenceEmbedding`
/// вернул nil) — semantic-сигнал деградирует до 0, поиск продолжает работать
/// на exact+fuzzy.
///
/// ## Двухфазный поиск (чтобы UI НЕ подвисал)
/// Семантика тяжёлая дважды: (1) загрузка моделей (сотни МБ, секунды) и
/// (2) расчёт эмбеддинга текста КАЖДОГО интервала (`NLEmbedding.vector`).
/// Оба шага уходят с главного актора:
///   - **Фаза 1 (мгновенно, на главном акторе):** exact+fuzzy ранжирование без
///     эмбеддингов — публикуется в `results` сразу, ввод не блокируется.
///   - **Фаза 2 (в фоне):** `Task.detached` грузит модели (если надо) и считает
///     все эмбеддинги, затем переранжирует с семантикой и публикует результат на
///     главном акторе. Пока фаза идёт — `isSearching == true` (вью показывает
///     прогресс «поиск по смыслу»).
@MainActor
final class SemanticSearchEngine: ObservableObject {

    private let weights: SearchWeights

    /// Кэш эмбеддингов текста интервала по его id.
    private var cache: [Int64: [Double]] = [:]

    /// Тестовый доступ к размеру кэша эмбеддингов. Не публичный — только для тестов.
    var cachedCount: Int { cache.count }

    /// Тестовый сид кэша. Не публичный — только для тестов (без реального NLEmbedding).
    func seedCacheForTesting(id: Int64, vector: [Double]) { cache[id] = vector }

    /// Текущий ранжированный список под активный запрос. Сначала наполняется
    /// быстрой фазой (exact+fuzzy), затем переписывается фоновой семантикой.
    /// `@Published` — лента журнала фильтруется именно по нему (а не по
    /// возврату функции).
    @Published private(set) var results: [HistoryEntry] = []

    /// `true`, пока идёт фоновая семантическая фаза (загрузка моделей и/или
    /// расчёт эмбеддингов). Вью показывает по нему индикатор прогресса поиска.
    /// Сбрасывается, когда семантика применена (или модель недоступна).
    @Published private(set) var isSearching = false

    /// Снимок последнего активного запроса/набора — для отсева устаревших
    /// фоновых результатов (пока считали, запрос/период могли смениться).
    private var currentQuery = ""
    private var currentEntries: [HistoryEntry] = []

    /// Модели-эмбеддеры. Загружаются ТОЛЬКО во время активного поиска и
    /// выгружаются через 5 секунд простоя (освобождая сотни МБ RAM).
    private var ruEmbedding: NLEmbedding?
    private var enEmbedding: NLEmbedding?
    private var embeddingsLoaded = false
    private var unloadTask: Task<Void, Never>?
    /// Текущая ФОНОВАЯ загрузка моделей (если идёт). Держим, чтобы не запускать
    /// две сразу и чтобы выгрузка/тесты могли её дождаться/отменить.
    private var loadTask: Task<Void, Never>?
    /// Текущая ФОНОВАЯ семантическая фаза (расчёт эмбеддингов + переранжирование).
    /// Держим, чтобы отменять при новом запросе/выгрузке и ждать в тестах.
    private var semanticTask: Task<Void, Never>?

    /// СЕРИЙНАЯ очередь для ВСЕХ обращений к `NLEmbedding`. Критично: CoreNLP
    /// (`NLEmbedding.vector(for:)`) НЕ потокобезопасен при ОДНОВРЕМЕННЫХ вызовах —
    /// гонка двух фоновых задач роняла процесс в `CoreNLP::fillWordVectors`
    /// (SIGSEGV). Поэтому эмбеддинги считаем строго по одному за раз, но ВНЕ
    /// главного потока (UI не подвисает). `nonisolated let` — обращаемся к ней с
    /// фоновых задач.
    nonisolated private let embedQueue = DispatchQueue(label: "app.chronica.semantic-embed",
                                                       qos: .userInitiated)

    /// Сколько кандидатов доходит до ТЯЖЁЛОЙ семантической фазы.
    ///
    /// Эмбеддинг считается для каждого текста по одному на серийной очереди,
    /// поэтому стоимость фазы линейна по числу интервалов: на периоде в
    /// несколько недель это тысячи вызовов ради переупорядочивания хвоста,
    /// который пользователь никогда не увидит. Берём только верхушку
    /// exact+fuzzy — она уже отсортирована по релевантности.
    static let semanticCandidateLimit = 200

    /// Поколение активного поиска. Растёт на каждый новый запрос; работа в очереди
    /// с устаревшим поколением пропускается — иначе при быстром наборе копился бы
    /// бэклог тяжёлых расчётов. Потокобезопасно (читается с фоновой очереди).
    nonisolated private let generation = Generation()
    /// Поколение текущего активного запроса (для досчёта после загрузки моделей).
    private var currentGen = 0

    /// Загрузчик моделей-эмбеддеров. Вынесен для тестируемости (в тестах
    /// подменяется стабом, без реального NLEmbedding). По умолчанию — Apple on-device.
    /// `@Sendable` — вызывается на фоновом исполнителе (`Task.detached`), чтобы
    /// тяжёлая загрузка не вешала главный поток (ввод в поиск).
    private let loadEmbeddings: @Sendable () -> (NLEmbedding?, NLEmbedding?)

    init(weights: SearchWeights = .default,
         loadEmbeddings: @escaping @Sendable () -> (NLEmbedding?, NLEmbedding?) = {
             (NLEmbedding.sentenceEmbedding(for: .russian), NLEmbedding.sentenceEmbedding(for: .english))
         }) {
        self.weights = weights
        self.loadEmbeddings = loadEmbeddings
    }

    // MARK: жизненный цикл моделей (загрузка по требованию, выгрузка по простою)

    /// Запустить АСИНХРОННУЮ загрузку моделей, если ещё не загружены и загрузка
    /// не идёт. Не блокирует вызывающего (ввод в поиск): тяжёлая загрузка уходит
    /// на фоновый исполнитель, результат применяется на главном акторе. Пока
    /// модель не готова — `isSearching` остаётся true (вью крутит прогресс),
    /// а exact+fuzzy уже показаны.
    private func ensureEmbeddingsLoaded() {
        guard !embeddingsLoaded, loadTask == nil else { return }
        let loader = loadEmbeddings
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let (ru, en) = loader()
            // Загрузку отменили (выгрузка по простою) — ничего не применяем.
            if Task.isCancelled { return }
            let models = EmbeddingModels(ru: ru, en: en)
            await self?.applyLoadedEmbeddings(models)
        }
    }

    /// Применить загруженные модели (на главном акторе) и запустить семантическую
    /// фазу для текущего активного запроса (если он есть).
    private func applyLoadedEmbeddings(_ models: EmbeddingModels) {
        // Если выгрузка по простою уже обнулила загрузку — не оживляем модели.
        guard loadTask != nil else { return }
        loadTask = nil
        ruEmbedding = models.ru
        enEmbedding = models.en
        embeddingsLoaded = true
        // Маяк для разбора памяти: модель поиска теперь резидентна.
        SearchMemoryProbe.shared.setLoaded(true)
        // Модели готовы — досчитываем семантику для активного запроса в фоне.
        if !currentQuery.isEmpty {
            scheduleSemanticRefine(entries: currentEntries, query: currentQuery, gen: currentGen)
        } else {
            isSearching = false
        }
    }

    /// Пауза простоя, после которой модели-эмбеддеры выгружаются.
    ///
    /// Было 5 с: пользователь, который на несколько секунд отвлёкся от поиска,
    /// платил повторной загрузкой моделей (секунды) при следующем же символе.
    /// 60 с закрывают паузу «подумал и продолжил», а память всё равно
    /// освобождается, когда поиск действительно закончен.
    private static let idleUnloadDelayNs: UInt64 = 60_000_000_000

    /// (Пере)взвести таймер простоя: по срабатыванию — выгрузить модели.
    private func armIdleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleUnloadDelayNs)
            guard !Task.isCancelled else { return }
            self?.unloadEmbeddings()
        }
    }

    /// Выгрузить модели-эмбеддеры.
    ///
    /// Кэш векторов НЕ чистим: вектор — это обычный `[Double]`, он не держит
    /// выгруженную модель и занимает килобайты, а не сотни мегабайт. Прежняя
    /// очистка обесценивала весь кэш при каждой выгрузке, и следующий поиск
    /// пересчитывал эмбеддинги всех интервалов заново.
    func unloadEmbeddings() {
        unloadTask?.cancel()
        unloadTask = nil
        loadTask?.cancel()
        loadTask = nil
        semanticTask?.cancel()
        semanticTask = nil
        ruEmbedding = nil
        enEmbedding = nil
        embeddingsLoaded = false
        isSearching = false
        // Маяк для разбора памяти: модель поиска выгружена.
        SearchMemoryProbe.shared.setLoaded(false)
    }

    /// Тестовый seam: дождаться завершения текущей фоновой загрузки моделей.
    /// Не публичный — только для детерминированных тестов асинхронной загрузки.
    func awaitEmbeddingLoadForTesting() async { await loadTask?.value }

    /// Тестовый seam: дождаться завершения текущей фоновой семантической фазы.
    func awaitSemanticForTesting() async { await semanticTask?.value }

    /// Главный вход: ранжированный список интервалов под запрос.
    ///
    /// Возвращает БЫСТРУЮ фазу (exact+fuzzy) синхронно — для мгновенного показа.
    /// Семантика досчитывается в фоне и публикуется через `results`/`isSearching`,
    /// поэтому вью должна рисовать `results`, а не возврат этой функции.
    ///
    /// - Пустой запрос (после обрезки пробелов) → исходный список БЕЗ изменений
    ///   (порядок «новое сверху» сохраняется как раньше).
    /// - Непустой запрос → exact+fuzzy сейчас, +семантика по готовности.
    @discardableResult
    func rankedEntries(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentEntries = entries
        currentQuery = q
        // Новый запрос → новое поколение: незапущенная работа прошлых запросов в
        // очереди увидит чужое поколение и пропустится.
        currentGen = generation.bump()
        guard !q.isEmpty else {
            // Пустой запрос: семантика не нужна — гасим фоновую фазу и взводим
            // выгрузку моделей по простою. Показываем список как есть.
            semanticTask?.cancel()
            semanticTask = nil
            isSearching = false
            armIdleUnload()
            results = entries
            return entries
        }

        // Активный поиск: грузим модели (если ещё нет) и (пере)взводим таймер простоя.
        ensureEmbeddingsLoaded()
        armIdleUnload()

        // Фаза 1: мгновенный exact+fuzzy без эмбеддингов (на главном акторе дёшево).
        let fast = fastRanked(entries, query: q)
        results = fast
        isSearching = true

        // Фаза 2: фоновая семантика (если модели уже готовы; иначе досчитается в
        // `applyLoadedEmbeddings` по завершении загрузки).
        scheduleSemanticRefine(entries: entries, query: q, gen: currentGen)
        return fast
    }

    // MARK: фаза 1 — быстрый exact+fuzzy (главный актор, без эмбеддингов)

    /// Ранжирование только по дословному+нечёткому сигналам. Никаких эмбеддингов
    /// → не вешает главный поток. Семантику добавит фаза 2.
    private func fastRanked(_ entries: [HistoryEntry], query q: String) -> [HistoryEntry] {
        let scored: [(id: Int64, signals: SearchSignals)] = entries.map { e in
            let exact = SemanticRanking.exactSignal(text: e.fullText, query: q)
            let fuzzy = SemanticRanking.fuzzySignal(text: e.fullText, query: q)
            return (id: e.id, signals: SearchSignals(exact: exact, fuzzy: fuzzy, semantic: 0))
        }
        let order = SemanticRanking.rank(scored, weights: weights)
        let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return order.compactMap { byId[$0] }
    }

    // MARK: фаза 2 — фоновая семантика (вне главного актора)

    /// Запустить фоновый расчёт эмбеддингов и переранжирование с семантикой.
    ///
    /// Тяжёлый `NLEmbedding.vector` для каждого текста уходит на СЕРИЙНУЮ
    /// `embedQueue` (по одному за раз — иначе гонка роняет CoreNLP), поэтому UI
    /// не подвисает и не крешит. В фазу попадают только `semanticCandidateLimit`
    /// лучших по exact+fuzzy: остальной хвост остаётся в порядке быстрой фазы,
    /// и стоимость поиска перестаёт зависеть от длины периода.
    private func scheduleSemanticRefine(entries: [HistoryEntry], query q: String, gen: Int) {
        // Модели ещё грузятся — фаза 2 стартует из `applyLoadedEmbeddings`.
        guard embeddingsLoaded else { return }
        semanticTask?.cancel()
        // Кандидаты берём из уже отсортированной быстрой фазы.
        let fast = fastRanked(entries, query: q)
        let candidates = Array(fast.prefix(Self.semanticCandidateLimit))
        let tail = Array(fast.dropFirst(Self.semanticCandidateLimit))
        guard !candidates.isEmpty else {
            isSearching = false
            return
        }
        let models = EmbeddingModels(ru: ruEmbedding, en: enEmbedding)
        let cacheSnapshot = cache
        let weights = self.weights
        let gen0 = generation
        let queue = embedQueue
        semanticTask = Task { [weak self] in
            // Считаем эмбеддинги строго последовательно на серийной очереди.
            let outcome: SemanticOutcome? = await withCheckedContinuation { cont in
                queue.async {
                    // Запрос устарел ещё до старта тяжёлой работы — пропускаем.
                    guard gen0.isCurrent(gen) else { cont.resume(returning: nil); return }
                    let qVec = Self.embed(text: q, models: models)
                    var newVectors: [Int64: [Double]] = [:]
                    var scored: [(id: Int64, signals: SearchSignals)] = []
                    scored.reserveCapacity(candidates.count)
                    for e in candidates {
                        // Пользователь напечатал дальше — бросаем недосчитанное.
                        guard gen0.isCurrent(gen) else { cont.resume(returning: nil); return }
                        let exact = SemanticRanking.exactSignal(text: e.fullText, query: q)
                        let fuzzy = SemanticRanking.fuzzySignal(text: e.fullText, query: q)
                        // Эмбеддинг текста: из снимка кэша или считаем (и копим для слияния).
                        let vec: [Double]
                        if let cached = cacheSnapshot[e.id] {
                            vec = cached
                        } else {
                            let v = Self.embed(text: e.fullText, models: models) ?? []
                            newVectors[e.id] = v
                            vec = v
                        }
                        let semantic = Self.semanticScore(queryVec: qVec, textVec: vec)
                        scored.append((id: e.id, signals: SearchSignals(exact: exact, fuzzy: fuzzy, semantic: semantic)))
                    }
                    let order = SemanticRanking.rank(scored, weights: weights)
                    cont.resume(returning: SemanticOutcome(order: order, newVectors: newVectors))
                }
            }
            guard let outcome, !Task.isCancelled else { return }
            // Task создан на главном акторе → продолжение здесь уже на нём.
            self?.applySemanticResults(order: outcome.order, candidates: candidates,
                                       tail: tail, entries: entries, query: q,
                                       newVectors: outcome.newVectors)
        }
    }

    /// Применить результат фоновой семантики на главном акторе. Отбрасываем, если
    /// запрос/набор уже устарели (пользователь печатает дальше / сменил период) —
    /// их обслуживает более новая фаза.
    private func applySemanticResults(order: [Int64], candidates: [HistoryEntry],
                                      tail: [HistoryEntry], entries: [HistoryEntry],
                                      query: String, newVectors: [Int64: [Double]]) {
        guard query == currentQuery, entries.map(\.id) == currentEntries.map(\.id) else { return }
        // Сливаем досчитанные векторы в кэш — следующий ввод их переиспользует.
        for (id, v) in newVectors { cache[id] = v }
        let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        // Верхушку переупорядочила семантика, хвост остаётся в порядке
        // быстрой фазы — так список не «прыгает» ниже видимой области.
        results = order.compactMap { byId[$0] } + tail
        isSearching = false
    }

    // MARK: эмбеддинг (статические, безопасны вне главного актора)

    /// Получить эмбеддинг текста заданными моделями. Пробуем обе (ru/en) и берём
    /// вектор доступной: русскую как основную (контент в основном русскоязычный),
    /// английскую — запасной. nil, если никакая модель не дала вектор.
    /// `nonisolated static` + модели через `EmbeddingModels` — вызывается с
    /// СЕРИЙНОЙ `embedQueue` (никогда не из двух потоков одновременно — иначе
    /// CoreNLP крешит).
    nonisolated private static func embed(text: String, models: EmbeddingModels) -> [Double]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let ru = models.ru, let v = ru.vector(for: t) { return v }
        if let en = models.en, let v = en.vector(for: t) { return v }
        return nil
    }

    /// Семантический сигнал: нормированный 0..1 cosine между эмбеддингом запроса
    /// и текста. Если хоть один недоступен/разной длины — 0.
    nonisolated private static func semanticScore(queryVec: [Double]?, textVec: [Double]) -> Double {
        guard let queryVec, !queryVec.isEmpty, !textVec.isEmpty, textVec.count == queryVec.count else { return 0 }
        let cos = cosine(queryVec, textVec)
        // cosine ∈ [-1, 1] → нормируем в [0, 1].
        return max(0, min(1, (cos + 1) / 2))
    }

    /// Cosine similarity двух векторов равной длины. 0 при нулевой норме.
    /// `nonisolated` — чистая функция, доступна из тестов вне main actor.
    nonisolated static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }
}

/// Бокс для переноса загруженных моделей между потоками. `NLEmbedding` не
/// `Sendable`, но модели неизменяемы после создания; запросы векторов мы
/// сериализуем на одной очереди (`embedQueue`), поэтому перенос ссылок
/// безопасен — отсюда `@unchecked Sendable`.
final class EmbeddingModels: @unchecked Sendable {
    let ru: NLEmbedding?
    let en: NLEmbedding?
    init(ru: NLEmbedding?, en: NLEmbedding?) {
        self.ru = ru
        self.en = en
    }
}

/// Результат фоновой семантической фазы: порядок интервалов + досчитанные
/// векторы для слияния в кэш. `Sendable` — переносится с `embedQueue` на актор.
private struct SemanticOutcome: Sendable {
    let order: [Int64]
    let newVectors: [Int64: [Double]]
}

/// Потокобезопасный счётчик поколений поиска. Фоновая работа сверяет своё
/// поколение с актуальным и бросает себя, если запрос успел смениться.
final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// Поднять поколение и вернуть новое значение.
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    /// Актуально ли переданное поколение (== текущему).
    func isCurrent(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return g == value }
}
