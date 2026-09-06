//! Shared public data types for the transcriber core.
//!
//! These are the stable contracts that every module and the platform shells
//! (via UniFFI) code against. Keep signatures stable; implementations live in
//! the respective modules.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Which ASR family + concrete weights/files to run.
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum ModelSpec {
    /// Whisper (ggml/onnx). `id` is a known whisper model name (e.g.
    /// "large-v3-turbo-q5_0") or an absolute path. Multi-candidate language
    /// picking applies to this family.
    Whisper { id: String },
    /// Parakeet TDT (sherpa-onnx int8 by default). Multilingual incl. ru/en;
    /// no language-candidate sweep needed.
    Parakeet { id: String },
}

/// How the engine picks the spoken language.
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum LanguageMode {
    /// Single backend pass in auto-detect mode.
    Auto,
    /// Single pass forced to this ISO code ("ru", "en", ...).
    Fixed { code: String },
    /// Whisper-only: run several passes (e.g. auto/ru/en) and score the best.
    Candidates { codes: Vec<String> },
}

/// Hardware acceleration hint for the ASR backend. Low resource usage is the
/// priority; `Auto` picks the cheapest capable provider per platform.
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Acceleration {
    /// Pick best-but-cheap automatically (CoreML/ANE on Apple, NNAPI on
    /// Android, else CPU/XNNPACK).
    Auto,
    Cpu,
    /// Apple CoreML execution provider (uses ANE/GPU where available).
    CoreMl,
    /// Generic GPU provider where the runtime supports it.
    Gpu,
}

/// VAD configuration. Silence detection drives interval cutting.
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct VadConfig {
    /// Silero speech-probability threshold (0.0..1.0). Frames below count as
    /// silence (subject to the RMS safety net below).
    pub silero_threshold: f32,
    /// RMS safety net: a frame the VAD calls "silence" is still treated as
    /// speech if its normalized RMS >= this value. Ported default: 0.008.
    pub rms_fallback: f32,
}

impl Default for VadConfig {
    fn default() -> Self {
        Self {
            silero_threshold: 0.5,
            rms_fallback: 0.008,
        }
    }
}

/// Top-level engine configuration handed in by the platform shell.
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CoreConfig {
    pub model: ModelSpec,
    pub language: LanguageMode,
    pub acceleration: Acceleration,
    /// Minimum interval length before a silence gap may cut it. Regulable.
    /// Product requirement: chunks are at least this long (default 30s).
    pub min_interval_s: u32,
    /// Hard cap: force a cut at this elapsed time regardless of speech.
    /// Regulable. Product requirement: never exceed ~5 min (default 300s).
    pub max_interval_s: u32,
    /// Continuous silence (all channels) needed to cut between min and max.
    /// Regulable (default 2000ms). The cut lands in the middle of the gap so
    /// it falls between words.
    pub silence_cut_ms: u32,
    pub vad: VadConfig,
    /// ASR worker thread count. Keep low for low resource usage (default 4).
    pub n_threads: u32,
    /// Bounded internal queue of pending intervals awaiting transcription.
    pub bg_queue_size: u32,
    /// Per-channel audio ring-buffer capacity in frames.
    pub audio_queue_size: u32,
    /// Directory for the SQLite store and exports (platform-provided).
    pub storage_path: String,
    /// Directory where model files live (platform downloads into it).
    pub models_path: String,
    /// Optional local HTTP API (records-by-time). Off unless the user enables.
    pub api: ApiConfig,
    /// Срок хранения истории в сутках. `0` — хранить всегда (по умолчанию).
    ///
    /// При положительном значении ядро чистит базу (интервалы, тексты, события
    /// речи старше срока) при `start()` и далее раз в 24 часа, пока идёт
    /// сессия. Чистка выполняется в тикере, не в realtime-потоках.
    ///
    /// Поле аддитивное: у FFI-клиентов (Swift/Kotlin) есть значение по
    /// умолчанию, поэтому старый код, не знающий о нём, продолжает собираться.
    #[cfg_attr(feature = "ffi", uniffi(default = 0))]
    pub retention_days: u32,
}

impl CoreConfig {
    /// Validates and clamps the config to sane bounds. Returns the cleaned
    /// config or a descriptive error.
    pub fn validated(self) -> Result<CoreConfig, crate::CoreError> {
        crate::config::validate(self)
    }
}

/// Optional embedded HTTP API for retrieving records by time range.
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ApiConfig {
    /// When false the API server is never started.
    pub enabled: bool,
    pub host: String,
    pub port: u16,
    /// Optional bearer token; empty disables auth (loopback-only is assumed).
    pub token: String,
}

impl Default for ApiConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            host: "127.0.0.1".into(),
            port: 8765,
            token: String::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// Channels
// ---------------------------------------------------------------------------

/// A named audio channel. The engine works with N channels; macOS uses
/// "mic" and "remote" (system audio).
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChannelSpec {
    pub id: String,
    pub label: String,
}

// ---------------------------------------------------------------------------
// Records (persisted + returned to UI / API)
// ---------------------------------------------------------------------------

/// Transcribed text for one channel within an interval.
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ChannelText {
    pub channel_id: String,
    pub text: String,
    pub words: u32,
    pub language: String,
}

/// A committed interval (the persistence + query unit). Maps to one SQLite row
/// set; texts indexed by channel id.
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct IntervalRecord {
    pub id: i64,
    pub start_at: String, // ISO-8601 with tz
    pub end_at: String,
    pub duration_s: f64,
    pub channels: Vec<ChannelText>,
}

/// Lightweight overview item for history timelines (no full text).
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct IntervalOverviewItem {
    pub id: i64,
    pub start_at: String,
    pub end_at: String,
    pub duration_s: f64,
    pub total_words: u32,
}

