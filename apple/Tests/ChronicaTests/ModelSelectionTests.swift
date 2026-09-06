import XCTest
import TranscriberCore
@testable import Chronica

/// Behavioral tests for the pure "UI selection → core ModelSpec" mapping (P2).
/// These assert logic/contract, not UI rendering.
final class ModelSelectionTests: XCTestCase {

    func testParakeetSelectionMapsToParakeetSpec() {
        let sel = ModelSelection(family: .parakeet, modelId: "parakeet-tdt-0.6b-v3-int8")
        guard case .parakeet(let id) = sel.toModelSpec() else {
            return XCTFail("expected .parakeet spec")
        }
        XCTAssertEqual(id, "parakeet-tdt-0.6b-v3-int8")
    }

    func testWhisperSelectionMapsToWhisperSpec() {
        let sel = ModelSelection(family: .whisper, modelId: "large-v3-turbo-q5_0")
        guard case .whisper(let id) = sel.toModelSpec() else {
            return XCTFail("expected .whisper spec")
        }
        XCTAssertEqual(id, "large-v3-turbo-q5_0")
    }

    func testRoundTripFromSpecPreservesFamilyAndId() {
        let specs: [ModelSpec] = [
            .parakeet(id: "parakeet-tdt-0.6b-v3-int8"),
            .whisper(id: "small-q5_1"),
            .whisper(id: "base-q5_1"),
        ]
        for spec in specs {
            let sel = ModelSelection(modelSpec: spec)
            XCTAssertEqual(sel.toModelSpec(), spec, "round-trip must be identity for \(spec)")
        }
    }

    func testInverseRecoversWhisperFamily() {
        let sel = ModelSelection(modelSpec: .whisper(id: "medium-q5_0"))
        XCTAssertEqual(sel.family, .whisper)
        XCTAssertEqual(sel.modelId, "medium-q5_0")
    }

    func testInverseRecoversParakeetFamily() {
        let sel = ModelSelection(modelSpec: .parakeet(id: "parakeet-tdt-0.6b-v3-int8"))
        XCTAssertEqual(sel.family, .parakeet)
    }

    func testEngineFamilyRuntimeRoutingIsStable() {
        // The family→runtime contract the core relies on for routing.
        XCTAssertEqual(EngineFamily.parakeet.runtime, "sherpa-onnx")
        XCTAssertEqual(EngineFamily.whisper.runtime, "whisper.cpp")
        // Family tag matches the core's ModelStatus.family string for filtering.
        XCTAssertEqual(EngineFamily.whisper.coreFamilyTag, "whisper")
        XCTAssertEqual(EngineFamily.parakeet.coreFamilyTag, "parakeet")
    }

    func testStateLabelsAreNonEmptyForEveryState() {
        // Reducer-style formatting: every session state yields a user label.
        for s: SessionState in [.idle, .loading, .recording, .stopping, .error] {
            XCTAssertFalse(StateText.label(s).isEmpty)
        }
    }

    // MARK: - Staging модели (применяется только по кнопке «Применить»)

    @MainActor
    func testStagingDifferentModelMarksPending() {
        let engine = makeIsolatedEngine()
        // Активная по умолчанию — Parakeet. Выбор Whisper должен встать в очередь.
        let whisper = ModelSelection(family: .whisper, modelId: "large-v3-turbo-q5_0")
        engine.stageModel(whisper)
        XCTAssertTrue(engine.hasPendingModel)
        XCTAssertEqual(engine.pendingModel, whisper)
        // Активная модель НЕ меняется до применения.
        XCTAssertEqual(engine.selection, ModelSelection.defaultParakeet)
        XCTAssertEqual(engine.effectiveSelection, whisper)
    }

    @MainActor
    func testStagingActiveModelClearsPending() {
        let engine = makeIsolatedEngine()
        // Выбор уже активной модели не создаёт «ожидающего» применения.
        engine.stageModel(engine.selection)
        XCTAssertFalse(engine.hasPendingModel)
        XCTAssertNil(engine.pendingModel)
        XCTAssertEqual(engine.effectiveSelection, engine.selection)
    }
}
