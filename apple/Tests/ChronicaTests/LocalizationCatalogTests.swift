import XCTest
@testable import Chronica

// =============================================================================
// Инструменты для языконезависимых тестов
// =============================================================================

/// Доступ к каталогу строк и к конкретным локализациям из тестов.
///
/// Нужен там, где проверяется НЕ формулировка, а поведение: тест не должен
/// «прибиваться» к русскому тексту, иначе смена языка сборки его ломает.
enum L10nTestSupport {

    /// Сырой каталог строк. Лежит в том же ресурсном бандле, что и продукты
    /// его компиляции, поэтому читается без путей к исходникам.
    static func catalog() throws -> [String: [String: Any]] {
        let url = try XCTUnwrap(
            Bundle.strings.url(forResource: "Localizable", withExtension: "xcstrings"),
            "Localizable.xcstrings нет в ресурсном бандле")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en",
                       "исходный язык каталога — английский")
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    /// Языки, которые обязан поддерживать интерфейс.
    static let languages = ["en", "ru"]

    /// Категории плюрализации, обязательные для русского языка.
    static let russianPluralCategories = ["one", "few", "many", "other"]

    /// Подбандл конкретной локализации (`<lang>.lproj`).
    static func bundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.strings.path(forResource: language, ofType: "lproj"),
                                 "нет \(language).lproj в ресурсном бандле")
        return try XCTUnwrap(Bundle(path: path))
    }

    /// Строка по ключу в конкретной локализации.
    static func string(_ key: String, language: String) throws -> String {
        try bundle(language).localizedString(forKey: key, value: nil, table: nil)
    }

    /// Строка-формат по ключу в конкретной локализации (в т.ч. плюрализация).
    static func format(_ key: String, language: String,
                       _ arguments: any CVarArg...) throws -> String {
        let format = try string(key, language: language)
        return String(format: format, locale: Locale(identifier: language),
                      arguments: arguments)
    }

    /// Число в том виде, в каком его печатает ИНТЕРФЕЙС.
    ///
    /// Система счисления — региональная настройка пользователя: при
    /// `@numbers=arab` «137» выглядит как «١٣٧», при `@numbers=hanidec` — как
    /// «一三七». Поэтому искать в локализованной строке латинские цифры нельзя:
    /// на такой машине их там законно нет. Тесты, которым важно «число попало
    /// в строку», сравнивают с этим представлением.
    static func localizedNumber(_ value: Int) -> String {
        String(format: "%lld", locale: Bundle.stringsLocale, value)
    }
}

// =============================================================================
// Полнота и целостность каталога
// =============================================================================

/// Контракт каталога строк: у КАЖДОГО ключа есть английский и русский перевод,
/// он непустой и в состоянии «переведено», а у plural-ключей есть все формы,
/// которых требует русский язык.
final class LocalizationCatalogTests: XCTestCase {

    func testCatalogIsNotEmpty() throws {
        let strings = try L10nTestSupport.catalog()
        XCTAssertGreaterThan(strings.count, 150,
                             "в каталоге должны быть все строки интерфейса")
    }

