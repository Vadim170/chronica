import SwiftUI
import Combine

/// Настройки уровня интерфейса (хранятся в `UserDefaults`).
///
/// Сюда НЕ попадает `CoreConfig` — им владеет `Engine`. Здесь живут только
/// вещи оболочки: автозапуск при входе и параметры журнала экрана.
@MainActor
final class Prefs: ObservableObject {
    /// Продовый экземпляр: домен приложения (`UserDefaults.standard`) плюс
    /// одноразовый перенос настроек из домена прежнего bundle id.
    ///
    /// Тесты этот экземпляр НЕ используют: они создают свой
    /// (`Prefs(defaults:migrate:)`) на отдельном suite и с `migrate: false`,
    /// иначе прогон читал бы и писал пользовательские домены.
    static let shared = Prefs(defaults: .standard, migrate: true)

    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "pref.launchAtLogin") } }

    // Наблюдение экрана (Chronica): ВЫКЛЮЧЕНО по умолчанию — включается
    // осознанно (снимает скриншоты, пусть и не покидающие машину).
    @Published var screenEnabled: Bool { didSet { d.set(screenEnabled, forKey: "pref.screenEnabled") } }
    /// Период между наблюдениями, секунды (30…600).
    @Published var screenPeriodS: Double { didSet { d.set(screenPeriodS, forKey: "pref.screenPeriodS") } }
    /// Хранение журнала дел, дни. `ScreenRetention.forever` — «всегда».
    @Published var screenRetentionDays: Int { didSet { d.set(screenRetentionDays, forKey: "pref.screenRetentionDays") } }
    /// Адрес локальной Ollama.
    @Published var ollamaURL: String { didSet { d.set(ollamaURL, forKey: "pref.ollamaURL") } }
    /// Маленькая vision-модель для описания скриншотов.
    @Published var visionModel: String { didSet { d.set(visionModel, forKey: "pref.visionModel") } }

    /// Срок хранения расшифровок речи, дни. `0` — хранить всегда (по умолчанию).
    ///
    /// В отличие от журнала экрана чистит не оболочка, а ядро: значение уезжает
    /// в `CoreConfig.retentionDays` и применяется на лету. Дефолт «всегда»
    /// выбран осознанно — молча удалять историю пользователя нельзя.
    @Published var transcriptRetentionDays: Int {
        didSet { d.set(transcriptRetentionDays, forKey: "pref.transcriptRetentionDays") }
    }

    /// Дефолтная vision-модель для НОВЫХ установок.
    ///
    /// `qwen3-vl:2b` под Apache-2.0 (прежний дефолт `qwen2.5vl:3b` шёл под
    /// некоммерческой лицензией). Уже сохранённое значение НЕ мигрируем:
    /// пользователь мог выбрать модель осознанно.
    static let defaultVisionModel = "qwen3-vl:2b"

    private let d: UserDefaults

    /// Создаёт настройки над конкретным хранилищем.
    ///
    /// - Parameters:
    ///   - defaults: домен настроек. Продовый вызов — `.standard`; тесты
    ///     передают отдельный suite и удаляют его в `tearDown`.
    ///   - migrate: выполнять одноразовый перенос из домена старого bundle id.
    ///     В тестах всегда `false`: перенос читает `app.transcriber.mac` и
    ///     пишет флаг, то есть трогает НАСТОЯЩИЕ настройки пользователя.
    init(defaults: UserDefaults, migrate: Bool) {
        self.d = defaults
        // Домен `UserDefaults` — это bundle id, поэтому после переименования
        // продукта настройки лежат в старом домене. Переносим их ДО первого
        // чтения, иначе пользователь увидел бы дефолты вместо своих значений.
        if migrate { PrefsMigration.applyIfNeeded(defaults: defaults) }
        launchAtLogin = d.object(forKey: "pref.launchAtLogin") as? Bool ?? false
        screenEnabled = d.object(forKey: "pref.screenEnabled") as? Bool ?? false
        screenPeriodS = d.object(forKey: "pref.screenPeriodS") as? Double ?? 60
        screenRetentionDays = d.object(forKey: "pref.screenRetentionDays") as? Int ?? 90
        ollamaURL = d.object(forKey: "pref.ollamaURL") as? String ?? "http://127.0.0.1:11434"
        visionModel = d.object(forKey: "pref.visionModel") as? String ?? Prefs.defaultVisionModel
        transcriptRetentionDays = d.object(forKey: "pref.transcriptRetentionDays") as? Int ?? 0
    }
}

