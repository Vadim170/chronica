//! Default config and validation. No host/port/password legacy — those were
//! web-server concerns and are dropped.

use crate::errors::CoreError;
use crate::types::*;

/// Hard bounds (product requirements):
/// - intervals are at least 10s (нижний предел регулируемого минимума; дефолт 30с),
/// - and never longer than ~5 min ("no chunks over 5 min, regulable").
pub const MIN_INTERVAL_FLOOR_S: u32 = 10;
pub const MAX_INTERVAL_CEIL_S: u32 = 300;
pub const SILENCE_CUT_MIN_MS: u32 = 200;
pub const SILENCE_CUT_MAX_MS: u32 = 10_000;

/// Нижняя/верхняя границы кольца сырых сэмплов на канал (16кГц моно).
/// Верхняя граница = 40с аудио (~1.3 МБ/канал) — потолок против опечатки в
/// конфиге, а не рабочее значение.
pub const AUDIO_QUEUE_MIN: u32 = 64;
pub const AUDIO_QUEUE_MAX: u32 = 640_000;

/// Потолок срока хранения истории (≈10 лет). Ограничения снизу нет: `0`
/// означает «хранить всегда» и является дефолтом.
pub const RETENTION_DAYS_MAX: u32 = 3650;

/// Default whisper fallback model name (ggml/onnx). Multilingual.
pub const DEFAULT_WHISPER_ID: &str = "large-v3-turbo-q5_0";
/// Default (and recommended) production model: multilingual Parakeet, sherpa.
pub const DEFAULT_PARAKEET_ID: &str = "parakeet-tdt-0.6b-v3-int8";

pub fn default_config(
    storage_path: impl Into<String>,
    models_path: impl Into<String>,
) -> CoreConfig {
    CoreConfig {
        model: ModelSpec::Parakeet {
            id: DEFAULT_PARAKEET_ID.to_string(),
        },
        language: LanguageMode::Auto,
        // CPU/XNNPACK держит одну резидентную копию модели; CoreML-провайдер
        // дублирует модель в памяти и копит autoreleased ObjC-объекты на
        // не-Cocoa ASR-потоке (утечка).
        acceleration: Acceleration::Cpu,
        min_interval_s: 30,
        max_interval_s: 300,
        silence_cut_ms: 2000,
        vad: VadConfig::default(),
        n_threads: 4,
        // Интервалы крупные и не копятся; маленькая очередь ограничивает
        // worst-case объём аудио в ожидании транскрипции.
        bg_queue_size: 4,
        // ~10с аудио на канал при 16кГц (~320 КБ/канал). Кольцо обязано быть
        // ГЛУБЖЕ, чем сторожевой таймер DSP (`DSP_STALL_TIMEOUT`, 3с): иначе к
        // моменту сигнала о стале сэмплы уже потеряны молча.
        audio_queue_size: 160_000,
        storage_path: storage_path.into(),
        models_path: models_path.into(),
        api: ApiConfig::default(),
        // Ничего не удаляем, пока пользователь явно не задал срок хранения:
        // журнал работы — это его данные, молчаливая потеря недопустима.
        retention_days: 0,
    }
}

/// Clamp + sanity-check. Returns a corrected config or a descriptive error.
pub fn validate(mut c: CoreConfig) -> Result<CoreConfig, CoreError> {
    if c.storage_path.trim().is_empty() {
        return Err(CoreError::Config("storage_path is empty".into()));
    }
    if c.models_path.trim().is_empty() {
        return Err(CoreError::Config("models_path is empty".into()));
    }

    c.min_interval_s = c.min_interval_s.max(MIN_INTERVAL_FLOOR_S);
    c.max_interval_s = c.max_interval_s.min(MAX_INTERVAL_CEIL_S);
    if c.max_interval_s <= c.min_interval_s {
        // Keep at least a 1s window between min and the hard cap.
        c.max_interval_s = (c.min_interval_s + 1).min(MAX_INTERVAL_CEIL_S);
        if c.max_interval_s <= c.min_interval_s {
            return Err(CoreError::Config(
                "min_interval_s must be below the 300s ceiling".into(),
            ));
        }
    }

    c.silence_cut_ms = c
        .silence_cut_ms
        .clamp(SILENCE_CUT_MIN_MS, SILENCE_CUT_MAX_MS);
    c.n_threads = c.n_threads.clamp(1, 16);
    c.bg_queue_size = c.bg_queue_size.clamp(4, 1024);
    c.audio_queue_size = c.audio_queue_size.clamp(AUDIO_QUEUE_MIN, AUDIO_QUEUE_MAX);
    // Снизу не ограничиваем: 0 — легальное «хранить всегда». Сверху — потолок
    // от опечатки; 3650 суток и «всегда» на практике неотличимы.
    c.retention_days = c.retention_days.min(RETENTION_DAYS_MAX);

    if !(0.0..=1.0).contains(&c.vad.silero_threshold) {
        return Err(CoreError::Config(
            "vad.silero_threshold must be 0..1".into(),
        ));
    }
    if !(0.0..=1.0).contains(&c.vad.rms_fallback) {
        return Err(CoreError::Config("vad.rms_fallback must be 0..1".into()));
    }

    if let LanguageMode::Candidates { codes } = &c.language {
        if codes.is_empty() {
            return Err(CoreError::Config("language candidates is empty".into()));
        }
    }
    Ok(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_valid() {
        let c = default_config("/tmp/store", "/tmp/models");
        let v = validate(c).unwrap();
        assert_eq!(v.min_interval_s, 30);
        assert_eq!(v.max_interval_s, 300);
    }

    #[test]
    fn default_audio_ring_survives_validation_and_outlasts_dsp_stall_timeout() {
        let v = validate(default_config("/tmp/store", "/tmp/models")).unwrap();
        // Валидация не должна «съедать» дефолт: раньше потолок 65_536 молча
        // урезал кольцо до ~4с.
        assert_eq!(v.audio_queue_size, 160_000);
        let ring_seconds = v.audio_queue_size as f64 / 16_000.0;
        assert!(
            ring_seconds > 3.0,
            "кольцо ({ring_seconds}с) должно переживать сторожевой таймер DSP (3с)"
        );
    }

    #[test]
    fn clamps_out_of_range_intervals() {
        let mut c = default_config("/tmp/s", "/tmp/m");
        c.min_interval_s = 5; // below floor (10)
        c.max_interval_s = 9000; // above ceil
        let v = validate(c).unwrap();
        assert_eq!(v.min_interval_s, 10);
        assert_eq!(v.max_interval_s, 300);
    }

    #[test]
    fn retention_defaults_to_keep_forever_and_is_capped() {
        let c = default_config("/tmp/s", "/tmp/m");
        assert_eq!(c.retention_days, 0, "по умолчанию история не удаляется");

        let mut c = default_config("/tmp/s", "/tmp/m");
        c.retention_days = 30;
        assert_eq!(validate(c).unwrap().retention_days, 30);

        let mut c = default_config("/tmp/s", "/tmp/m");
        c.retention_days = 1_000_000;
        assert_eq!(
            validate(c).unwrap().retention_days,
            RETENTION_DAYS_MAX,
            "абсурдный срок хранения подрезается потолком"
        );
    }

    #[test]
    fn rejects_empty_storage() {
        let mut c = default_config("/tmp/s", "/tmp/m");
        c.storage_path = "".into();
        assert!(validate(c).is_err());
    }
}
