//! ASR backend abstraction. One trait, several implementations selected by
//! model + platform + build features.
//!
//! Two real ASR runtimes sit behind the same [`AsrBackend`] trait:
//!
//! - **sherpa** (ONNX Runtime via `sherpa-rs`) — the cross-platform default,
//!   serving both Parakeet (NeMo transducer) and Whisper (ONNX exports).
//! - **whisper.cpp** (ggml via `whisper-rs`) — a Whisper-only fast path that
//!   consumes the ggml `.bin` weights `model_manager` already downloads (Metal
//!   on Apple, CPU elsewhere). It avoids the ONNX-export requirement that
//!   sherpa-whisper has, so it is preferred for the Whisper family when built.
//!
//! CoreML is an optional Apple fast-path for Parakeet; a mock backend powers
//! tests and the default (ML-free) build.

use crate::errors::CoreError;
use crate::types::{Acceleration, ModelSpec};

/// Minimum number of mono 16 kHz samples accepted by any ASR backend.
///
/// The pipeline normally hands an interval (or a 30 s sub-chunk) to a model,
/// but a final VAD slice can be a short, non-zero tail.  Sherpa's offline
/// feature extractor / encoder can produce a zero-length time axis for such a
/// tail; ONNX Runtime then raises a foreign exception that Rust cannot catch.
/// Keep one conservative floor for every backend instead of relying on a
/// model-specific check at each call site.  `3_200` samples is 200 ms at the
/// pipeline's fixed 16 kHz rate: it leaves roughly 18 ten-millisecond feature
/// frames after the 25 ms analysis window, enough for Parakeet's three
/// stride-2 convolution stages (and comfortably valid for Whisper/whisper.cpp
/// and CoreML).  Inputs shorter than this are intentionally skipped.
pub const MIN_ASR_AUDIO_SAMPLES: usize = 3_200;

/// Return whether a normalized 16 kHz f32 buffer is safe to hand to a native
/// ASR runtime.  The pipeline applies the same [`MIN_ASR_AUDIO_SAMPLES`] floor
/// to its i16 chunks before conversion; keeping the finite-value check here
/// prevents direct native callers from bypassing the contract.
#[inline]
pub(crate) fn is_safe_asr_audio(audio_f32_16k: &[f32]) -> bool {
    audio_f32_16k.len() >= MIN_ASR_AUDIO_SAMPLES
        && audio_f32_16k.iter().all(|sample| sample.is_finite())
}

#[cfg(feature = "coreml")]
pub mod coreml;
#[cfg(feature = "mock-asr")]
pub mod mock;
#[cfg(feature = "sherpa")]
pub mod sherpa;
#[cfg(feature = "whispercpp")]
pub mod whispercpp;

/// One transcription result for a chunk of mono f32 16kHz audio.
#[derive(Clone, Debug, Default)]
pub struct AsrResult {
    pub text: String,
    pub language: Option<String>,
    /// End time of the last segment relative to chunk start, if known.
    pub seg_end_rel: Option<f32>,
}

/// Everything a backend needs at load time.
#[derive(Clone, Debug)]
pub struct BackendInit {
    pub model: ModelSpec,
    pub models_path: String,
    pub n_threads: u32,
    pub acceleration: Acceleration,
}

/// Uniform ASR interface. `transcribe_once` is called under a lock; backends
/// need not be internally reentrant.
pub trait AsrBackend: Send {
    /// Transcribe one chunk (mono f32 normalized to -1..1, 16kHz).
    fn transcribe_once(
        &mut self,
        audio_f32_16k: &[f32],
        language: Option<&str>,
    ) -> Result<AsrResult, CoreError>;

    /// Whisper-style backends return true so the engine runs auto/ru/en
    /// candidates and scores the best. Parakeet returns false (multilingual,
    /// single pass).
    fn supports_multi_candidate(&self) -> bool {
        false
    }
}

/// Instantiate and load the right backend. Selection is per model family:
///
/// - **Whisper**: whisper.cpp (ggml, if built) -> sherpa (ONNX, if built) ->
///   mock. whisper.cpp is preferred because it consumes the ggml weights the
///   registry actually ships; if it fails to load (e.g. weights absent) we fall
///   through to the next runtime.
/// - **Parakeet**: CoreML (if built + Apple + Auto/CoreMl) -> sherpa -> mock.
pub fn create_backend(init: &BackendInit) -> Result<Box<dyn AsrBackend>, CoreError> {
    // --- Parakeet Apple fast path (unchanged) ------------------------------
    #[cfg(feature = "coreml")]
    {
        if matches!(init.model, ModelSpec::Parakeet { .. })
            && matches!(init.acceleration, Acceleration::Auto | Acceleration::CoreMl)
        {
            if let Ok(b) = coreml::CoreMlParakeet::load(init) {
                return Ok(Box::new(b));
            }
            // fall through to sherpa/mock if CoreML path unavailable
        }
    }
    // --- Whisper ggml fast path --------------------------------------------
    #[cfg(feature = "whispercpp")]
    {
        if matches!(init.model, ModelSpec::Whisper { .. }) {
            if let Ok(b) = whispercpp::WhisperCppBackend::load(init) {
                return Ok(Box::new(b));
            }
            // fall through to sherpa/mock if the ggml path is unavailable
        }
    }
    // --- Cross-platform sherpa runtime -------------------------------------
    #[cfg(feature = "sherpa")]
    {
        return Ok(Box::new(sherpa::SherpaBackend::load(init)?));
    }
    #[cfg(all(not(feature = "sherpa"), feature = "mock-asr"))]
    {
        return Ok(Box::new(mock::MockBackend::load(init)?));
    }
    #[allow(unreachable_code)]
    {
        let _ = init;
        Err(CoreError::Backend(
            "no ASR backend compiled in (enable `sherpa`, `whispercpp`, `coreml`, or `mock-asr`)"
                .into(),
        ))
    }
}
