import Foundation

// =============================================================================
// Локализация интерфейса (английский + русский, язык — системный)
// =============================================================================
//
// Единственный источник строк — каталог `Sources/Chronica/Resources/
// Localizable.xcstrings` (source language `en`, локализации `en` и `ru`).
// Рядом с каталогом лежат СКОМПИЛИРОВАННЫЕ им же файлы
// `{en,ru}.lproj/Localizable.{strings,stringsdict}`: SwiftPM (в отличие от
// Xcode) не умеет компилировать `.xcstrings` сам, поэтому продукты компиляции
// коммитятся рядом и попадают в ресурсный бандл как локализованные ресурсы.
// Пересобрать их после правки каталога:
//
//     xcrun --sdk macosx xcstringstool compile \
//         apple/Sources/Chronica/Resources/Localizable.xcstrings \
//         -o apple/Sources/Chronica/Resources
//
// Тест `LocalizationCatalogTests` следит за тем, чтобы каталог и продукты
// компиляции не разъезжались.

extension Bundle {
    /// Бандл с каталогом строк.
    ///
    /// SwiftPM генерирует `Bundle.module` для ИСПОЛНЯЕМОГО таргета так, что
    /// ресурсный бандл ищется рядом с `Bundle.main.bundleURL`. Для собранного
    /// `.app` это КОРЕНЬ бандла приложения — класть туда ресурсы нельзя
    /// (вложенный бандл вне `Contents` ломает раскладку и подпись). Поэтому
    /// сначала ищем штатное место — `Contents/Resources` (туда бандл кладут
    /// `Scripts/install-debug.sh` и `Scripts/package-app.sh`), и только затем
    /// используем `Bundle.module` (пути сборки `swift build`/`swift test`).
    ///
    /// `Bundle.module` — `static let` и падает, если бандла нет, поэтому к нему
    /// обращаемся ТОЛЬКО когда штатное место не сработало.
    static let strings: Bundle = {
        let bundleName = "Chronica_Chronica.bundle"
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent(bundleName)) {
            return bundle
        }
        return .module
    }()

    /// Язык, на котором приложение реально показывает интерфейс.
    ///
    /// Это НЕ `Locale.current.identifier`: система может стоять на языке, для
    /// которого локализации нет, — тогда Foundation отдаёт `en`. Значение нужно
    /// там, где язык интерфейса уезжает наружу (промпт vision-модели).
    static var appLanguage: String {
        Bundle.strings.preferredLocalizations.first ?? "en"
    }

    /// Локаль для подстановки аргументов в локализованные форматы.
    ///
    /// Берёт РЕГИОНАЛЬНЫЕ настройки пользователя (`Locale.current`: разделители
    /// разрядов, календарь, единицы) и подменяет в них только ЯЗЫК — на язык
    /// интерфейса. Это важно для плюрализации: правила форм слова берутся из
    /// локали, а не из бандла, и при русском интерфейсе с американским регионом
    /// `Locale.current` остаётся `en_US` — тогда «3 интервала» превращалось в
    /// «3 интервалов» (русские `few`/`many` схлопывались в английский `other`).
    /// Так бывает ровно в том сценарии, ради которого локализация и делается:
    /// язык одного приложения выбран в Системных настройках → Приложения.
    static let stringsLocale: Locale = {
        var components = Locale.Components(locale: .current)
        components.languageComponents = .init(identifier: Bundle.appLanguage)
        return Locale(components: components)
    }()
}

/// Локализованная строка по стабильному семантическому ключу.
///
/// Ключи вида `popover.start`, `settings.general.launchAtLogin` — не сам текст:
/// правка формулировки не должна ломать перевод.
func L(_ key: String.LocalizationValue, comment: StaticString = "") -> String {
    String(localized: key, bundle: .strings, comment: comment)
}

/// Локализованная строка-ФОРМАТ с аргументами.
///
/// Работает и с обычными форматами (`%@`, `%lld`), и с плюрализацией из
/// каталога (`%#@…@` в `.stringsdict`): резолвом занимается
/// `String(format:locale:arguments:)`, то есть тот же путь, что и
/// `String.localizedStringWithFormat`. Первый аргумент обязателен — иначе
/// перегрузка была бы неоднозначна с вариантом без аргументов.
func L(_ key: String, _ firstArgument: any CVarArg,
       _ moreArguments: any CVarArg...) -> String {
    let format = Bundle.strings.localizedString(forKey: key, value: nil, table: nil)
    return String(format: format, locale: Bundle.stringsLocale,
                  arguments: [firstArgument] + moreArguments)
}

/// Локализованная строка в языке ИНТЕРФЕЙСА, а не системной локали.
///
/// Нужна для текста, который уезжает во внешнюю модель (промпт vision-LLM):
/// модель обязана отвечать на том языке, который пользователь видит в
/// интерфейсе, даже если системная локаль — третья.
func LApp(_ key: String, _ arguments: any CVarArg...) -> String {
    let format = Bundle.appLanguageStrings
        .localizedString(forKey: key, value: nil, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Bundle.stringsLocale, arguments: arguments)
}

extension Bundle {
    /// Подбандл конкретной локализации (`<lang>.lproj`) языка интерфейса.
    /// `Bundle.strings`, если подбандл почему-то не нашёлся.
    static let appLanguageStrings: Bundle = {
        guard let path = Bundle.strings.path(forResource: Bundle.appLanguage,
                                             ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .strings }
        return bundle
    }()
}
