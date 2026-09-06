import XCTest
import TranscriberCore
@testable import Chronica

/// Пользователю нельзя показывать сырой дамп `CoreError` вида
/// `ModelLoad("sherpa: ...")`. Проверяем контракт маппинга: короткая понятная
/// фраза из каталога строк + опциональная техническая деталь.
///
/// Сравниваем с `L(...)`, а не с русскими литералами: интерфейс локализован
/// (en/ru), и тест обязан проходить на любом языке сборки.
final class ErrorMessageTests: XCTestCase {

    func testCoreErrorsMapToActionablePhrasesFromTheCatalog() {
        let cases: [(CoreError, String)] = [
            (.ModelLoad("sherpa"), "error.core.modelLoad"),
            (.ModelDownload("timeout"), "error.core.modelDownload"),
            (.Audio("device"), "error.core.audio"),
            (.Backend("onnx"), "error.core.backend"),
            (.Store("disk full"), "error.core.store"),
            (.Api("port busy"), "error.core.api"),
            (.Config("bad interval"), "error.core.config"),
            (.Internal("panic"), "error.core.internal"),
        ]
        for (error, key) in cases {
            let message = Engine.humanMessage(error)
            let phrase = L(String.LocalizationValue(key))
            XCTAssertNotEqual(phrase, key, "ключ «\(key)» не разрешился в текст")
            XCTAssertTrue(message.hasPrefix(phrase),
                          "«\(message)» не начинается с фразы ключа «\(key)»")
            // Ни один вариант не должен протекать сырым представлением кейса.
            XCTAssertFalse(message.hasPrefix("ModelLoad"))
            XCTAssertFalse(message.contains("CoreError"))
        }
    }

    /// Каждый кейс получает СВОЮ фразу: одинаковый текст на две разные причины
    /// не подсказывает пользователю, что делать.
    func testEveryCoreErrorHasItsOwnPhrase() {
        let messages = [
            Engine.humanMessage(CoreError.ModelLoad("")),
            Engine.humanMessage(CoreError.ModelDownload("")),
            Engine.humanMessage(CoreError.Audio("")),
            Engine.humanMessage(CoreError.Backend("")),
            Engine.humanMessage(CoreError.Store("")),
            Engine.humanMessage(CoreError.Api("")),
            Engine.humanMessage(CoreError.Config("")),
            Engine.humanMessage(CoreError.Internal("")),
        ]
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertFalse(messages.contains(where: \.isEmpty))
    }

    func testShortTechnicalDetailIsKeptAndLongOneIsDropped() {
        let short = Engine.humanMessage(CoreError.ModelLoad("sherpa: no such file"))
        XCTAssertTrue(short.contains("sherpa: no such file"))

        let long = Engine.humanMessage(CoreError.ModelLoad(String(repeating: "x", count: 400)))
        XCTAssertFalse(long.contains("xxx"))
        XCTAssertEqual(long, L("error.core.modelLoad"))

        let multiline = Engine.humanMessage(CoreError.Store("first line\nsecond line"))
        XCTAssertFalse(multiline.contains("\n"))
    }

    func testAudioCaptureErrorsKeepTheirOwnUserFacingText() {
        let denied = Engine.humanMessage(AudioCaptureError.micPermissionDenied)
        XCTAssertEqual(denied, L("error.audio.micDenied"))
        // Фраза обязана называть, ГДЕ выдать доступ, — на обоих языках.
        for language in L10nTestSupport.languages {
            let text = try? L10nTestSupport.string("error.audio.micDenied", language: language)
            XCTAssertTrue(text?.contains("→") ?? false,
                          "\(language): нет пути в Системных настройках")
        }

        let system = Engine.humanMessage(
            AudioCaptureError.systemAudioUnavailable(reason: "no display"))
        XCTAssertEqual(system, L("error.audio.systemUnavailable", "no display"))
        XCTAssertTrue(system.contains("no display"), "причина обязана дойти до пользователя")
    }

    func testUnknownErrorStillProducesUserFacingPhrase() {
        struct Weird: Error {}
        let message = Engine.humanMessage(Weird())
        XCTAssertTrue(message.hasPrefix(L("error.unexpected")))
    }

    /// Обе локализации отдают непустую фразу для каждой причины сбоя.
    func testErrorPhrasesExistInBothLanguages() throws {
        let keys = [
            "error.core.config", "error.core.modelLoad", "error.core.modelDownload",
            "error.core.audio", "error.core.backend", "error.core.store",
            "error.core.api", "error.core.internal", "error.unexpected",
            "error.audio.micDenied", "error.audio.micNotDetermined",
            "error.relaunchFailed", "error.pipelineStalled",
        ]
        for key in keys {
            for language in L10nTestSupport.languages {
                let text = try L10nTestSupport.string(key, language: language)
                XCTAssertNotEqual(text, key, "\(language): нет перевода для «\(key)»")
                XCTAssertFalse(text.isEmpty)
            }
        }
    }
}
