import Foundation
import TranscriberCore

/// The transcription engine family the user can choose between in the UI.
///
/// This is a presentation-level concept that maps deterministically onto the
/// core's ``ModelSpec``. `parakeet` routes to the sherpa-onnx runtime
/// (multilingual NeMo transducer); `whisper` routes to the whisper.cpp (ggml)
/// runtime built into the core. The mapping is the single source of truth the
/// Models/Settings UI uses to translate a click into a core config.
public enum EngineFamily: String, CaseIterable, Identifiable, Sendable {
    case parakeet
    case whisper

    public var id: String { rawValue }

    /// Human-facing name shown in the picker.
    public var displayName: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .whisper: return "Whisper"
        }
    }

    /// The core ASR runtime that serves this family (informational).
    public var runtime: String {
        switch self {
        case .parakeet: return "sherpa-onnx"
        case .whisper: return "whisper.cpp"
        }
    }

    /// The `ModelStatus.family` string the core reports for this engine, so the
    /// UI can filter the model registry by family.
    public var coreFamilyTag: String { rawValue }
}

/// A user-facing model choice: an engine family plus a concrete model id from
/// the core registry (e.g. `"parakeet-tdt-0.6b-v3-int8"` or
/// `"large-v3-turbo-q5_0"`).
///
/// `ModelSelection` is intentionally tiny and value-typed so the
/// "UI choice → ``ModelSpec``" mapping is a pure function that can be unit
/// tested without a running core.
public struct ModelSelection: Equatable, Sendable {
    public let family: EngineFamily
    public let modelId: String

    public init(family: EngineFamily, modelId: String) {
        self.family = family
        self.modelId = modelId
    }

    /// The default Parakeet selection (the product default model).
    public static let defaultParakeet = ModelSelection(
        family: .parakeet, modelId: "parakeet-tdt-0.6b-v3-int8")
}

extension ModelSelection {
    /// Pure mapping from a UI selection to the core's ``ModelSpec``.
    ///
    /// This is the behavioral contract P2 cares about: choosing Parakeet yields
    /// `.parakeet(id:)` (served by sherpa), choosing any Whisper variant yields
    /// `.whisper(id:)` (served by whisper.cpp). The core then routes Whisper →
    /// whisper.cpp → sherpa → mock, and Parakeet → CoreML → sherpa → mock.
    public func toModelSpec() -> ModelSpec {
        switch family {
        case .parakeet: return .parakeet(id: modelId)
        case .whisper: return .whisper(id: modelId)
        }
    }

    /// Recover the UI selection from a core ``ModelSpec`` (inverse of
    /// ``toModelSpec()``), used to highlight the active row on load.
    public init(modelSpec: ModelSpec) {
        switch modelSpec {
        case .parakeet(let id): self.init(family: .parakeet, modelId: id)
        case .whisper(let id): self.init(family: .whisper, modelId: id)
        }
    }
}
