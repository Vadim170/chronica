//! whisper.cpp (ggml) ASR backend via the `whisper-rs` crate (~0.16).
//!
//! This is the fast-path runtime for the Whisper family: it consumes the ggml
//! `.bin` weights that `model_manager` already downloads directly, with no ONNX
//! conversion. On Apple it runs on Metal (GPU/ANE) when the crate is built with
//! the `metal` feature and acceleration is enabled; everywhere else it runs on
//! CPU. This closes the divergence noted in `sherpa.rs` (whisper-through-sherpa
//! requires ONNX exports the registry does not ship).
//!
//! Model file layout mirrors `model_manager::local_files` exactly: a Whisper
//! model `id` resolves to a single file `<models_path>/<id>/ggml-<id>.bin`.
//! Only [`ModelSpec::Whisper`] is handled here; Parakeet stays on sherpa/CoreML.
//!
//! Transcription parameters are ported from the legacy Python WebUI
//! `WhisperCppBackend` (`no_context`, `suppress_blank`, `no_speech_thold=0.6`,
//! no printed output, timestamps suppressed in the text). `n_threads` comes from
//! [`BackendInit`]. Language: `Some(code)` forces it, `None` enables whisper's
//! built-in auto-detection.
//!
//! API verified against docs.rs/whisper-rs 0.16:
//!   * `WhisperContext::new_with_params(path: impl AsRef<Path>,
//!     params: WhisperContextParameters) -> Result<Self, WhisperError>`.
//!   * `WhisperContextParameters` has a public `use_gpu: bool` (Metal toggle).
//!   * `ctx.create_state() -> Result<WhisperState, _>`.
//!   * `FullParams::new(SamplingStrategy::Greedy { best_of })`, with
//!     `set_language(Option<&str>)`, `set_n_threads(i32)`, `set_no_context`,
//!     `set_suppress_blank`, `set_no_speech_thold`, `set_print_*`,
//!     `set_translate`, `set_token_timestamps`.
//!   * `state.full(params, &[f32]) -> Result<(), _>`,
//!     `state.full_n_segments() -> i32`, `state.get_segment(i) ->
//!     Option<WhisperSegment>` with `to_str()` and `end_timestamp()`
//!     (centiseconds), and `state.full_lang_id_from_state() -> i32`.
//!   * `whisper_rs::get_lang_str(id: i32) -> Option<&'static str>`.

use std::path::{Path, PathBuf};

use whisper_rs::{
    FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState,
};

use crate::asr::{is_safe_asr_audio, AsrBackend, AsrResult, BackendInit};
use crate::errors::CoreError;
use crate::types::{Acceleration, ModelSpec};

/// whisper.cpp backend: an owned context plus a reusable decoding state.
///
/// Audio is assumed to be mono f32 at 16 kHz, matching whisper.cpp's expected
/// input and the rest of the pipeline.
pub struct WhisperCppBackend {
    /// The loaded ggml model. Kept alive for the lifetime of the backend.
    ///
    /// Boxed so the `state` borrowing it can be stored alongside it in the same
    /// struct: the box gives the context a stable heap address, and we hand the
    /// state a `'static`-extended reference (sound because `ctx` outlives
    /// `state` and both are dropped together, `state` first by field order).
    _ctx: Box<WhisperContext>,
    /// Decoding state, reused across calls (each `full()` resets it).
    state: WhisperState,
    /// Thread count for decoding, taken from `BackendInit`.
    n_threads: i32,
}

