import XCTest
@testable import Chronica
@testable import TranscriberCore

/// Поведенческие тесты витрины реестра моделей.
///
/// В реестре ядра три десятка вариантов Whisper. Контракт: в основном списке
/// видны Parakeet и небольшой разумный набор Whisper, но модель НИКОГДА не
/// пропадает из него, если она активная, выбранная, установлена или сейчас
/// скачивается — иначе её нельзя найти, чтобы переключиться или удалить.
final class ModelCatalogTests: XCTestCase {

    private let parakeetId = "parakeet-tdt-0.6b-v3-int8"

    private func model(_ id: String,
                       family: String = "whisper",
                       installed: Bool = false,
                       downloading: Bool = false) -> ModelStatus {
        ModelStatus(id: id, label: id, family: family, runtime: "whisper.cpp",
                    installed: installed, downloadedBytes: 0, totalBytes: 0,
                    progressPct: 0, downloading: downloading, lastError: "")
    }

    /// Реестр, похожий на настоящий: Parakeet + много вариантов Whisper.
    private func registry() -> [ModelStatus] {
        var out = [model(parakeetId, family: "parakeet")]
        out += ModelCatalog.featuredWhisper.map { model($0) }
        out += (0..<28).map { model("tiny-variant-\($0)") }
        return out
    }

    func testParakeetComesFirst() {
        let primary = ModelCatalog.primary(registry(), activeId: parakeetId, pendingId: nil)
        XCTAssertEqual(primary.first?.id, parakeetId)
    }

    func testPrimaryListStaysShort() {
        let primary = ModelCatalog.primary(registry(), activeId: parakeetId, pendingId: nil)
        XCTAssertEqual(primary.count, 1 + ModelCatalog.featuredWhisper.count)
    }

    func testFeaturedWhisperKeepDeclaredOrder() {
        let primary = ModelCatalog.primary(registry(), activeId: parakeetId, pendingId: nil)
        XCTAssertEqual(primary.dropFirst().map(\.id), ModelCatalog.featuredWhisper)
    }

    func testEverythingElseIsAvailableUnderTheDisclosure() {
        let all = registry()
        let primary = ModelCatalog.primary(all, activeId: parakeetId, pendingId: nil)
        let extra = ModelCatalog.extraWhisper(all, activeId: parakeetId, pendingId: nil)
        let shown = Set(primary.map(\.id)).union(extra.map(\.id))
        XCTAssertEqual(shown, Set(all.map(\.id)), "ни одна модель не теряется")
        XCTAssertTrue(Set(primary.map(\.id)).isDisjoint(with: extra.map(\.id)),
                      "модель не должна дублироваться в двух списках")
    }

    func testInstalledRareModelIsPromotedToPrimaryList() {
        var all = registry()
        // Пользователь когда-то скачал экзотический вариант — его нужно видеть,
        // чтобы иметь возможность его удалить.
        all = all.map { $0.id == "tiny-variant-7" ? model($0.id, installed: true) : $0 }
        let primary = ModelCatalog.primary(all, activeId: parakeetId, pendingId: nil)
        XCTAssertTrue(primary.contains { $0.id == "tiny-variant-7" })
        XCTAssertFalse(ModelCatalog.extraWhisper(all, activeId: parakeetId, pendingId: nil)
            .contains { $0.id == "tiny-variant-7" })
    }

    func testActiveAndPendingRareModelsStayVisible() {
        let all = registry()
        let primary = ModelCatalog.primary(all, activeId: "tiny-variant-3",
                                           pendingId: "tiny-variant-9")
        XCTAssertTrue(primary.contains { $0.id == "tiny-variant-3" })
        XCTAssertTrue(primary.contains { $0.id == "tiny-variant-9" })
    }

    func testDownloadingModelStaysVisible() {
        let all = registry().map {
            $0.id == "tiny-variant-1" ? model($0.id, downloading: true) : $0
        }
        let primary = ModelCatalog.primary(all, activeId: parakeetId, pendingId: nil)
        XCTAssertTrue(primary.contains { $0.id == "tiny-variant-1" },
                      "идущую загрузку нельзя прятать под раскрывающийся список")
    }

    // MARK: служебный VAD

    func testSileroVadNeverAppearsInTheModelLists() {
        // Silero VAD едет вместе с любой ASR-моделью и выбору не подлежит:
        // строка, которую нельзя выбрать, ломает смысл списка. Ядро прячет её
        // из `listModels()`, но витрина не должна на это полагаться.
        let vad = model("silero-vad", family: "vad", installed: true)
        let all = registry() + [vad]
        let primary = ModelCatalog.primary(all, activeId: parakeetId, pendingId: nil)
        let extra = ModelCatalog.extraWhisper(all, activeId: parakeetId, pendingId: nil)
        XCTAssertFalse(primary.contains { $0.id == vad.id })
        XCTAssertFalse(extra.contains { $0.id == vad.id })
    }

    func testDownloadingVadIsStillHiddenFromTheList() {
        // Установленная/скачиваемая модель обычно «закрепляется» в основном
        // списке — на служебный VAD это правило не распространяется.
        let vad = model("silero-vad", family: "vad", downloading: true)
        let primary = ModelCatalog.primary(registry() + [vad],
                                           activeId: parakeetId, pendingId: nil)
        XCTAssertFalse(primary.contains { $0.id == vad.id })
    }

    // MARK: подписи

    func testLanguagesAreDescribedPerFamilyNotPerRuntime() {
        XCTAssertEqual(ModelCatalog.languages(family: "parakeet"),
                       L("models.languages.parakeet", ModelCatalog.parakeetLanguages))
        XCTAssertEqual(ModelCatalog.languages(family: "whisper"),
                       L("models.languages.whisper", ModelCatalog.whisperLanguages))
        // Число языков обязано быть в подписи — оно и есть смысл строки.
        XCTAssertTrue(ModelCatalog.languages(family: "parakeet")
            .contains(L10nTestSupport.localizedNumber(ModelCatalog.parakeetLanguages)))
        XCTAssertTrue(ModelCatalog.languages(family: "whisper")
            .contains(L10nTestSupport.localizedNumber(ModelCatalog.whisperLanguages)))
    }

    /// Размер до скачивания: у Parakeet известен, у остальных — честное
    /// «размер уточняется», а не выдуманная оценка.
    func testApproximateSizeIsHonestWhenUnknown() {
        XCTAssertEqual(ModelCatalog.approximateSize(id: parakeetId),
                       L("models.size.parakeet"))
        XCTAssertEqual(ModelCatalog.approximateSize(id: "large-v3-turbo-q5_0"),
                       L("models.size.unknown"))
        XCTAssertFalse(ModelCatalog.approximateSize(id: "large-v3-turbo-q5_0").contains("1"),
                       "нельзя показывать выдуманный размер")
    }

    func testDisplayNameNeverExposesRuntimeNames() {
        for id in [parakeetId, "large-v3-turbo-q5_0"] {
            let name = ModelCatalog.displayName(id: id)
            XCTAssertFalse(name.lowercased().contains("sherpa"))
            XCTAssertFalse(name.lowercased().contains("onnx"))
            XCTAssertFalse(name.lowercased().contains("ggml"))
        }
        XCTAssertEqual(ModelCatalog.displayName(id: parakeetId), "Parakeet")
    }
}
