//! Cross-platform ASR backend on top of sherpa-onnx (ONNX Runtime) via the
//! `sherpa-rs` crate (~0.6). Two model families behind one `AsrBackend`:
//!
//! - Parakeet → `sherpa_rs::transducer` (NeMo TDT transducer): encoder /
//!   decoder / joiner / tokens, `model_type = "nemo_transducer"`.
//! - Whisper  → `sherpa_rs::whisper`: encoder / decoder / tokens.
//!
//! API verified against docs.rs/sherpa-rs 0.6.8 and the crate's `examples/`:
//!   * `TransducerConfig { encoder, decoder, joiner, tokens, num_threads: i32,
//!     sample_rate: i32, feature_dim: i32, model_type, provider: Option<String>,
//!     debug, .. }`; `TransducerRecognizer::new(cfg) -> Result<Self>`;
//!     `transcribe(&mut self, sample_rate: u32, samples: &[f32]) -> String`.
//!   * `WhisperConfig { encoder, decoder, tokens, language, bpe_vocab:
//!     Option<String>, provider: Option<String>, num_threads: Option<i32>,
//!     debug, .. }`; `WhisperRecognizer::new(cfg) -> Result<Self>`;
//!     `transcribe(&mut self, sample_rate: u32, samples: &[f32]) ->
//!     WhisperRecognizerResult { text, .. }`.
//!   * `get_default_provider() -> String`.
//!
//! Model file layout mirrors `model_manager::local_files`:
//!   * parakeet: `<models_path>/<id>/{encoder,decoder,joiner}.int8.onnx` +
//!     `tokens.txt`.
//!   * whisper: see the DIVERGENCE note below.

use std::path::{Path, PathBuf};

use crate::asr::{is_safe_asr_audio, AsrBackend, AsrResult, BackendInit};
use crate::errors::CoreError;
use crate::types::{Acceleration, ModelSpec};

/// Audio sample rate the whole pipeline runs at.
const SAMPLE_RATE: u32 = 16_000;
/// Mel feature dimension used by the sherpa NeMo/zipformer transducer front-end.
const FEATURE_DIM: i32 = 80;

/// Either ASR family, each owning a sherpa recognizer.
enum Recognizer {
    Transducer(sherpa_rs::transducer::TransducerRecognizer),
    Whisper(sherpa_rs::whisper::WhisperRecognizer),
}

pub struct SherpaBackend {
    inner: Recognizer,
    multi_candidate: bool,
}

impl SherpaBackend {
    /// Load the recognizer for the configured model. File paths are resolved
    /// from `<models_path>/<id>/...` so the layout matches `model_manager`.
    pub fn load(init: &BackendInit) -> Result<Self, CoreError> {
        let provider = pick_provider(init.acceleration);
        // sherpa wants a sane positive thread count; never 0.
        let num_threads = init.n_threads.max(1) as i32;

        match &init.model {
            ModelSpec::Parakeet { id } => {
                let dir = model_dir(&init.models_path, id);
                let encoder = require_file(&dir, "encoder.int8.onnx")?;
                let decoder = require_file(&dir, "decoder.int8.onnx")?;
                let joiner = require_file(&dir, "joiner.int8.onnx")?;
                let tokens = require_file(&dir, "tokens.txt")?;

                let config = sherpa_rs::transducer::TransducerConfig {
                    encoder,
                    decoder,
                    joiner,
                    tokens,
                    num_threads,
                    sample_rate: SAMPLE_RATE as i32,
                    feature_dim: FEATURE_DIM,
                    model_type: "nemo_transducer".to_string(),
                    provider,
                    debug: false,
                    ..Default::default()
                };
                let rec = sherpa_rs::transducer::TransducerRecognizer::new(config)
                    .map_err(|e| CoreError::ModelLoad(format!("sherpa transducer: {e}")))?;
                Ok(Self {
                    inner: Recognizer::Transducer(rec),
                    multi_candidate: false,
                })
            }
            ModelSpec::Whisper { id } => {
                let dir = model_dir(&init.models_path, id);
                // DIVERGENCE: `model_manager` downloads whisper.cpp ggml weights
                // (`ggml-<id>.bin`), but sherpa-onnx whisper requires ONNX
                // encoder/decoder + a tokens file. We resolve the ONNX layout
                // sherpa-whisper-onnx ships with (k2-fsa release tarballs):
                // `<id>-encoder.onnx`, `<id>-decoder.onnx`, `<id>-tokens.txt`,
                // with `encoder.onnx`/`decoder.onnx`/`tokens.txt` as fallbacks.
                // Running whisper through sherpa therefore needs ONNX exports to
                // be present; the ggml `.bin` is for a whisper.cpp backend, not
                // this one. (model_manager is owned elsewhere and not edited.)
                let encoder = resolve_whisper(&dir, id, "encoder")?;
                let decoder = resolve_whisper(&dir, id, "decoder")?;
                let tokens = resolve_whisper_tokens(&dir, id)?;

                let config = sherpa_rs::whisper::WhisperConfig {
                    encoder,
                    decoder,
                    tokens,
                    // Empty => sherpa whisper auto-detects the language.
                    language: String::new(),
                    bpe_vocab: None,
                    provider,
                    num_threads: Some(num_threads),
                    debug: false,
                    ..Default::default()
                };
                let rec = sherpa_rs::whisper::WhisperRecognizer::new(config)
                    .map_err(|e| CoreError::ModelLoad(format!("sherpa whisper: {e}")))?;
                Ok(Self {
                    inner: Recognizer::Whisper(rec),
                    multi_candidate: true,
                })
            }
        }
    }
}