/// Варианты срока хранения расшифровок речи (Настройки → Дополнительно).
///
/// Отдельно от `ScreenRetentionChoice`: у журнала экрана свои сроки и свой
/// исполнитель чистки (оболочка), а расшифровки чистит ядро по
/// `CoreConfig.retentionDays`.
enum TranscriptRetentionChoice: Int, CaseIterable, Identifiable {
    case month = 30
    case quarter = 90
    case halfYear = 180
    case year = 365
    /// «Всегда» — хранить без ограничения срока (значение ядра `0`).
    case forever = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .forever: return L("retention.forever")
        default: return L("retention.days", rawValue)
        }
    }

    /// Значение для `Prefs.transcriptRetentionDays` (0 — без ограничения).
    var days: Int { rawValue }

    /// Ближайший вариант к сохранённому значению в днях.
    ///
    /// Значение могло прийти из будущей/прошлой версии или быть отредактировано
    /// вне приложения — выбираем ближайший пункт, а не «падаем» на дефолт.
    /// Ноль и отрицательные значения — это «Всегда».
    static func nearest(toDays days: Int) -> TranscriptRetentionChoice {
        if days <= 0 { return .forever }
        return [TranscriptRetentionChoice.month, .quarter, .halfYear, .year]
            .min { abs($0.days - days) < abs($1.days - days) } ?? .quarter
    }
}

/// Варианты частоты наблюдения экрана, показываемые в Настройках.
///
/// Слайдер в секундах был непонятен: пользователю важно «раз в сколько минут»,
/// а не точное число. Чистая пара «минуты ↔ секунды» позволяет проверить
/// отображение сохранённого значения в пикер без UI.
enum ScreenPeriodChoice: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }

    /// Период в секундах для `Prefs.screenPeriodS`.
    var seconds: Double { Double(rawValue) }

    /// Подпись пункта («1 мин», «10 мин»).
    var title: String { L("screen.period.minutes", rawValue / 60) }

    /// Ближайший вариант к сохранённому значению в секундах.
    ///
    /// Значение могло быть записано старым слайдером (например 90 с) или
    /// отредактировано вне приложения — выбираем ближайший допустимый пункт,
    /// а не «падаем» на дефолт.
    static func nearest(toSeconds seconds: Double) -> ScreenPeriodChoice {
        guard seconds.isFinite else { return .oneMinute }
        return allCases.min { a, b in
            abs(a.seconds - seconds) < abs(b.seconds - seconds)
        } ?? .oneMinute
    }
}

/// Варианты срока хранения журнала экрана.
enum ScreenRetentionChoice: Int, CaseIterable, Identifiable {
    case month = 30
    case quarter = 90
    case halfYear = 180
    /// «Всегда» — хранить без ограничения срока.
    case forever = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .forever: return L("retention.forever")
        default: return L("retention.days", rawValue)
        }
    }

    /// Значение для `Prefs.screenRetentionDays` (0 — без ограничения).
    var days: Int { rawValue }

    /// Ближайший вариант к сохранённому значению в днях.
    static func nearest(toDays days: Int) -> ScreenRetentionChoice {
        if days <= 0 { return .forever }
        return [ScreenRetentionChoice.month, .quarter, .halfYear]
            .min { abs($0.days - days) < abs($1.days - days) } ?? .quarter
    }
}
