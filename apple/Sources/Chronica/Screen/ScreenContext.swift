import Foundation

// Chronica — сборщик контекста экрана (только macOS).
//
// Периодический скриншот описывается локальной маленькой vision-LLM, а
// наблюдения СЕССИОНИЗИРУЮТСЯ в «дела» (Activity): непрерывная работа в одном
// приложении/контексте — один блок со start/end, а не россыпь описаний
// скриншотов. Транскрипция речи подтягивается к блоку по перекрытию времени
// на этапе показа (см. JournalFeedView) — хранилища не дублируют друг друга.
//
// В этом файле — ТОЛЬКО чистая логика (без I/O): типы, правила сессионизации,
// perceptual-hash кадра, промпт. Всё покрыто юнит-тестами.

/// Одно наблюдение экрана: что было на экране в момент `ts`.
struct ScreenObservation: Equatable {
    var ts: Date
    /// Имя фронтального приложения ("Xcode", "Safari").
    var app: String
    /// Заголовок активного окна (может быть пустым).
    var windowTitle: String
    /// Описание от vision-LLM; пустое, если кадр не изменился и LLM не звалась.
    var summary: String
}

/// «Дело» — слитый блок непрерывной работы в одном контексте.
struct Activity: Identifiable, Equatable {
    /// id строки в SQLite; -1 — ещё не сохранено.
    var id: Int64 = -1
    var startAt: Date
    var endAt: Date
    var app: String
    /// Репрезентативный заголовок окна (первый непустой в блоке).
    var title: String
    /// Актуальное описание работы (последнее непустое от LLM).
    var summary: String
    /// Сколько наблюдений слито в блок.
    var observations: Int = 1
}

/// Правила сессионизации наблюдений в дела. Чистые функции.
enum Sessionizer {
    enum Decision: Equatable {
        /// Продолжить последний блок (обновлённая копия).
        case extend(Activity)
        /// Начать новый блок.
        case start(Activity)
    }

    /// Решает, продолжает ли наблюдение последний блок или начинает новый.
    /// `gap` — максимальная пауза между наблюдениями внутри одного блока
    /// (разумно ставить ~3 периода опроса: пропущенные тики не рвут дело).
    static func merge(last: Activity?, obs: ScreenObservation, gap: TimeInterval) -> Decision {
        if let last,
           obs.ts.timeIntervalSince(last.endAt) <= gap,
           obs.ts >= last.startAt,
           obs.app == last.app,
           titlesSimilar(last.title, obs.windowTitle)
        {
            var updated = last
            updated.endAt = obs.ts
            updated.observations += 1
            if !obs.summary.isEmpty { updated.summary = obs.summary }
            if updated.title.isEmpty { updated.title = obs.windowTitle }
            return .extend(updated)
        }
        return .start(Activity(
            startAt: obs.ts,
            endAt: obs.ts,
            app: obs.app,
            title: obs.windowTitle,
            summary: obs.summary
        ))
    }

    /// Заголовки «похожи», если равны после нормализации, один — префикс
    /// другого (счётчики/суффиксы документов), или перекрытие токенов ≥ 0.5.
    /// Пустой заголовок не рвёт блок (окна без имени, пропуски CGWindowName).
    static func titlesSimilar(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        if na.isEmpty || nb.isEmpty || na == nb { return true }
        if na.hasPrefix(nb) || nb.hasPrefix(na) { return true }
        let ta = Set(na.split(separator: " ")), tb = Set(nb.split(separator: " "))
        guard !ta.isEmpty, !tb.isEmpty else { return true }
        let overlap = Double(ta.intersection(tb).count)
        return overlap / Double(min(ta.count, tb.count)) >= 0.5
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Perceptual average-hash кадра: 64-битный отпечаток по сетке яркости 8×8.
/// Если кадр «почти тот же» (малая дистанция Хэмминга) и контекст окна не
/// менялся — vision-LLM не дёргаем (экономия CPU/энергии).
enum FrameHash {
    /// `luma64` — яркости 8×8 (row-major, ровно 64 значения 0...255).
    static func aHash(luma64: [UInt8]) -> UInt64 {
        precondition(luma64.count == 64, "aHash expects an 8x8 luma grid")
        let mean = luma64.reduce(0) { $0 + UInt32($1) } / 64
        var bits: UInt64 = 0
        for (i, v) in luma64.enumerated() where UInt32(v) >= mean {
            bits |= 1 << UInt64(i)
        }
        return bits
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Порог «кадр не изменился» (эмпирически: <6 бит из 64 — косметика:
    /// курсор, часы, мигающая каретка).
    static let unchangedThreshold = 6
}

/// Промпт для vision-LLM. Отдельно от бэкенда: одинаков для любого рантайма.
///
/// Промпт и ожидаемый язык ответа СЛЕДУЮТ ЯЗЫКУ ИНТЕРФЕЙСА (`LApp`, то есть
/// `Bundle.module.preferredLocalizations.first`), а не системной локали:
/// описания попадают в журнал, который пользователь читает в приложении,
/// поэтому русскоязычный интерфейс не должен наполняться английскими записями
/// (и наоборот).
enum VisionPrompt {
    /// Язык, на котором просим модель отвечать (= язык интерфейса).
    static var language: String { Bundle.appLanguage }

    static func build(app: String, windowTitle: String) -> String {
        var context = LApp("vision.prompt.app", app)
        if !windowTitle.isEmpty {
            context += " " + LApp("vision.prompt.window", windowTitle)
        }
        return LApp("vision.prompt.body", context)
    }
}
