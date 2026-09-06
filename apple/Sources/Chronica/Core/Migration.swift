import Foundation

// =============================================================================
// Миграции после продуктового переименования Transcriber → Chronica (0.1.0)
// =============================================================================
//
// Смена bundle id (`app.transcriber.mac` → `io.github.vadim170.chronica`) и
// имени исполняемого файла меняет ДВА пользовательских хранилища:
//
//   1. каталог данных `~/Library/Application Support/<имя>` — базы, логи и
//      ~640 МБ весов моделей;
//   2. домен `UserDefaults` — все настройки `pref.*`;
//   3. плюс регистрацию автозапуска (`SMAppService` привязан к bundle id).
//
// Все три переноса одноразовые и «мягкие»: сбой не должен ломать запуск.
// Решения «переносить или нет» вынесены в ЧИСТЫЕ функции с инжектируемыми
// проверками, поэтому проверяются тестами без файловой системы и без
// системных настроек.

// MARK: - Каталог данных

/// Одноразовый перенос каталога данных с прежнего имени продукта
/// (`Application Support/Transcriber`) на новое (`.../Chronica`).
enum SupportFolderMigration {
    /// Имя каталога данных до переименования продукта.
    static let legacyFolderName = "Transcriber"
    /// Текущее имя каталога данных.
    static let folderName = "Chronica"

    /// Что делать с каталогом данных на старте.
    enum Decision: Equatable {
        /// Ничего не переносим: либо новый каталог уже есть, либо старого нет.
        case useNew
        /// Старый каталог есть, нового ещё нет — переносим целиком.
        case move
    }

    /// Чистое решение «переносить или нет».
    ///
    /// Переносим РОВНО в одном случае: старый каталог существует, а нового
    /// ещё нет. Если новый уже есть — он главный (второй запуск, или
    /// пользователь создал его сам), и подмешивать в него старые файлы нельзя:
    /// две базы с разной историей слить нечем.
    static func decide(legacyExists: Bool, newExists: Bool) -> Decision {
        legacyExists && !newExists ? .move : .useNew
    }

    /// Результат подготовки каталога данных.
    struct Outcome: Equatable {
        /// Каталог, с которым приложение работает дальше.
        let url: URL
        /// Человеческое сообщение о сорванном переносе (`nil` — переноса не
        /// было либо он удался). Запуск не прерывается ни в одном случае.
        let error: String?
        /// Перенос действительно выполнен (для логов и тестов).
        let moved: Bool
    }

    /// Готовит каталог данных, при необходимости перенося старый целиком.
    ///
    /// `moveItem` на одном томе — это переименование записи каталога, поэтому
    /// 640 МБ моделей «переезжают» мгновенно и без копирования. Сбой переноса
    /// НЕ фатален: возвращаем СТАРЫЙ путь (данные пользователя целы и
    /// приложение продолжает с ними работать) и текст ошибки для UI.
    ///
    /// FS-операции инжектируются (`exists`/`move`), чтобы поведение — включая
    /// откат на старый путь при ошибке — проверялось тестами.
    static func prepare(legacy: URL, new: URL,
                        exists: (URL) -> Bool,
                        move: (URL, URL) throws -> Void) -> Outcome {
        switch decide(legacyExists: exists(legacy), newExists: exists(new)) {
        case .useNew:
            return Outcome(url: new, error: nil, moved: false)
        case .move:
            do {
                try move(legacy, new)
                return Outcome(url: new, error: nil, moved: true)
            } catch {
                return Outcome(url: legacy, error: failureMessage(error), moved: false)
            }
        }
    }

    /// Боевой вариант: каталоги внутри `Application Support`, реальный `FileManager`.
    static func prepare(inApplicationSupport root: URL,
                        fileManager: FileManager = .default) -> Outcome {
        prepare(
            legacy: root.appendingPathComponent(legacyFolderName, isDirectory: true),
            new: root.appendingPathComponent(folderName, isDirectory: true),
            exists: { fileManager.fileExists(atPath: $0.path) },
            move: { from, to in
                try fileManager.createDirectory(at: to.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.moveItem(at: from, to: to)
            })
    }

    /// Сообщение об ошибке в стиле `Engine.humanMessage`: короткая понятная
    /// фраза плюс техническая деталь в скобках, если она однострочная и короткая.
    static func failureMessage(_ error: Error) -> String {
        let phrase = L("migration.folderFailed", legacyFolderName, folderName)
        let detail = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty, !detail.contains("\n"), detail.count <= 120 else { return phrase }
        return L("error.detail", phrase, detail)
    }
}

// MARK: - Настройки (UserDefaults)

/// Одноразовый перенос значений `pref.*` из домена старого bundle id.
///
/// Домен `UserDefaults` — это bundle id, поэтому после переименования
/// приложение стартует с пустыми настройками, хотя файл
/// `~/Library/Preferences/app.transcriber.mac.plist` никуда не делся.
/// Копируем из него только свои ключи и только те, которых в новом домене
/// ещё нет: значение, уже выставленное пользователем в новой версии, важнее.
enum PrefsMigration {
    /// Домен `UserDefaults` до смены bundle id.
    static let legacyDomain = "app.transcriber.mac"
    /// Ключ флага однократности переноса (живёт в НОВОМ домене).
    static let flagKey = "pref.migratedFromLegacyDomain"