impl WhisperCppBackend {
    /// Load the ggml model for the configured Whisper id.
    ///
    /// Resolves `<models_path>/<id>/ggml-<id>.bin` (the `model_manager` layout).
    /// Returns [`CoreError::ModelLoad`] if the file is missing or the context /
    /// state cannot be created. Errors for a non-Whisper [`ModelSpec`] so the
    /// dispatcher can fall through to another runtime.
    pub fn load(init: &BackendInit) -> Result<Self, CoreError> {
        let id = match &init.model {
            ModelSpec::Whisper { id } => id,
            ModelSpec::Parakeet { .. } => {
                return Err(CoreError::ModelLoad(
                    "whisper.cpp backend only handles the Whisper family".into(),
                ));
            }
        };

        let model_path = ggml_model_path(&init.models_path, id);
        if !model_path.is_file() {
            return Err(CoreError::ModelLoad(format!(
                "whisper.cpp model file not found: {} \
                 (expected ggml weights at <models_path>/{id}/ggml-{id}.bin)",
                model_path.display()
            )));
        }

        // Enable the Metal GPU path for Auto/CoreMl/Gpu; force CPU otherwise.
        // (On a build without the `metal` feature or on non-Apple targets the
        // crate ignores `use_gpu` and runs on CPU regardless, so this is safe.)
        let params = WhisperContextParameters {
            use_gpu: wants_gpu(init.acceleration),
            ..Default::default()
        };

        let ctx = WhisperContext::new_with_params(&model_path, params).map_err(|e| {
            CoreError::ModelLoad(format!("whisper.cpp load {}: {e}", model_path.display()))
        })?;
        let ctx = Box::new(ctx);

        // SAFETY: `state` borrows from `*ctx`. The box pins the context to a
        // stable address for the backend's lifetime, and `WhisperCppBackend`
        // drops `state` before `_ctx` (struct field order), so the borrow never
        // outlives the context.
        let ctx_ref: &'static WhisperContext = unsafe { &*(ctx.as_ref() as *const WhisperContext) };
        let state = ctx_ref
            .create_state()
            .map_err(|e| CoreError::ModelLoad(format!("whisper.cpp create_state: {e}")))?;

        Ok(Self {
            _ctx: ctx,
            state,
            n_threads: init.n_threads.max(1) as i32,
        })
    }

    /// Build the per-call decoding parameters, mirroring the legacy WebUI.
    fn full_params<'a>(&self, language: Option<&'a str>) -> FullParams<'a, 'a> {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(self.n_threads);
        // `Some(code)` forces the language; `None` => whisper auto-detection.
        params.set_language(language);
        // Each chunk is independent — don't carry decoder context across calls.
        params.set_no_context(true);
        params.set_suppress_blank(true);
        params.set_no_speech_thold(0.6);
        params.set_translate(false);
        // We only consume plain text; suppress all printing and timestamps.
        params.set_print_realtime(false);
        params.set_print_progress(false);
        params.set_print_timestamps(false);
        params.set_print_special(false);
        params.set_token_timestamps(false);
        params
    }
}

impl AsrBackend for WhisperCppBackend {
    fn transcribe_once(
        &mut self,
        audio_f32_16k: &[f32],
        language: Option<&str>,
    ) -> Result<AsrResult, CoreError> {
        // Keep the native input contract at the backend boundary as well as
        // in the pipeline.  whisper.cpp is a C++ runtime; malformed/very
        // short buffers must not cross this FFI boundary even when a direct
        // caller bypasses the normal chunking path.
        if !is_safe_asr_audio(audio_f32_16k) {
            return Ok(AsrResult::default());
        }
        let params = self.full_params(language);
        self.state
            .full(params, audio_f32_16k)
            .map_err(|e| CoreError::Backend(format!("whisper.cpp transcribe: {e}")))?;

        let n = self.state.full_n_segments();

        let mut parts: Vec<String> = Vec::new();
        let mut seg_end_cs: Option<i64> = None;
        for i in 0..n {
            let Some(seg) = self.state.get_segment(i) else {
                continue;
            };
            if let Ok(text) = seg.to_str() {
                let t = text.trim();
                if !t.is_empty() {
                    parts.push(t.to_string());
                }
            }
            // End timestamps are reported in centiseconds; keep the largest.
            let end = seg.end_timestamp();
            seg_end_cs = Some(seg_end_cs.map_or(end, |acc| acc.max(end)));
        }

        // Detected language: when the caller forced one, echo it back; otherwise
        // map whisper's auto-detected id to its short code (e.g. "ru", "en").
        let detected = match language {
            Some(code) => Some(code.to_string()),
            None => whisper_rs::get_lang_str(self.state.full_lang_id_from_state())
                .map(|s| s.to_string()),
        };

        Ok(AsrResult {
            text: parts.join(" "),
            language: detected,
            // centiseconds -> seconds, relative to the chunk start.
            seg_end_rel: seg_end_cs.map(|cs| cs as f32 / 100.0),
        })
    }