    func testEveryKeyIsTranslatedIntoBothLanguages() throws {
        let strings = try L10nTestSupport.catalog()
        for (key, entry) in strings {
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any],
                                              "\(key): нет localizations")
            for language in L10nTestSupport.languages {
                let node = try XCTUnwrap(localizations[language] as? [String: Any],
                                         "\(key): нет локализации \(language)")
                for unit in Self.stringUnits(node) {
                    let state = unit["state"] as? String
                    XCTAssertEqual(state, "translated",
                                   "\(key)/\(language): состояние \(state ?? "nil")")
                    let value = unit["value"] as? String
                    XCTAssertFalse((value ?? "").isEmpty,
                                   "\(key)/\(language): пустое значение")
                }
                XCTAssertFalse(Self.stringUnits(node).isEmpty,
                               "\(key)/\(language): ни stringUnit, ни variations")
            }
        }
    }

    func testPluralKeysCarryEveryCategoryRussianNeeds() throws {
        let strings = try L10nTestSupport.catalog()
        var pluralKeys: [String] = []
        for (key, entry) in strings {
            guard let localizations = entry["localizations"] as? [String: Any],
                  let ru = localizations["ru"] as? [String: Any],
                  let variations = ru["variations"] as? [String: Any],
                  let plural = variations["plural"] as? [String: Any] else { continue }
            pluralKeys.append(key)
            for category in L10nTestSupport.russianPluralCategories {
                XCTAssertNotNil(plural[category],
                                "\(key): у русского plural нет формы «\(category)»")
            }
            // Английскому хватает one/other, но обе формы обязательны.
            let en = try XCTUnwrap(localizations["en"] as? [String: Any])
            let enPlural = try XCTUnwrap(
                (en["variations"] as? [String: Any])?["plural"] as? [String: Any],
                "\(key): английский вариант ключа не plural")
            XCTAssertNotNil(enPlural["one"], "\(key): у английского plural нет «one»")
            XCTAssertNotNil(enPlural["other"], "\(key): у английского plural нет «other»")
        }
        XCTAssertFalse(pluralKeys.isEmpty, "в каталоге должны быть plural-ключи")
    }

    /// Число подстановок обязано совпадать: пропущенный `%@` в одном языке —
    /// это либо потерянные данные, либо падение `String(format:)`.
    func testPlaceholderCountsMatchBetweenLanguages() throws {
        let strings = try L10nTestSupport.catalog()
        for (key, entry) in strings {
            guard let localizations = entry["localizations"] as? [String: Any] else { continue }
            let counts = L10nTestSupport.languages.map { language -> Int in
                guard let node = localizations[language] as? [String: Any] else { return -1 }
                return Self.stringUnits(node)
                    .map { Self.placeholderCount($0["value"] as? String ?? "") }
                    .max() ?? 0
            }
            XCTAssertEqual(Set(counts).count, 1,
                           "\(key): разное число подстановок по языкам — \(counts)")
        }
    }

    /// Каталог — источник истины, а `.lproj` рядом с ним — продукт его
    /// компиляции (`xcstringstool compile`). Тест ловит расхождение: правку
    /// каталога без пересборки строк.
    func testCompiledStringsAreInSyncWithTheCatalog() throws {
        let strings = try L10nTestSupport.catalog()
        for language in L10nTestSupport.languages {
            let bundle = try L10nTestSupport.bundle(language)
            for key in strings.keys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key,
                                  "\(language): ключ «\(key)» не скомпилирован — "
                                  + "перезапустите `xcstringstool compile`")
            }
        }
    }

    // MARK: разбор узлов каталога

    /// Все `stringUnit` внутри локализации: одиночный или все формы plural.
    private static func stringUnits(_ node: [String: Any]) -> [[String: Any]] {
        if let unit = node["stringUnit"] as? [String: Any] { return [unit] }
        guard let variations = node["variations"] as? [String: Any] else { return [] }
        return variations.values
            .compactMap { $0 as? [String: Any] }
            .flatMap { $0.values.compactMap { $0 as? [String: Any] } }
            .compactMap { $0["stringUnit"] as? [String: Any] }
    }

    /// Сколько аргументов ждёт формат (`%@`, `%lld`, `%1$@`…). `%%` не считаем.
    private static func placeholderCount(_ value: String) -> Int {
        var count = 0
        var index = value.startIndex
        while let percent = value[index...].firstIndex(of: "%") {
            let next = value.index(after: percent)
            guard next < value.endIndex else { break }
            if value[next] == "%" {
                index = value.index(after: next)
                continue
            }
            // `%#@name@` — переменная плюрализации, аргумент у неё один.
            count += 1
            index = next
        }
        return count
    }
}

// =============================================================================
// Локализация действительно РАБОТАЕТ (а не только лежит в каталоге)
// =============================================================================

final class LocalizationLookupTests: XCTestCase {

    func testBundleShipsBothLocalizations() throws {
        let localizations = Set(Bundle.strings.localizations)
        for language in L10nTestSupport.languages {
            XCTAssertTrue(localizations.contains(language),
                          "в бандле нет локализации \(language)")
        }
    }

    /// Ключевая проверка: одна и та же строка в разных локалях даёт РАЗНЫЙ
    /// непустой текст — значит переводы подхватываются, а не подставляется ключ.
    func testSameKeyGivesDifferentTextPerLanguage() throws {
        let en = try L10nTestSupport.string("popover.start", language: "en")
        let ru = try L10nTestSupport.string("popover.start", language: "ru")
        XCTAssertFalse(en.isEmpty)
        XCTAssertFalse(ru.isEmpty)
        XCTAssertNotEqual(en, "popover.start")
        XCTAssertNotEqual(ru, "popover.start")
        XCTAssertNotEqual(en, ru, "перевод не подхватился")
        XCTAssertEqual(en, "Start Recording")
        XCTAssertEqual(ru, "Начать запись")
    }