    /// Ключи, которые пишет `Prefs`. Переносим ровно их — чужие ключи из
    /// старого домена (например, служебные записи AppKit) не трогаем.
    static let keys = [
        "pref.launchAtLogin",
        "pref.screenEnabled",
        "pref.screenPeriodS",
        "pref.screenRetentionDays",
        "pref.ollamaURL",
        "pref.visionModel",
        "pref.transcriptRetentionDays",
    ]

    /// Чистый план переноса: какие ключи и с какими значениями записать в
    /// новый домен.
    ///
    /// - Parameters:
    ///   - legacy: содержимое старого домена (как отдаёт `persistentDomain`).
    ///   - existingKeys: ключи, УЖЕ имеющие значение в новом домене.
    ///   - alreadyMigrated: флаг `flagKey` — перенос уже выполнялся.
    /// - Returns: пары «ключ → значение» для записи. Пусто, если переносить нечего.
    static func plan(legacy: [String: Any],
                     existingKeys: Set<String>,
                     alreadyMigrated: Bool) -> [String: Any] {
        guard !alreadyMigrated else { return [:] }
        var result: [String: Any] = [:]
        for key in keys where !existingKeys.contains(key) {
            if let value = legacy[key] { result[key] = value }
        }
        return result
    }

    /// Выполняет перенос, если он ещё не выполнялся, и ставит флаг.
    ///
    /// Флаг ставится ВСЕГДА, даже если переносить было нечего: иначе на каждом
    /// запуске мы читали бы старый plist впустую и могли бы «оживить» настройку,
    /// которую пользователь осознанно сбросил.
    ///
    /// - Returns: ключи, реально записанные в новый домен.
    @discardableResult
    static func applyIfNeeded(defaults: UserDefaults = .standard) -> [String] {
        let alreadyMigrated = defaults.bool(forKey: flagKey)
        guard !alreadyMigrated else { return [] }
        // `UserDefaults(suiteName:)` открывает именно старый домен;
        // `persistentDomain(forName:)` читает ЕГО содержимое напрямую, без
        // подмешивания текущего домена через список поиска.
        let legacy = UserDefaults(suiteName: legacyDomain)?
            .persistentDomain(forName: legacyDomain) ?? [:]
        let existing = Set(keys.filter { defaults.object(forKey: $0) != nil })
        let copied = plan(legacy: legacy, existingKeys: existing, alreadyMigrated: false)
        for (key, value) in copied { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: flagKey)
        return copied.keys.sorted()
    }
}

// MARK: - Автозапуск (login item)

/// Перерегистрация автозапуска после смены bundle id.
///
/// `SMAppService.mainApp` привязан к bundle id, поэтому старая запись остаётся
/// в Системных настройках как «Transcriber», а новая не создаётся. Если
/// пользователь держал автозапуск включённым, включаем его заново — уже под
/// новым id. Старую запись система не удаляет; её убирают руками (об этом
/// сказано в README и PRIVACY).
enum LoginItemMigration {
    /// Ключ флага однократной перерегистрации.
    static let flagKey = "pref.loginItemReregistered"

    /// Чистое решение: перерегистрировать автозапуск или нет.
    ///
    /// Только когда пользовательский флаг включён, система об автозапуске под
    /// новым id ещё не знает и перерегистрацию мы ещё не пробовали. Повторные
    /// попытки не нужны: в неподписанной dev-сборке `register()` всегда
    /// падает, и без флага мы бы дёргали его на каждом запуске.
    static func shouldReregister(prefEnabled: Bool,
                                 systemRegistered: Bool,
                                 alreadyDone: Bool) -> Bool {
        prefEnabled && !systemRegistered && !alreadyDone
    }
}
