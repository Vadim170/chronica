//! Voice activity detection. Drives interval cutting (not text output).
//!
//! Contract: `is_speech` is called once per fixed 30ms / 480-sample frame at
//! 16kHz. The cross-platform target is Silero (bundled with sherpa); when the
//! ML runtime is absent we fall back to an energy/RMS detector that mirrors
//! the legacy RMS safety net.

use crate::types::VadConfig;

/// Frame length the pipeline feeds the VAD. 30ms at 16kHz.
pub const FRAME_MS: u32 = 30;
pub const FRAME_SAMPLES: usize = 16_000 * FRAME_MS as usize / 1000; // 480

/// A per-channel VAD instance.
pub trait Vad: Send {
    /// Returns true when the 30ms frame is considered speech.
    fn is_speech(&mut self, frame_i16: &[i16]) -> bool;

    /// Горячее обновление порогов во время записи (по умолчанию — no-op).
    ///
    /// `silero` — порог вероятности речи Silero (0..1), `rms` — порог RMS
    /// «страховочной сетки». DSP-поток зовёт это на каждом тике, перечитывая
    /// значения из общего `RuntimeParams`, поэтому реализация обязана быть
    /// дешёвой. `RmsVad` обновляет свой RMS-порог; `SileroVad` — оба.
    fn set_threshold(&mut self, silero: f32, rms: f32) {
        let _ = (silero, rms);
    }
}

/// Normalized RMS of an i16 frame (0..~1).
pub fn frame_rms(frame_i16: &[i16]) -> f32 {
    if frame_i16.is_empty() {
        return 0.0;
    }
    let sum_sq: f64 = frame_i16
        .iter()
        .map(|&s| {
            let x = s as f64 / 32768.0;
            x * x
        })
        .sum();
    (sum_sq / frame_i16.len() as f64).sqrt() as f32
}

/// Energy-only VAD used when no ML VAD is compiled in. Treats a frame as
/// speech when its normalized RMS clears `rms_fallback`.
pub struct RmsVad {
    threshold: f32,
}

impl RmsVad {
    pub fn new(cfg: &VadConfig) -> Self {
        Self {
            threshold: cfg.rms_fallback,
        }
    }
}

impl Vad for RmsVad {
    fn is_speech(&mut self, frame_i16: &[i16]) -> bool {
        frame_rms(frame_i16) >= self.threshold
    }

    /// RMS-детектор использует только порог `rms`; `silero` игнорируется.
    fn set_threshold(&mut self, _silero: f32, rms: f32) {
        self.threshold = rms;
    }
}

/// Идентификатор записи Silero в реестре моделей и имя файла на диске.
/// Путь по конвенции: `<models_path>/silero-vad/silero_vad.onnx`.
pub const SILERO_VAD_DIR: &str = "silero-vad";
pub const SILERO_VAD_FILE: &str = "silero_vad.onnx";

/// Переменная окружения-override пути к модели Silero. Только для разработки:
/// продакшен берёт модель из каталога моделей по конвенции.
const SILERO_ENV_OVERRIDE: &str = "TC_SILERO_VAD";

/// Штатный путь к весам Silero внутри каталога моделей.
pub fn silero_model_path(models_path: &str) -> std::path::PathBuf {
    std::path::Path::new(models_path)
        .join(SILERO_VAD_DIR)
        .join(SILERO_VAD_FILE)
}

/// Выбранный детектор и (при откате) причина, которую нужно показать один раз.
pub struct VadChoice {
    pub vad: Box<dyn Vad>,
    /// Заполнено, если пришлось откатиться на простой RMS-детектор.
    /// Пайплайн эмитит ОДНО событие на сессию, а не по одному на канал.
    pub fallback_warning: Option<String>,
}