    /// `L(...)` в рантайме отдаёт перевод для текущей локали, а не ключ.
    func testRuntimeHelperResolvesKeys() {
        for key in ["popover.start", "popover.stop", "section.journal",
                    "settings.general.launchAtLogin", "models.size.unknown"] {
            let value = L(String.LocalizationValue(key))
            XCTAssertNotEqual(value, key, "ключ «\(key)» не разрешился")
            XCTAssertFalse(value.isEmpty)
        }
    }

    /// Русская плюрализация: 1 запись · 2 записи · 5 записей · 11 записей.
    func testRussianPluralFormsAreApplied() throws {
        let expected: [(Int, String)] = [
            (1, "1 запись"), (2, "2 записи"), (5, "5 записей"),
            (11, "11 записей"), (21, "21 запись"), (112, "112 записей"),
            (0, "0 записей"),
        ]
        for (count, text) in expected {
            XCTAssertEqual(try L10nTestSupport.format("metric.records", language: "ru", count),
                           text)
        }
    }

    func testEnglishPluralFormsAreApplied() throws {
        XCTAssertEqual(try L10nTestSupport.format("metric.records", language: "en", 1),
                       "1 record")
        XCTAssertEqual(try L10nTestSupport.format("metric.records", language: "en", 5),
                       "5 records")
    }

    /// Регрессия: формы слова обязаны следовать языку ИНТЕРФЕЙСА, а не языковой
    /// части `Locale.current`. Русский интерфейс с американским регионом даёт
    /// `Locale.current == en_US` — тогда русские `few`/`many` схлопывались в
    /// английский `other` и «3 интервала» печаталось как «3 интервалов».
    func testPluralRulesFollowTheInterfaceLanguageNotTheRegion() throws {
        XCTAssertEqual(Bundle.stringsLocale.language.languageCode?.identifier,
                       Bundle.appLanguage,
                       "локаль подстановки обязана говорить на языке интерфейса")
        // Регион сравниваем с ФАКТИЧЕСКИМ регионом машины, каким бы он ни был,
        // включая «не задан» (`nil == nil`): проверяется сохранение, а не
        // конкретная страна.
        XCTAssertEqual(Bundle.stringsLocale.region, Locale.current.region,
                       "регион пользователя (разделители, календарь) сохраняется")
        // Рантайм-результат совпадает с формой для языка интерфейса.
        //
        // Эталон считаем в ТОЙ ЖЕ подстановочной локали, а не в голой
        // `Locale(identifier:)`: иначе тест сверял бы заодно и написание цифр,
        // а оно законно региональное (при `numbers=arab` пользователь видит
        // «١ record», и это правильно). Проверяется выбор ФОРМЫ по языку
        // интерфейса, а не система счисления.
        let interfaceFormat = try L10nTestSupport.string("metric.records",
                                                         language: Bundle.appLanguage)
        for count in [1, 3, 5, 11, 21] {
            XCTAssertEqual(L("metric.records", count),
                           String(format: interfaceFormat,
                                  locale: Bundle.stringsLocale, arguments: [count]))
        }
        // И три русские формы действительно различаются.
        let forms = try [1, 3, 5].map {
            try L10nTestSupport.format("metric.records", language: "ru", $0)
        }
        XCTAssertEqual(Set(forms).count, 3, "русские one/few/many дают разные формы")
    }

