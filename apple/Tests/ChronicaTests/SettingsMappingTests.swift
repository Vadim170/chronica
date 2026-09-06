import XCTest
@testable import Chronica
@testable import TranscriberCore

/// Поведенческие тесты перевода формы Настроек в `CoreConfig`.
///
/// Проверяем ровно те решения, где ошибка молча ломает продукт: перевёрнутые
/// границы интервала, мусор в поле порта и включённый API без токена.
@MainActor
final class SettingsMappingTests: XCTestCase {

    private var base: CoreConfig {
        Engine.defaultConfig(storagePath: "/tmp/chronica-test/store",
                             modelsPath: "/tmp/chronica-test/models")
    }

    // MARK: нарезка интервалов

    func testMaxIntervalNeverDropsBelowMin() {
        // Пользователь увёл «мин» выше «макс»: ядро с перевёрнутыми границами
        // не режет интервалы вовсе, поэтому макс подтягивается к мин.
        let c = SettingsMapping.transcription(base, minS: 240, maxS: 60,
                                              silenceMs: 2000, vadThreshold: 0.5,
                                              language: .auto)
        XCTAssertEqual(c.minIntervalS, 240)
        XCTAssertGreaterThanOrEqual(c.maxIntervalS, c.minIntervalS)
        XCTAssertEqual(c.maxIntervalS, 240)
    }

    func testValuesAreClampedIntoSupportedRange() {
        let c = SettingsMapping.transcription(base, minS: -100, maxS: 100_000,
                                              silenceMs: 0, vadThreshold: 5,
                                              language: .auto)
        XCTAssertEqual(c.minIntervalS, 10)
        XCTAssertEqual(c.maxIntervalS, 600)
        XCTAssertEqual(c.silenceCutMs, 500)
        XCTAssertEqual(c.vad.sileroThreshold, 0.9, accuracy: 0.0001)
    }

    func testNonFiniteSliderValuesDoNotTrapOrExplode() {
        let c = SettingsMapping.transcription(base, minS: .nan, maxS: .infinity,
                                              silenceMs: .nan, vadThreshold: .nan,
                                              language: .auto)
        XCTAssertEqual(c.minIntervalS, 10)
        XCTAssertEqual(c.maxIntervalS, 600)
        XCTAssertEqual(c.silenceCutMs, 500)
        XCTAssertEqual(c.vad.sileroThreshold, 0.1, accuracy: 0.0001)
    }

    func testRmsFallbackIsPreserved() {
        var input = base
        input.vad = VadConfig(sileroThreshold: 0.5, rmsFallback: 0.123)
        let c = SettingsMapping.transcription(input, minS: 30, maxS: 300,
                                              silenceMs: 2000, vadThreshold: 0.6,
                                              language: .auto)
        XCTAssertEqual(c.vad.rmsFallback, 0.123, accuracy: 0.0001)
    }

    // MARK: язык

    func testLanguageChoiceRoundTrips() {
        for choice in LanguageChoice.allCases {
            let c = SettingsMapping.transcription(base, minS: 30, maxS: 300,
                                                  silenceMs: 2000, vadThreshold: 0.5,
                                                  language: choice)
            XCTAssertEqual(LanguageChoice.from(c.language), choice)
        }
    }

    func testUnknownLanguageCodeFallsBackToAuto() {
        XCTAssertEqual(LanguageChoice.from(.fixed(code: "de")), .auto)
        XCTAssertEqual(LanguageChoice.from(.candidates(codes: ["ru", "en"])), .auto)
    }

    // MARK: порт

    func testPortParsingAcceptsValidValue() {
        XCTAssertEqual(SettingsMapping.parsePort(" 9000 "), 9000)
    }

    func testPortParsingFallsBackOnGarbage() {
        XCTAssertEqual(SettingsMapping.parsePort("восемь"), 8765)
        XCTAssertEqual(SettingsMapping.parsePort(""), 8765)
        XCTAssertEqual(SettingsMapping.parsePort("70000"), 8765, "выход за UInt16")
        XCTAssertEqual(SettingsMapping.parsePort("0"), 8765, "нулевой порт недопустим")
    }