impl AsrBackend for SherpaBackend {
    fn transcribe_once(
        &mut self,
        audio_f32_16k: &[f32],
        language: Option<&str>,
    ) -> Result<AsrResult, CoreError> {
        match &mut self.inner {
            Recognizer::Transducer(rec) => {
                // Defense in depth for callers that bypass the pipeline (for
                // example, a future FFI/backend integration).  sherpa-rs
                // exposes the native transcribe call as an infallible Rust
                // method; passing a short/invalid sequence can make ONNX
                // Runtime construct a zero-length Conv input and abort the
                // process.  Rust's `catch_unwind` cannot catch that foreign
                // exception, so reject the buffer immediately before crossing
                // the C++ boundary.
                if !is_safe_asr_audio(audio_f32_16k) {
                    return Ok(AsrResult::default());
                }
                // Parakeet is multilingual / single-pass: `language` is ignored.
                let text = rec.transcribe(SAMPLE_RATE, audio_f32_16k);
                Ok(AsrResult {
                    text: text.trim().to_string(),
                    language: None,
                    seg_end_rel: None,
                })
            }
            Recognizer::Whisper(rec) => {
                // Keep the same guard immediately before Whisper's native
                // call; the shared floor protects all sherpa model families.
                if !is_safe_asr_audio(audio_f32_16k) {
                    return Ok(AsrResult::default());
                }
                // sherpa's WhisperRecognizer has no per-call language override:
                // the language is fixed at construction. The engine drives the
                // candidate sweep by scoring outputs, so we just transcribe and
                // echo the requested language code back when one was given.
                let result = rec.transcribe(SAMPLE_RATE, audio_f32_16k);
                Ok(AsrResult {
                    text: result.text.trim().to_string(),
                    language: language.map(|s| s.to_string()),
                    seg_end_rel: None,
                })
            }
        }
    }