/// Сессия записи: факт «здесь запись включили» и «здесь выключили».
///
/// Нужна единой ленте журнала: разделители между блоками рисуются по ФАКТУ
/// начала/конца сессии, а не по эвристике «пауза больше N секунд». Пустой
/// `ended_at` вместе с пустым `stop_reason` означает «сессия не закрыта
/// штатно» — процесс убили или он упал, то есть «здесь приложение закрылось».
///
/// Пустая строка вместо NULL — принятое в ядре соглашение FFI-типов
/// (`Option` в контрактах сознательно не используется).
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SessionRecord {
    pub id: i64,
    /// ISO-8601 с локальным смещением — когда запись включили.
    pub started_at: String,
    /// ISO-8601 с локальным смещением; пустая строка — сессия не закрыта.
    pub ended_at: String,
    /// `"user"` — остановил пользователь, `"error"` — авария (паника DSP,
    /// потеря ASR-воркера, watchdog, прерванная по дедлайну остановка);
    /// пустая строка — сессия не закрыта.
    pub stop_reason: String,
}

/// Voice-activity aggregation bucket (hourly or daily).
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ActivityBucket {
    pub ts: String,
    pub counts: Vec<ChannelCount>,
}

#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChannelCount {
    pub channel_id: String,
    pub count: u32,
}

#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ActivityKind {
    Hourly,
    Daily,
}

// ---------------------------------------------------------------------------
// Хранилище
// ---------------------------------------------------------------------------

/// Состояние локальной базы: сколько занимает, что в ней лежит, доступен ли
/// полнотекстовый индекс. Для экрана «Хранилище» и диагностики.
///
/// Пустая строка в `first_start_at`/`last_end_at` означает «истории нет»
/// (Option в FFI-контрактах ядра сознательно не используется).
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct StoreInfo {
    /// Полный путь к файлу базы.
    pub path: String,
    /// Версия схемы (`PRAGMA user_version`).
    pub schema_version: i64,
    /// Размер основной базы в байтах.
    pub size_bytes: u64,
    /// Размер WAL-файла рядом с базой в байтах (0, если его нет).
    pub wal_bytes: u64,
    pub intervals: i64,
    pub interval_texts: i64,
    pub voice_events: i64,
    /// Доступен ли FTS5 (иначе поиск идёт по LIKE).
    pub fts5: bool,
    pub first_start_at: String,
    pub last_end_at: String,
}

// ---------------------------------------------------------------------------
// Metrics & state
// ---------------------------------------------------------------------------

#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SessionState {
    Idle,
    Loading,
    Recording,
    Stopping,
    Error,
}

/// Per-channel live metrics.
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SourceMetrics {
    pub channel_id: String,
    pub enabled: bool,
    pub status: String,
    pub queue_size: u32,
    pub dropped_chunks: u64,
    pub busy: bool,
    pub last_rtf: f32,
    pub lag_estimate_s: f32,
    pub words: u32,
    pub last_text: String,
    pub last_language: String,
    pub speech_seconds: f32,
}

/// A snapshot of the whole engine, pushed to the UI ~1/s.
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MetricsSnapshot {
    pub state_running: bool,
    pub state_loading: bool,
    pub state_stopping: bool,
    pub model_loaded: bool,
    pub model_name: String,
    pub started_at: String,
    pub last_write_at: String,
    pub total_words: u32,
    pub total_intervals: u32,
    pub bg_queue_depth: u32,
    pub bg_queue_capacity: u32,
    pub current_interval_elapsed_s: f32,
    pub current_interval_start_at: String,
    pub channels_silent: bool,
    pub sources: Vec<SourceMetrics>,
    /// Текущая загрузка CPU процессом в процентах (может быть >100% при
    /// нескольких рабочих потоках — как в Activity Monitor).
    pub cpu_percent: f32,
    /// Медиана (50-й перцентиль) CPU% за скользящее окно последних сэмплов.
    pub cpu_p50: f32,
    /// 90-й перцентиль CPU% за скользящее окно — индикатор «пиков».
    pub cpu_p90: f32,
    /// Текущий резидентный размер памяти процесса (RSS) в байтах.
    pub memory_rss_bytes: u64,
    /// Пиковый RSS за окно/сессию в байтах.
    pub memory_rss_peak_bytes: u64,
    pub last_error: String,
    /// Сколько интервалов за сессию было выброшено (переполнение ASR-очереди
    /// или прерывание остановки по дедлайну). 0 — потерь не было.
    pub dropped_intervals: u32,
}

// ---------------------------------------------------------------------------
// Model management
// ---------------------------------------------------------------------------

#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ModelStatus {
    pub id: String,
    pub label: String,
    pub family: String,  // "whisper" | "parakeet"
    pub runtime: String, // "sherpa" | "coreml" | "whisper.cpp"
    pub installed: bool,
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub progress_pct: f32,
    pub downloading: bool,
    pub last_error: String,
}

// ---------------------------------------------------------------------------
// Audio input enumeration is a PLATFORM concern; the core never captures.
// The shell pushes PCM via TranscriberCore::push_audio_frame.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Events emitted to the shell
// ---------------------------------------------------------------------------

#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum CoreEvent {
    StateChanged { state: SessionState },
    IntervalCommitted { interval: IntervalRecord },
    Metrics { snapshot: MetricsSnapshot },
    VoiceActivity { channel_id: String, at: String },
    ModelProgress { status: ModelStatus },
    Error { code: ErrorCode, message: String },
}

#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ErrorCode {
    Config,
    ModelLoad,
    ModelDownload,
    Audio,
    Backend,
    Store,
    Api,
    Internal,
}