    // MARK: токен

    func testEnablingApiWithEmptyTokenGeneratesOne() {
        let c = SettingsMapping.api(base, enabled: true, host: "127.0.0.1",
                                    port: "8765", token: "   ")
        XCTAssertEqual(c.api.token.count, 32)
        XCTAssertTrue(c.api.token.allSatisfy { $0.isHexDigit },
                      "токен — 32 шестнадцатеричных символа")
    }

    func testExistingTokenIsKept() {
        let c = SettingsMapping.api(base, enabled: true, host: "127.0.0.1",
                                    port: "8765", token: "secret")
        XCTAssertEqual(c.api.token, "secret")
    }

    func testDisabledApiDoesNotInventToken() {
        let c = SettingsMapping.api(base, enabled: false, host: "127.0.0.1",
                                    port: "8765", token: "")
        XCTAssertTrue(c.api.token.isEmpty)
    }

    func testEmptyHostFallsBackToLoopback() {
        let c = SettingsMapping.api(base, enabled: true, host: "  ",
                                    port: "8765", token: "t")
        XCTAssertEqual(c.api.host, "127.0.0.1")
    }

    func testRandomTokensDifferBetweenCalls() {
        let a = SettingsMapping.randomToken()
        let b = SettingsMapping.randomToken()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b, "предсказуемый токен не защищает локальный API")
    }

    // MARK: срок хранения расшифровок

    func testRetentionChoiceReachesCoreConfig() {
        // Чистит базу ядро, поэтому выбор пользователя обязан доехать до
        // `CoreConfig.retentionDays` — иначе настройка ничего не делает.
        for choice in TranscriptRetentionChoice.allCases where choice != .forever {
            let c = SettingsMapping.retention(base, days: choice.days)
            XCTAssertEqual(c.retentionDays, UInt32(choice.days), "\(choice.title)")
        }
    }

    func testForeverMeansZeroDaysForTheCore() {
        let c = SettingsMapping.retention(base, days: TranscriptRetentionChoice.forever.days)
        XCTAssertEqual(c.retentionDays, 0, "0 — контракт ядра «хранить всегда»")
    }

    func testBrokenRetentionValueNeverDeletesHistory() {
        // Испорченный UserDefaults не должен превращаться в «удалить всё»:
        // потеря истории необратима, поэтому мусор трактуем как «всегда».
        XCTAssertEqual(SettingsMapping.retention(base, days: -30).retentionDays, 0)
        XCTAssertEqual(SettingsMapping.retention(base, days: Int.min).retentionDays, 0)
    }

    func testRetentionMappingTouchesNothingElse() {
        let c = SettingsMapping.retention(base, days: 90)
        var expected = base
        expected.retentionDays = 90
        XCTAssertEqual(c, expected, "срок хранения не должен задевать другие поля")
    }

    func testSavedRetentionValueIsRestoredIntoThePicker() {
        XCTAssertEqual(TranscriptRetentionChoice.nearest(toDays: 90), .quarter)
        XCTAssertEqual(TranscriptRetentionChoice.nearest(toDays: 365), .year)
        XCTAssertEqual(TranscriptRetentionChoice.nearest(toDays: 0), .forever)
        XCTAssertEqual(TranscriptRetentionChoice.nearest(toDays: -1), .forever)
        // Значение не из списка (правка вне приложения) — ближайший пункт,
        // а не молчаливый откат на дефолт.
        XCTAssertEqual(TranscriptRetentionChoice.nearest(toDays: 200), .halfYear)
    }

    // MARK: дефолты конфига

    func testAudioQueueHoldsAtLeastTenSecondsAt16kHz() {
        // Кольцевой буфер меньше ~10 с терял сэмплы на загрузке модели и
        // всплесках обработки. Значение синхронизировано с дефолтом ядра.
        XCTAssertGreaterThanOrEqual(base.audioQueueSize, 160_000)
    }

    func testDefaultConfigKeepsHistoryForever() {
        XCTAssertEqual(base.retentionDays, 0)
    }
}
