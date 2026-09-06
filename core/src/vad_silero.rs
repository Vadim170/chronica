//! Silero VAD via sherpa-onnx (`sherpa_rs::silero_vad`).
//!
//! The pipeline feeds fixed 30ms / 480-sample i16 frames (see `vad::Vad`).
//! Silero, however, runs on 512-sample float windows, so we convert each frame
//! to f32, append it to an internal buffer, and drain the buffer in 512-sample
//! windows through `accept_waveform` + `is_speech`. A frame is "speech" if the
//! latest VAD verdict is positive OR the frame clears the RMS safety net — the
//! same belt-and-braces policy the RMS fallback enforces on its own.
//!
//! Verified API (docs.rs/sherpa-rs 0.6.8, `examples/vad_silero.rs`):
//!   * `SileroVadConfig { model: String, threshold: f32, min_silence_duration:
//!     f32, min_speech_duration: f32, max_speech_duration: f32, window_size:
//!     i32, sample_rate: u32, provider: Option<String>, num_threads:
//!     Option<i32>, debug: bool }`.
//!   * `SileroVad::new(config: SileroVadConfig, buffer_size_in_seconds: f32) ->
//!     Result<Self>`.
//!   * `accept_waveform(&mut self, samples: Vec<f32>)`, `is_speech(&mut self)
//!     -> bool`.
//!
//! Model discovery: путь к весам передаёт `vad::make_vad` (штатно —
//! `<models_path>/silero-vad/silero_vad.onnx`, скачивается вместе с ASR-моделью).
//! Если файла нет или sherpa не смог его открыть, `new` возвращает `Err`, и
//! `make_vad` прозрачно откатывается на RMS-детектор с предупреждением.

use crate::errors::CoreError;
use crate::types::VadConfig;
use crate::vad::{frame_rms, Vad};
use std::time::{Duration, Instant};

/// Sherpa Silero VAD window length in samples (Silero v4/v5 at 16kHz).
const WINDOW_SIZE: usize = 512;
/// Internal speech buffer the recognizer keeps; generous so segments never drop.
const BUFFER_SECONDS: f32 = 30.0;
/// Минимальный интервал между пересозданиями нативного детектора при движении
/// слайдера порога: пересоздание грузит ONNX-модель, а DSP зовёт `set_threshold`
/// на каждом тике.
const THRESHOLD_REBUILD_DEBOUNCE: Duration = Duration::from_millis(500);

pub struct SileroVad {
    vad: sherpa_rs::silero_vad::SileroVad,
    /// f32 samples accumulated across frames, drained in WINDOW_SIZE chunks.
    pending: Vec<f32>,
    /// Last verdict from the most recently completed window.
    last_speech: bool,
    /// RMS safety net mirrored from `VadConfig::rms_fallback`. Меняется на лету.
    rms_fallback: f32,
    /// Путь к модели Silero — нужен для пересоздания детектора при горячей
    /// смене порога (sherpa не даёт менять threshold у существующего детектора).
    model_path: String,
    /// Текущий silero-порог; пересоздаём детектор только при реальном изменении.
    silero_threshold: f32,
    /// Момент последнего пересоздания детектора — дебаунс слайдера порога.
    last_rebuild: Instant,
}

impl SileroVad {
    /// Build the Silero VAD. Returns `Err` (triggering the RMS fallback) when
    /// the model file is missing or the runtime refuses to load it.
    pub fn new(cfg: &VadConfig, model_path: &str) -> Result<Self, CoreError> {
        if !std::path::Path::new(model_path).is_file() {
            return Err(CoreError::ModelLoad(format!(
                "Silero VAD model not found at {model_path}"
            )));
        }

        let vad = Self::build_detector(model_path, cfg.silero_threshold)?;

        Ok(Self {
            vad,
            pending: Vec::with_capacity(WINDOW_SIZE * 2),
            last_speech: false,
            rms_fallback: cfg.rms_fallback,
            model_path: model_path.to_string(),
            silero_threshold: cfg.silero_threshold,
            last_rebuild: Instant::now(),
        })
    }

    /// Создаёт нативный sherpa-детектор с заданным порогом.
    fn build_detector(
        model: &str,
        threshold: f32,
    ) -> Result<sherpa_rs::silero_vad::SileroVad, CoreError> {
        let config = sherpa_rs::silero_vad::SileroVadConfig {
            model: model.to_string(),
            threshold,
            window_size: WINDOW_SIZE as i32,
            sample_rate: 16_000,
            provider: Some(sherpa_rs::get_default_provider()),
            ..Default::default()
        };
        sherpa_rs::silero_vad::SileroVad::new(config, BUFFER_SECONDS)
            .map_err(|e| CoreError::ModelLoad(format!("silero vad: {e}")))
    }
}

impl Vad for SileroVad {
    fn is_speech(&mut self, frame_i16: &[i16]) -> bool {
        // Convert this 30ms frame to f32 and stage it.
        self.pending
            .extend(frame_i16.iter().map(|&s| s as f32 / 32768.0));

        // Drain complete 512-sample windows; remember the freshest verdict.
        while self.pending.len() >= WINDOW_SIZE {
            let window: Vec<f32> = self.pending.drain(..WINDOW_SIZE).collect();
            self.vad.accept_waveform(window);
            // Any error from the runtime surfaces as a panic in sherpa; guard
            // it so a bad frame degrades to "no speech" rather than crashing.
            self.last_speech =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.vad.is_speech()))
                    .unwrap_or(false);
        }

        // RMS safety net: keep frames Silero calls silence but that are loud.
        self.last_speech || frame_rms(frame_i16) >= self.rms_fallback
    }

    /// Горячее обновление порогов. RMS-сетка применяется мгновенно. Silero-порог
    /// зашит в нативный детектор при создании, поэтому при его изменении
    /// пересоздаём детектор (буфер `pending` сохраняем; внутреннее состояние
    /// окон сбрасывается — на длинной записи это незаметно). При сбое
    /// пересоздания оставляем прежний детектор и порог.
    ///
    /// Пересоздание — загрузка ONNX-модели, а метод зовётся из realtime-цикла
    /// DSP, поэтому оно происходит только при РЕАЛЬНОМ изменении порога и не
    /// чаще [`THRESHOLD_REBUILD_DEBOUNCE`]. Пропущенное во время дебаунса
    /// значение не теряется: порог остаётся отличным от текущего, и следующий
    /// же вызов после окна применит его.
    fn set_threshold(&mut self, silero: f32, rms: f32) {
        self.rms_fallback = rms;
        if (silero - self.silero_threshold).abs() <= f32::EPSILON {
            return;
        }
        if self.last_rebuild.elapsed() < THRESHOLD_REBUILD_DEBOUNCE {
            return;
        }
        self.last_rebuild = Instant::now();
        match Self::build_detector(&self.model_path, silero) {
            Ok(vad) => {
                self.vad = vad;
                self.silero_threshold = silero;
                self.last_speech = false;
            }
            Err(_) => { /* оставляем рабочий детектор со старым порогом */
            }
        }
    }
}