    /// Whisper runs the engine's auto/ru/en candidate sweep.
    fn supports_multi_candidate(&self) -> bool {
        true
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Resolve the ggml weights path for a Whisper `id`, mirroring exactly the
/// layout `model_manager` writes: `<models_path>/<id>/ggml-<id>.bin`.
fn ggml_model_path(models_path: &str, id: &str) -> PathBuf {
    Path::new(models_path)
        .join(id)
        .join(format!("ggml-{id}.bin"))
}

/// Whether to request the GPU (Metal) path for a given acceleration hint.
/// `Auto`/`CoreMl`/`Gpu` opt in; `Cpu` forces the CPU path.
fn wants_gpu(accel: Acceleration) -> bool {
    matches!(
        accel,
        Acceleration::Auto | Acceleration::CoreMl | Acceleration::Gpu
    )
}

// ---------------------------------------------------------------------------
// Tests (behavioural; NO real weights — those are absent in CI)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Acceleration, ModelSpec};

    /// Pipeline sample rate (mono f32 @ 16 kHz).
    const SAMPLE_RATE: u32 = 16_000;

    fn init(model: ModelSpec, models_path: &str, accel: Acceleration) -> BackendInit {
        BackendInit {
            model,
            models_path: models_path.to_string(),
            n_threads: 4,
            acceleration: accel,
        }
    }

    #[test]
    fn ggml_path_matches_model_manager_layout() {
        // Contract with model_manager: `<models_path>/<id>/ggml-<id>.bin`.
        let p = ggml_model_path("/models", "base-q5_1");
        assert!(
            p.ends_with("base-q5_1/ggml-base-q5_1.bin"),
            "got {}",
            p.display()
        );
    }

    #[test]
    fn missing_model_file_is_model_load_error() {
        let dir = tempfile::tempdir().unwrap();
        let init = init(
            ModelSpec::Whisper {
                id: "base-q5_1".into(),
            },
            dir.path().to_str().unwrap(),
            Acceleration::Cpu,
        );
        let err = match WhisperCppBackend::load(&init) {
            Err(e) => e,
            Ok(_) => panic!("expected load failure when weights are absent"),
        };
        assert!(matches!(err, CoreError::ModelLoad(_)), "got {err:?}");
        // Message should name the expected ggml path so the user can fix it.
        assert!(err.to_string().contains("ggml-base-q5_1.bin"), "msg: {err}");
    }

    #[test]
    fn parakeet_spec_is_rejected_by_this_backend() {
        let dir = tempfile::tempdir().unwrap();
        let init = init(
            ModelSpec::Parakeet {
                id: "parakeet-tdt-0.6b-v3-int8".into(),
            },
            dir.path().to_str().unwrap(),
            Acceleration::Auto,
        );
        // This backend only serves the Whisper family; Parakeet must error so
        // the dispatcher can fall through to sherpa/CoreML.
        assert!(matches!(
            WhisperCppBackend::load(&init),
            Err(CoreError::ModelLoad(_))
        ));
    }

    #[test]
    fn gpu_requested_for_auto_coreml_gpu_not_cpu() {
        assert!(wants_gpu(Acceleration::Auto));
        assert!(wants_gpu(Acceleration::CoreMl));
        assert!(wants_gpu(Acceleration::Gpu));
        assert!(!wants_gpu(Acceleration::Cpu));
    }

    #[test]
    fn native_input_contract_rejects_short_or_nonfinite_audio() {
        assert!(!is_safe_asr_audio(&vec![
            0.1;
            crate::asr::MIN_ASR_AUDIO_SAMPLES
                - 1
        ]));
        assert!(is_safe_asr_audio(&vec![
            0.1;
            crate::asr::MIN_ASR_AUDIO_SAMPLES
        ]));

        let mut non_finite = vec![0.1; crate::asr::MIN_ASR_AUDIO_SAMPLES];
        non_finite[0] = f32::INFINITY;
        assert!(!is_safe_asr_audio(&non_finite));
    }

    /// Real-weights smoke test. Ignored: CI has no ggml `.bin` (they are large
    /// and downloaded on-device). Run on a machine with the model installed:
    /// `cargo test --features whispercpp -- --ignored loads_and_transcribes`.
    #[test]
    #[ignore = "requires a real ggml whisper model on disk (absent in CI)"]
    fn loads_and_transcribes() {
        let models_path = std::env::var("TC_MODELS_PATH")
            .expect("set TC_MODELS_PATH to a dir containing <id>/ggml-<id>.bin");
        let id = std::env::var("TC_WHISPER_ID").unwrap_or_else(|_| "base-q5_1".into());
        let init = init(ModelSpec::Whisper { id }, &models_path, Acceleration::Auto);
        let mut be = WhisperCppBackend::load(&init).expect("load real model");
        assert!(be.supports_multi_candidate());
        // 1s of silence — should run end-to-end without error.
        let audio = vec![0.0f32; SAMPLE_RATE as usize];
        let res = be.transcribe_once(&audio, Some("en")).expect("transcribe");
        assert_eq!(res.language.as_deref(), Some("en"));
    }
}