    fn supports_multi_candidate(&self) -> bool {
        self.multi_candidate
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// `<models_path>/<id>` — same layout `model_manager` writes into.
fn model_dir(models_path: &str, id: &str) -> PathBuf {
    Path::new(models_path).join(id)
}

/// Require a file to exist under `dir`, returning its absolute path as a String.
fn require_file(dir: &Path, rel: &str) -> Result<String, CoreError> {
    let p = dir.join(rel);
    if p.is_file() {
        Ok(p.to_string_lossy().into_owned())
    } else {
        Err(CoreError::ModelLoad(format!(
            "missing model file: {}",
            p.display()
        )))
    }
}

/// Resolve a sherpa-whisper ONNX component (encoder/decoder), trying the common
/// release naming `<id>-<component>.onnx` then a bare `<component>.onnx`.
fn resolve_whisper(dir: &Path, id: &str, component: &str) -> Result<String, CoreError> {
    let candidates = [
        format!("{id}-{component}.onnx"),
        format!("{id}-{component}.int8.onnx"),
        format!("{component}.onnx"),
        format!("{component}.int8.onnx"),
    ];
    first_existing(dir, &candidates).ok_or_else(|| {
        CoreError::ModelLoad(format!(
            "sherpa whisper needs ONNX {component} for '{id}' (looked for {:?} in {}); \
             note: model_manager ships ggml '.bin' weights for whisper.cpp, not sherpa ONNX",
            candidates,
            dir.display()
        ))
    })
}

/// Resolve the sherpa-whisper tokens file.
fn resolve_whisper_tokens(dir: &Path, id: &str) -> Result<String, CoreError> {
    let candidates = [format!("{id}-tokens.txt"), "tokens.txt".to_string()];
    first_existing(dir, &candidates).ok_or_else(|| {
        CoreError::ModelLoad(format!(
            "sherpa whisper needs a tokens file for '{id}' (looked for {:?} in {})",
            candidates,
            dir.display()
        ))
    })
}

/// First of `names` that exists under `dir`, as an absolute path string.
fn first_existing(dir: &Path, names: &[String]) -> Option<String> {
    names.iter().find_map(|n| {
        let p = dir.join(n);
        p.is_file().then(|| p.to_string_lossy().into_owned())
    })
}

/// Map our acceleration hint to a sherpa-onnx ONNX Runtime provider string.
///
/// Low resource usage is the priority, so `Auto`/`CoreMl` prefer the platform's
/// cheap accelerator (CoreML on Apple, NNAPI on Android, else CPU/XNNPACK) via
/// `get_default_provider()`; `Gpu` asks for the CUDA provider; `Cpu` forces CPU.
fn pick_provider(accel: Acceleration) -> Option<String> {
    match accel {
        Acceleration::Cpu => Some("cpu".to_string()),
        Acceleration::Gpu => Some("cuda".to_string()),
        // `get_default_provider()` returns "coreml" on Apple when built with
        // CoreML support, otherwise "cpu". Honour whatever the runtime offers.
        Acceleration::Auto | Acceleration::CoreMl => Some(sherpa_rs::get_default_provider()),
    }
}

#[cfg(test)]
mod input_tests {
    use super::*;
    use crate::asr::MIN_ASR_AUDIO_SAMPLES;

    #[test]
    fn native_input_floor_accepts_exact_boundary_only_for_finite_audio() {
        assert!(!is_safe_asr_audio(&vec![0.1; MIN_ASR_AUDIO_SAMPLES - 1]));
        assert!(is_safe_asr_audio(&vec![0.1; MIN_ASR_AUDIO_SAMPLES]));

        let mut non_finite = vec![0.1; MIN_ASR_AUDIO_SAMPLES];
        non_finite[MIN_ASR_AUDIO_SAMPLES / 2] = f32::NAN;
        assert!(!is_safe_asr_audio(&non_finite));
    }
}

// ---------------------------------------------------------------------------
// Тесты расхода памяти (тяжёлые, требуют модель на диске; `#[ignore]`).
// ---------------------------------------------------------------------------
//
// Замеряют РЕАЛЬНЫЙ резидентный набор (RSS) процесса вокруг загрузки модели и по
// итерациям инференса. Цель — ответить на два вопроса:
//   1. Где «пол» расхода (модель + рантайм ORT) сразу после загрузки.
//   2. Это ПЛАТО (арена ORT удерживает пик активаций) или УТЕЧКА (RSS растёт
//      с каждым инференсом)?
//
// Запуск (пример):
//   cargo test --features sherpa memory_footprint -- --ignored --nocapture
//   TC_MEM_CHUNK_S=10 cargo test --features sherpa memory_footprint -- --ignored --nocapture
//   TC_MEM_THREADS=2 cargo test --features sherpa memory_footprint -- --ignored --nocapture
#[cfg(test)]
mod memory_tests {
    use super::*;
    use crate::asr::{AsrBackend, BackendInit, MIN_ASR_AUDIO_SAMPLES};
    use crate::types::{Acceleration, ModelSpec};

    fn models_path() -> String {
        if let Ok(p) = std::env::var("TRANSCRIBER_MODELS_PATH") {
            return p;
        }
        let home = std::env::var("HOME").unwrap_or_default();
        format!("{home}/Library/Application Support/Transcriber/Models")
    }

    /// Синтетический ненулевой звук (синус), чтобы инференс реально считал
    /// (нулевые буферы пайплайн пропускает).
    fn sine(samples: usize) -> Vec<f32> {
        let (f, sr) = (220.0_f32, 16_000.0_f32);
        (0..samples)
            .map(|n| 0.1 * (2.0 * std::f32::consts::PI * f * (n as f32) / sr).sin())
            .collect()
    }

    fn rss_mb() -> f64 {
        crate::metrics::process_rss_bytes().unwrap_or(0) as f64 / 1_048_576.0
    }

    /// Число потоков ORT для замера; переопределяется `TC_MEM_THREADS`,
    /// чтобы прогнать footprint при 1/2/4 без пересборки.
    fn mem_threads() -> u32 {
        std::env::var("TC_MEM_THREADS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(4)
    }

    fn parakeet_init(models_path: String) -> BackendInit {
        BackendInit {
            model: ModelSpec::Parakeet {
                id: "parakeet-tdt-0.6b-v3-int8".into(),
            },
            models_path,
            n_threads: mem_threads(),
            acceleration: Acceleration::Cpu,
        }
    }

    #[test]
    #[ignore = "требует реальные веса Parakeet на диске; запускается вручную"]
    fn short_nonzero_tail_is_rejected_before_native_inference() {
        let mp = models_path();
        let dir = std::path::Path::new(&mp).join("parakeet-tdt-0.6b-v3-int8");
        assert!(
            dir.join("encoder.int8.onnx").is_file(),
            "model not found at {} — set TRANSCRIBER_MODELS_PATH",
            dir.display()
        );

        let mut backend = SherpaBackend::load(&parakeet_init(mp)).expect("load model");
        let short = sine(MIN_ASR_AUDIO_SAMPLES - 1);
        assert!(short.iter().any(|&sample| sample != 0.0));

        // This is intentionally a real backend instance: the shared guard in
        // `transcribe_once` must return before sherpa/ORT sees the short tail.
        let result = backend
            .transcribe_once(&short, None)
            .expect("short tail should be a safe no-op");
        assert!(result.text.is_empty());
    }

    #[test]
    #[ignore = "heavy; needs Parakeet model on disk. run: cargo test --features sherpa memory_footprint -- --ignored --nocapture"]
    fn memory_footprint_parakeet() {
        let mp = models_path();
        let dir = std::path::Path::new(&mp).join("parakeet-tdt-0.6b-v3-int8");
        assert!(
            dir.join("encoder.int8.onnx").is_file(),
            "model not found at {} — set TRANSCRIBER_MODELS_PATH",
            dir.display()
        );

        let chunk_s: usize = std::env::var("TC_MEM_CHUNK_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(30);
        let iters: usize = std::env::var("TC_MEM_ITERS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(20);

        let init = parakeet_init(mp);

        let before_load = rss_mb();
        let mut backend = SherpaBackend::load(&init).expect("load model");
        let after_load = rss_mb();

        let audio = sine(chunk_s * 16_000);
        let mut peak = after_load;
        let mut warmup = after_load;
        // RTF считаем по итерациям ПОСЛЕ прогрева (первые прогоны включают
        // ленивую инициализацию арены/потоков ORT и завышают время).
        let mut timed_secs = 0.0_f64;
        let mut timed_iters = 0_usize;
        for i in 0..iters {
            let t0 = std::time::Instant::now();
            let _ = backend.transcribe_once(&audio, None).expect("transcribe");
            let elapsed = t0.elapsed().as_secs_f64();
            if i >= 2 {
                timed_secs += elapsed;
                timed_iters += 1;
            }
            let now = rss_mb();
            peak = peak.max(now);
            if i == 4 {
                warmup = now; // RSS после прогрева (арена уже выросла до пика)
            }
            if i % 5 == 0 || i + 1 == iters {
                eprintln!("iter {i:>2}: RSS {now:.0} MB (peak {peak:.0} MB)");
            }
        }
        let end = rss_mb();
        let growth = (end - warmup).max(0.0);

        let rtf = if timed_iters > 0 {
            timed_secs / (timed_iters as f64 * chunk_s as f64)
        } else {
            f64::NAN
        };

        eprintln!(
            "---- footprint: chunk={chunk_s}s, threads={}, provider=cpu ----",
            mem_threads()
        );
        eprintln!("RTF (после прогрева): {rtf:.3}");
        eprintln!("before load        : {before_load:.0} MB");
        eprintln!("after load (пол)   : {after_load:.0} MB  (веса модели + рантайм ORT)");
        eprintln!("peak               : {peak:.0} MB");
        eprintln!("end                : {end:.0} MB");
        eprintln!("growth (iter5→end) : {growth:.0} MB  (лик-индикатор)");

        // Лик-гард: после прогрева RSS не должен заметно расти. Если это арена ORT
        // (ожидаемо) — рост ≈ 0; устойчивый рост означает утечку.
        let max_growth_mb = 150.0;
        assert!(
            growth < max_growth_mb,
            "RSS вырос на {growth:.0} MB после прогрева (порог {max_growth_mb:.0} MB) — вероятна утечка"
        );
    }
}