/// Build the best available VAD for this build/config.
///
/// Модель Silero берётся из каталога моделей (`<models_path>/silero-vad/
/// silero_vad.onnx`), а не из переменной окружения — раньше её не ставил никто,
/// поэтому в релизе всегда работал RMS и слайдер «порог речи» ничего не менял.
/// `TC_SILERO_VAD` остаётся dev-override. Если файла нет или загрузка не
/// удалась — возвращается RMS + текст предупреждения.
pub fn make_vad(cfg: &VadConfig, models_path: &str) -> VadChoice {
    let path = match std::env::var(SILERO_ENV_OVERRIDE) {
        Ok(p) if !p.trim().is_empty() => std::path::PathBuf::from(p),
        _ => silero_model_path(models_path),
    };
    if !path.is_file() {
        return VadChoice {
            vad: Box::new(RmsVad::new(cfg)),
            fallback_warning: Some(format!(
                "Silero VAD не найден ({}), используется простой детектор по громкости: \
                 границы речи и порог «речь/тишина» будут грубее",
                path.display()
            )),
        };
    }
    #[cfg(feature = "sherpa")]
    {
        match crate::vad_silero::SileroVad::new(cfg, &path.to_string_lossy()) {
            Ok(v) => VadChoice {
                vad: Box::new(v),
                fallback_warning: None,
            },
            Err(e) => VadChoice {
                vad: Box::new(RmsVad::new(cfg)),
                fallback_warning: Some(format!(
                    "Silero VAD не загрузился ({e}), используется простой детектор по громкости"
                )),
            },
        }
    }
    // Сборка без ML-рантайма (тесты/mock): файл на месте, но использовать его
    // нечем — работаем на RMS молча, это свойство сборки, а не установки.
    #[cfg(not(feature = "sherpa"))]
    VadChoice {
        vad: Box::new(RmsVad::new(cfg)),
        fallback_warning: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_is_not_speech() {
        let cfg = VadConfig::default();
        let mut v = RmsVad::new(&cfg);
        assert!(!v.is_speech(&vec![0i16; FRAME_SAMPLES]));
    }

    #[test]
    fn loud_frame_is_speech() {
        let cfg = VadConfig::default();
        let mut v = RmsVad::new(&cfg);
        let loud = vec![8000i16; FRAME_SAMPLES];
        assert!(v.is_speech(&loud));
    }

    /// Детектор без модели обязан остаться рабочим RMS-детектором и честно
    /// сказать, почему: молчаливый откат — это ровно та ошибка, из-за которой
    /// «порог речи» в UI ни на что не влиял.
    #[test]
    fn missing_silero_model_falls_back_to_rms_with_one_warning() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = VadConfig::default();

        let mut choice = make_vad(&cfg, dir.path().to_str().unwrap());

        let warning = choice
            .fallback_warning
            .as_deref()
            .expect("отсутствие модели должно быть видно пользователю");
        assert!(warning.contains("Silero VAD"), "текст: {warning}");
        // Откат обязан работать: громкий кадр — речь, тишина — не речь.
        assert!(choice.vad.is_speech(&vec![8000i16; FRAME_SAMPLES]));
        assert!(!choice.vad.is_speech(&vec![0i16; FRAME_SAMPLES]));
    }

    /// Каталог моделей есть, но файла VAD в нём нет (частый случай: модель ASR
    /// скачана давно, до появления записи silero-vad в реестре).
    #[test]
    fn models_dir_without_vad_file_still_yields_working_detector() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(SILERO_VAD_DIR)).unwrap();
        let cfg = VadConfig::default();

        let mut choice = make_vad(&cfg, dir.path().to_str().unwrap());

        assert!(choice.fallback_warning.is_some());
        assert!(choice.vad.is_speech(&vec![8000i16; FRAME_SAMPLES]));
    }

    #[test]
    fn silero_path_follows_registry_convention() {
        let p = silero_model_path("/models");
        assert!(p.ends_with("silero-vad/silero_vad.onnx"), "{}", p.display());
    }

    /// Реальная загрузка Silero: требует весов на диске и ML-рантайма.
    #[cfg(feature = "sherpa")]
    #[test]
    #[ignore = "нужны реальные веса silero_vad.onnx в каталоге моделей"]
    fn silero_is_used_when_model_is_installed() {
        let models = std::env::var("TRANSCRIBER_MODELS_PATH").unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap_or_default();
            format!("{home}/Library/Application Support/Transcriber/Models")
        });
        assert!(
            silero_model_path(&models).is_file(),
            "нет {} — скачайте любую ASR-модель (VAD докачивается вместе с ней)",
            silero_model_path(&models).display()
        );

        let mut choice = make_vad(&VadConfig::default(), &models);
        assert!(
            choice.fallback_warning.is_none(),
            "с установленной моделью отката быть не должно: {:?}",
            choice.fallback_warning
        );
        // Громкая речь остаётся речью и на Silero (RMS-страховка тоже даёт true).
        assert!(choice.vad.is_speech(&vec![8000i16; FRAME_SAMPLES]));
    }

    #[test]
    fn set_threshold_flips_verdict_on_borderline_frame() {
        // Кадр с известным RMS: при amplitude A нормализованный RMS = A/32768.
        // Возьмём A=1000 -> rms ≈ 0.0305.
        let cfg = VadConfig::default();
        let mut v = RmsVad::new(&cfg);
        let frame = vec![1000i16; FRAME_SAMPLES];
        let rms = frame_rms(&frame);
        assert!(rms > 0.0);

        // Горячо ставим порог ВЫШЕ rms кадра -> теперь это «тишина».
        v.set_threshold(0.5, rms + 0.01);
        assert!(
            !v.is_speech(&frame),
            "frame below new threshold must be silence"
        );

        // Опускаем порог НИЖЕ rms кадра -> снова «речь».
        v.set_threshold(0.5, rms - 0.005);
        assert!(
            v.is_speech(&frame),
            "frame above new threshold must be speech"
        );
    }
}