    /// Тот же инвариант, но на ЯВНО заданных локалях-входах: настройки машины
    /// прогона не участвуют вовсе.
    ///
    /// Подмена языка обязана менять ТОЛЬКО язык. Регион — это разделители
    /// чисел, календарь и единицы; он живёт субтегом ЯЗЫКА (`en_US` →
    /// languageComponents.region == US), поэтому замена языковых компонент
    /// целиком молча стирала его у всех, кроме машин с отдельным «Регионом» в
    /// Системных настройках (там он приезжает ключом `@rg=` и уцелевал). Ровно
    /// поэтому баг не был виден локально и вылез только на CI.
    func testInterfaceLanguageSwapKeepsTheUserRegion() {
        // Регион есть; отдельный «Регион» в настройках; экзотическая
        // письменность; посторонние ключи локали.
        let withRegion = ["en_US", "ru_RU", "en_RU", "en_GB", "ru_KZ", "en_001",
                          "zh_Hans_CN", "en_US@rg=ruzzzz", "en_US@calendar=japanese"]
        // Региона нет вовсе — как у части машин CI.
        let withoutRegion = ["en", "ru"]

        for baseId in withRegion + withoutRegion {
            let base = Locale(identifier: baseId)
            for language in L10nTestSupport.languages {
                let locale = Bundle.stringsLocale(base: base, language: language)
                XCTAssertEqual(locale.language.languageCode?.identifier, language,
                               "\(baseId) → \(language): язык интерфейса не подставился")
                XCTAssertEqual(locale.region, base.region,
                               "\(baseId) → \(language): регион пользователя обязан уцелеть")
            }
        }

        // Наблюдаемое следствие: пока регион задан, разделитель дробной части
        // остаётся региональным и от языка интерфейса не зависит. Это та самая
        // «1,234.5 вместо 1 234,5», которую ловит инвариант.
        for baseId in withRegion {
            let base = Locale(identifier: baseId)
            for language in L10nTestSupport.languages {
                let locale = Bundle.stringsLocale(base: base, language: language)
                XCTAssertEqual(locale.decimalSeparator, base.decimalSeparator,
                               "\(baseId) → \(language): разделитель дробной части — "
                               + "региональная настройка, язык её не меняет")
                XCTAssertEqual(locale.groupingSeparator, base.groupingSeparator,
                               "\(baseId) → \(language): разделитель разрядов тоже региональный")
            }
        }
    }

    /// Наблюдаемый симптом потери региона — счётчики от тысячи.
    ///
    /// `String(format:locale:)` применяет к `%lld` и разделитель разрядов, и
    /// письменность цифр, а в интерфейсе есть счётчики, которые легко
    /// переваливают за тысячу («N записей» в сводке хранилища). Значит разряды
    /// обязаны группироваться по-РЕГИОНАЛЬНОМУ даже тогда, когда интерфейс на
    /// другом языке. Эталон — та же база: ни один разделитель не зашит.
    func testThousandsAreGroupedByRegionNotByInterfaceLanguage() {
        for (baseId, language) in [("en_US", "ru"), ("ru_RU", "en"), ("de_DE", "en"),
                                   ("de_DE", "ru"), ("en_US", "en"), ("ru_RU", "ru")] {
            let base = Locale(identifier: baseId)
            let locale = Bundle.stringsLocale(base: base, language: language)
            for value in [1234, 1_234_567] {
                XCTAssertEqual(String(format: "%lld", locale: locale, value),
                               String(format: "%lld", locale: base, value),
                               "\(baseId) → \(language): \(value) обязано группироваться "
                               + "по региону пользователя, а не по языку интерфейса")
            }
        }
    }

    /// Формы слова определяются ЯЗЫКОМ подстановочной локали и не зависят от
    /// того, какой регион у пользователя.
    func testPluralFormsDependOnLanguageAndNotOnRegion() throws {
        let ruFormat = try L10nTestSupport.string("metric.records", language: "ru")
        let expected = try [1, 3, 5].map {
            try L10nTestSupport.format("metric.records", language: "ru", $0)
        }
        for baseId in ["en_US", "ru_RU", "en_001", "zh_Hans_CN", "en"] {
            let locale = Bundle.stringsLocale(base: Locale(identifier: baseId), language: "ru")
            let forms = [1, 3, 5].map {
                String(format: ruFormat, locale: locale, arguments: [$0])
            }
            XCTAssertEqual(forms, expected,
                           "\(baseId): русские one/few/many не должны зависеть от региона")
        }
    }

    /// Промпт vision-модели следует языку ИНТЕРФЕЙСА: журнал экрана не должен
    /// наполняться записями на чужом языке.
    func testVisionPromptLanguageFollowsTheInterface() throws {
        XCTAssertTrue(L10nTestSupport.languages.contains(VisionPrompt.language),
                      "язык промпта — одна из локализаций приложения")
        XCTAssertEqual(VisionPrompt.language, Bundle.appLanguage)

        let ru = try L10nTestSupport.string("vision.prompt.body", language: "ru")
        let en = try L10nTestSupport.string("vision.prompt.body", language: "en")
        XCTAssertTrue(ru.contains("по-русски"), "русский промпт просит русский ответ")
        XCTAssertTrue(en.contains("in English"), "английский промпт просит английский ответ")
    }
}
