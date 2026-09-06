//! TranscriberCore — the public facade and orchestration spine.
//!
//! Threading: `push_audio_frame` resamples to 16kHz mono and writes to a
//! per-channel lock-free ring (never blocks). A DSP thread frames at 30ms,
//! runs VAD, drives the interval coordinator and, on a cut, slices the
//! per-channel buffers and hands the interval to a bounded queue. One ASR
//! worker drains that queue, transcribes (30s chunks; whisper multi-candidate),
//! persists to the store and emits events. A ticker emits metrics ~1/s and, when
//! `CoreConfig::retention_days > 0`, sweeps history older than that (at session
//! start and every 24h) — maintenance never runs on the realtime threads.
//!
//! Запросы к истории через фасад: `query_intervals`, `intervals_overview`,
//! `intervals_overview_range`, `search_intervals`, `interval_by_id`,
//! `voice_activity`; обслуживание базы — `store_maintenance`, `store_info`.

use crate::asr::{
    create_backend, is_safe_asr_audio, AsrBackend, BackendInit, MIN_ASR_AUDIO_SAMPLES,
};
use crate::audio::resample::to_mono_16k_i16;
use crate::audio::ring::{pcm_ring, PcmConsumer, PcmProducer};
use crate::errors::CoreError;
use crate::events::{CoreEventListener, EventBus};
use crate::interval::IntervalCutCoordinator;
use crate::lang::{clean_transcribed_text, count_words, pick_best_candidate, Candidate};
use crate::metrics::{Metrics, SourcePatch};
use crate::types::*;
use crate::vad::{make_vad, Vad, FRAME_SAMPLES};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[cfg(feature = "store")]
use crate::store::{Store, SESSION_STOP_ERROR, SESSION_STOP_USER};

const TARGET_SAMPLE_RATE: u32 = 16_000;
/// Long intervals are transcribed in ≤30s chunks (ported `_TRANSCRIBE_CHUNK_S`).
/// NB: уменьшение чанка НЕ даёт надёжного выигрыша по RSS — арена активаций ORT
/// отдаётся между инференсами, а стационар определяется весами модели (замерено:
/// 10/15/30с дают 1.47/1.72/1.67 ГБ — разброс перекрывает эффект). Поэтому
/// оставляем 30с (лучше для качества: меньше разрезов слов на границах чанков).
const TRANSCRIBE_CHUNK_SAMPLES: usize = 30 * TARGET_SAMPLE_RATE as usize;

type IntervalJob = (
    chrono::DateTime<chrono::Local>,
    chrono::DateTime<chrono::Local>,
    HashMap<String, Vec<i16>>,
);

/// Сообщение внутренней очереди DSP → ASR.
///
/// Разделение на `Interval`/`Tail` нужно остановке: штатный стоп обязан
/// дотранскрибировать и уже накопленный backlog (это реальная речь
/// пользователя), и хвост текущего интервала. `Finish` — маркер того, что DSP
/// завершился и новых сообщений не будет.
enum AsrMsg {
    /// Обычный интервал, нарезанный координатором.
    Interval(IntervalJob),
    /// Хвост текущего интервала, сброшенный при остановке.
    Tail(IntervalJob),
    /// DSP закончил работу.
    Finish,
}

/// Параметры, применяемые ГОРЯЧО во время записи без перезапуска сессии.
///
/// Живут в `Arc<Mutex<RuntimeParams>>` внутри `TranscriberCore`. `configure()`
/// обновляет их под мьютексом; DSP-поток на каждом тике перечитывает интервалы,
/// порог тишины и пороги VAD, а ASR-воркер — язык на каждом интервале. Модель
/// сюда НЕ входит: она снимок старта и меняется только перезапуском.
#[derive(Clone, Debug)]
struct RuntimeParams {
    min_interval_s: f64,
    max_interval_s: f64,
    silence_cut_ms: f64,
    silero_threshold: f32,
    rms_fallback: f32,
    language: LanguageMode,
}

impl RuntimeParams {
    fn from_config(cfg: &CoreConfig) -> Self {
        Self {
            min_interval_s: cfg.min_interval_s as f64,
            max_interval_s: cfg.max_interval_s as f64,
            silence_cut_ms: cfg.silence_cut_ms as f64,
            silero_threshold: cfg.vad.silero_threshold,
            rms_fallback: cfg.vad.rms_fallback,
            language: cfg.language.clone(),
        }
    }
}

/// Core library version (smoke-test + diagnostics across the FFI boundary).
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg_attr(feature = "ffi", derive(uniffi::Object))]
pub struct TranscriberCore {
    /// Актуальный конфиг. `Arc`, потому что тикер обслуживания читает из него
    /// срок хранения на каждом проходе — чтобы `configure()` применялся горячо,
    /// без перезапуска сессии.
    config: Arc<Mutex<CoreConfig>>,
    channels: Mutex<Vec<ChannelSpec>>,
    events: EventBus,
    metrics: Arc<Metrics>,
    backend: Arc<Mutex<Option<Box<dyn AsrBackend>>>>,
    backend_loaded: Arc<AtomicBool>,
    /// Горячо применяемые параметры (интервалы/тишина/VAD/язык). Делится с DSP-
    /// и ASR-потоками; обновляется в `configure()` под мьютексом.
    runtime: Arc<Mutex<RuntimeParams>>,
    running: Mutex<Option<Running>>,
    #[cfg(feature = "store")]
    store: Arc<Store>,
    #[cfg(feature = "download")]
    models: crate::model_manager::ModelManager,
    #[cfg(feature = "api")]
    api: Mutex<Option<crate::api::ApiServer>>,
}

struct Running {
    /// Штатная остановка: DSP сбрасывает хвост и выходит, ASR дорабатывает всё,
    /// что уже стоит в очереди.
    stop: Arc<AtomicBool>,
    /// Аварийное прерывание остановки по дедлайну: ASR выбрасывает остаток
    /// очереди (одним событием) и выходит, как только вернётся из текущего
    /// нативного вызова. Ставится только из `stop()` по таймауту.
    abort: Arc<AtomicBool>,
    producers: HashMap<String, PcmProducer>,
    handles: Vec<JoinHandle<()>>,
    /// Строка `sessions` этой сессии записи. `None` — записать её не удалось
    /// (запись при этом идёт как обычно).
    #[cfg(feature = "store")]
    session: Option<Arc<SessionLog>>,
}

/// Учёт сессии записи в базе: «здесь включили» / «здесь выключили».
///
/// Нужен единой ленте журнала: разделители в UI рисуются по ФАКТУ из таблицы
/// `sessions`, а не по эвристике «пауза больше N секунд». Закрыть сессию может
/// любой из путей — штатный `stop()`, паника DSP, потеря ASR-воркера,
/// watchdog зависшего DSP; побеждает ПЕРВЫЙ (см. [`Store::close_session`]),
/// иначе авария маскировалась бы последующей штатной остановкой.
///
/// Ошибки записи сознательно не всплывают наружу: сессия — это метаданные
/// журнала, из-за них нельзя ронять `start()`/`stop()`. Причина уходит в
/// `diag::log`.
#[cfg(feature = "store")]
struct SessionLog {
    store: Arc<Store>,
    id: i64,
}

#[cfg(feature = "store")]
impl SessionLog {
    /// Открыть сессию «сейчас». `None` — база не приняла запись.
    fn open(store: &Arc<Store>) -> Option<Arc<Self>> {
        let at = chrono::Local::now().to_rfc3339();
        match store.open_session(&at) {
            Ok(id) => Some(Arc::new(Self {
                store: store.clone(),
                id,
            })),
            Err(e) => {
                crate::diag::log(&format!("sessions: не удалось открыть сессию: {e}"));
                None
            }
        }
    }

    /// Закрыть сессию «сейчас» с указанной причиной.
    fn close(&self, stop_reason: &str) {
        let at = chrono::Local::now().to_rfc3339();
        if let Err(e) = self.store.close_session(self.id, &at, stop_reason) {
            crate::diag::log(&format!(
                "sessions: не удалось закрыть сессию {} ({stop_reason}): {e}",
                self.id
            ));
        }
    }
}

/// Закрыть сессию, если она вообще была открыта.
#[cfg(feature = "store")]
fn close_session(session: &Option<Arc<SessionLog>>, stop_reason: &str) {
    if let Some(s) = session {
        s.close(stop_reason);
    }
}

/// Внутренний счётчик интервалов, отброшенных при переполнении ASR-очереди.
///
/// Счётчик живёт весь запуск ядра, чтобы диагностические тесты и будущий
/// telemetry-слой могли отличить перегрузку от отсутствия аудио. Публичный
/// контракт метрик пока не расширяем.
#[derive(Default)]
struct QueueStats {
    dropped_jobs: AtomicU64,
    /// Зафиксировать закрытый ASR receiver и не повторять одно и то же событие.
    receiver_disconnected: AtomicBool,
}

/// Минимальный liveness-маркер DSP-потока.
///
/// DSP обновляет его после каждого тика, даже если rings пусты. Поэтому
/// отсутствие аудио не считается зависанием; тикер сообщает о stall только
/// когда сам DSP не возвращался к циклу дольше порога.
struct DspHealth {
    started_at: Instant,
    last_progress_ms: AtomicU64,
    stall_reported: AtomicBool,
    timeout: Duration,
}

/// Порог «DSP не возвращался в цикл». Держим его МЕНЬШЕ, чем глубина кольца
/// сырого аудио (`audio_queue_size`, дефолт 10с): сигнал должен приходить до
/// того, как сэмплы начнут теряться, а не после.
const DSP_STALL_TIMEOUT: Duration = Duration::from_secs(3);
const QUEUE_ERROR_INTERVAL_S: f64 = 30.0;

/// Сколько `stop()` ждёт штатного завершения рабочих потоков.
///
/// Нативный вызов ASR не отменяем: единственная защита от зависшего рантайма —
/// дедлайн, после которого backlog выбрасывается (`abort`), а `stop()` не
/// висит бесконечно на join.
const STOP_DEADLINE: Duration = Duration::from_secs(60);
/// Отсрочка после `abort` — воркеру нужно вернуться из текущего вызова.
const STOP_ABORT_GRACE: Duration = Duration::from_secs(5);
/// Период перечитывания горячих параметров и обновления метрик в DSP.
/// Сам цикл крутится каждые 10мс (realtime-нарезка), но `runtime.lock()`,
/// `set_threshold`, счёт кадров речи и `to_rfc3339()` там не нужны.
const DSP_SLOW_TICK_EVERY: u64 = 20;
/// Шаг тикера метрик; период эмита складывается из этих шагов.
const TICK_STEP: Duration = Duration::from_millis(100);
/// Как часто во время сессии повторяется чистка по сроку хранения.
/// Первый проход делается сразу при старте сессии.
#[cfg(feature = "store")]
const RETENTION_PERIOD: Duration = Duration::from_secs(24 * 60 * 60);

impl DspHealth {
    fn new() -> Self {
        Self {
            started_at: Instant::now(),
            last_progress_ms: AtomicU64::new(0),
            stall_reported: AtomicBool::new(false),
            timeout: DSP_STALL_TIMEOUT,
        }
    }

    #[cfg(all(test, feature = "store"))]
    fn with_timeout(timeout: Duration) -> Self {
        Self {
            started_at: Instant::now(),
            last_progress_ms: AtomicU64::new(0),
            stall_reported: AtomicBool::new(false),
            timeout,
        }
    }

    fn touch(&self) {
        let elapsed_ms = self.started_at.elapsed().as_millis() as u64;
        self.last_progress_ms.store(elapsed_ms, Ordering::Release);
        self.stall_reported.store(false, Ordering::Release);
    }

    /// Вернуть true ровно один раз за один stall-период.
    fn stalled_event_due(&self) -> bool {
        let now_ms = self.started_at.elapsed().as_millis() as u64;
        let last_ms = self.last_progress_ms.load(Ordering::Acquire);
        if now_ms.saturating_sub(last_ms) < self.timeout.as_millis() as u64 {
            // DSP мог возобновиться между проверками; следующий stall снова
            // должен получить одно событие.
            self.stall_reported.store(false, Ordering::Release);
            return false;
        }
        !self.stall_reported.swap(true, Ordering::AcqRel)
    }
}

#[cfg_attr(feature = "ffi", uniffi::export)]
impl TranscriberCore {
    #[cfg_attr(feature = "ffi", uniffi::constructor)]
    pub fn new(
        config: CoreConfig,
        listener: Box<dyn CoreEventListener>,
    ) -> Result<Arc<Self>, CoreError> {
        let config = config.validated()?;
        // Crash diagnostics: capture Rust panics and (in the packaged app) the
        // C++ ASR runtime's stderr into <storage_path>/logs/core.log, so a
        // background `tc-asr` abort leaves a readable error behind.
        crate::diag::init(&std::path::Path::new(&config.storage_path).join("logs"));
        let events = EventBus::new();
        events.set_listener(listener);

        #[cfg(feature = "store")]
        let store = {
            let db = std::path::Path::new(&config.storage_path).join("transcriber.sqlite");
            if let Some(parent) = db.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            Arc::new(Store::open(db.to_string_lossy().as_ref())?)
        };

        #[cfg(feature = "download")]
        let models = crate::model_manager::ModelManager::new(&config.models_path);

        let runtime = Arc::new(Mutex::new(RuntimeParams::from_config(&config)));

        let core = Arc::new(Self {
            config: Arc::new(Mutex::new(config)),
            channels: Mutex::new(Vec::new()),
            events,
            metrics: Arc::new(Metrics::new()),
            backend: Arc::new(Mutex::new(None)),
            backend_loaded: Arc::new(AtomicBool::new(false)),
            runtime,
            running: Mutex::new(None),
            #[cfg(feature = "store")]
            store,
            #[cfg(feature = "download")]
            models,
            #[cfg(feature = "api")]
            api: Mutex::new(None),
        });

        // Start the optional API if it was enabled in the initial config.
        #[cfg(all(feature = "api", feature = "store"))]
        {
            let api_cfg = core.config.lock().api.clone();
            if api_cfg.enabled {
                core.start_api(api_cfg)?;
            }
        }
        Ok(core)
    }

    pub fn register_channel(&self, channel: ChannelSpec) -> Result<(), CoreError> {
        if self.running.lock().is_some() {
            return Err(CoreError::Config(
                "cannot register channels while running".into(),
            ));
        }
        let mut chans = self.channels.lock();
        if chans.iter().any(|c| c.id == channel.id) {
            return Err(CoreError::Config(format!(
                "channel '{}' already registered",
                channel.id
            )));
        }
        self.metrics.set_source(&channel.id, true, "ready");
        chans.push(channel);
        Ok(())
    }

    pub fn configure(&self, config: CoreConfig) -> Result<(), CoreError> {
        let config = config.validated()?;
        #[cfg(all(feature = "api", feature = "store"))]
        {
            let was = self.config.lock().api.clone();
            if config.api != was {
                self.stop_api();
                if config.api.enabled {
                    self.start_api(config.api.clone())?;
                }
            }
        }
        // Горячее применение: интервалы/тишина/VAD/язык перечитываются рабочими
        // потоками в течение ~тика. Модель НЕ трогаем — это снимок старта,
        // меняется только перезапуском сессии.
        *self.runtime.lock() = RuntimeParams::from_config(&config);
        *self.config.lock() = config;
        Ok(())
    }

    /// Load the configured model into a backend. Must be called before start().
    ///
    /// Во время сессии загрузка ЗАПРЕЩЕНА: рабочий ASR-поток держит `backend`
    /// под мьютексом, и подмена весов под ним — это либо зависание записи, либо
    /// интервал, транскрибированный «половиной» старой и новой модели. Модель —
    /// снимок старта (см. `Engine.applyModelRestart`: стоп → загрузка → старт).
    ///
    /// Старый бэкенд освобождается ДО создания нового, иначе в пике в памяти
    /// живут две модели (для Parakeet это ~2.5 ГБ лишних). Следствие: неудачная
    /// перезагрузка оставляет ядро БЕЗ модели — честнее, чем тихо продолжать
    /// работать на прежних весах, о которых UI уже не знает.
    pub fn load_model(&self) -> Result<(), CoreError> {
        if self.running.lock().is_some() {
            return Err(CoreError::Config(
                "cannot load a model while running; stop the session first".into(),
            ));
        }
        self.events.emit(CoreEvent::StateChanged {
            state: SessionState::Loading,
        });
        self.metrics.set_running(false, true);
        let cfg = self.config.lock().clone();
        // Освобождаем прежние веса до аллокации новых.
        self.backend_loaded.store(false, Ordering::SeqCst);
        *self.backend.lock() = None;

        // Служебный Silero VAD (1.8 МБ) мог не приехать вместе с моделью,
        // скачанной до его появления в реестре. Пытаемся догрузить; сбой не
        // фатален — движок продолжит на RMS-детекторе с предупреждением.
        // Условие «ASR-модель уже установлена здесь» намеренное: мы лишь
        // ДОукомплектовываем существующую установку и не ходим в сеть там, где
        // весов нет вовсе (mock-сборки, тесты, чужой каталог моделей).
        #[cfg(feature = "download")]
        if self.models.is_installed(model_id(&cfg.model))
            && !crate::vad::silero_model_path(&cfg.models_path).is_file()
        {
            if let Err(e) = self.models.ensure_vad() {
                crate::diag::log(&format!("silero vad ensure failed: {e}"));
            }
        }

        let init = BackendInit {
            model: cfg.model.clone(),
            models_path: cfg.models_path.clone(),
            n_threads: cfg.n_threads,
            acceleration: cfg.acceleration,
        };
        match create_backend(&init) {
            Ok(b) => {
                *self.backend.lock() = Some(b);
                self.backend_loaded.store(true, Ordering::SeqCst);
                self.metrics.set_model_loaded();
                self.events.emit(CoreEvent::StateChanged {
                    state: SessionState::Idle,
                });
                Ok(())
            }
            Err(e) => {
                self.metrics.set_error(&e.to_string());
                self.events.emit(CoreEvent::Error {
                    code: e.code(),
                    message: e.to_string(),
                });
                Err(e)
            }
        }
    }

    pub fn start(&self) -> Result<(), CoreError> {
        let mut running = self.running.lock();
        if running.is_some() {
            return Err(CoreError::Config("already running".into()));
        }
        if !self.backend_loaded.load(Ordering::SeqCst) {
            return Err(CoreError::ModelLoad(
                "model not loaded; call load_model() first".into(),
            ));
        }
        let cfg = self.config.lock().clone();
        let channels = self.channels.lock().clone();
        if channels.is_empty() {
            return Err(CoreError::Config("no channels registered".into()));
        }
        // Синхронизируем общий блок с текущим конфигом на момент старта.
        *self.runtime.lock() = RuntimeParams::from_config(&cfg);

        self.metrics.reset_for_run(&model_name(&cfg.model));
        self.metrics.set_running(true, false);
        for ch in &channels {
            self.metrics.set_source(&ch.id, true, "listening");
        }

        // Факт «здесь запись включили». Незакрытые сессии прошлых запусков
        // (процесс убили) НЕ трогаем — это и есть «приложение закрылось».
        #[cfg(feature = "store")]
        let session = SessionLog::open(&self.store);

        let stop = Arc::new(AtomicBool::new(false));
        let abort = Arc::new(AtomicBool::new(false));
        let asr_done = Arc::new(AtomicBool::new(false));
        let queue_stats = Arc::new(QueueStats::default());
        let dsp_health = Arc::new(DspHealth::new());
        let (tx, rx) = crossbeam_channel::bounded::<AsrMsg>(cfg.bg_queue_size as usize);

        // Per-channel rings: producer kept for push_audio_frame, consumer to DSP.
        // Отсутствие Silero — свойство всей сессии, а не канала: копим причину и
        // говорим о ней ОДИН раз, а не по событию на каждый источник.
        let mut vad_warning: Option<String> = None;
        let mut producers = HashMap::new();
        let mut dsp_channels = Vec::new();
        for ch in &channels {
            let (prod, cons) = pcm_ring(cfg.audio_queue_size as usize);
            producers.insert(ch.id.clone(), prod);
            let choice = make_vad(&cfg.vad, &cfg.models_path);
            if vad_warning.is_none() {
                vad_warning = choice.fallback_warning;
            }
            dsp_channels.push(ChannelDsp {
                id: ch.id.clone(),
                consumer: cons,
                vad: choice.vad,
                buffer: Vec::new(),
                partial: Vec::new(),
                speech_flags: Vec::new(),
            });
        }

        let mut handles: Vec<JoinHandle<()>> = Vec::new();
        // DSP thread
        {
            let cfg = cfg.clone();
            let metrics = self.metrics.clone();
            let thread_stop = stop.clone();
            let tx = tx.clone();
            let runtime = self.runtime.clone();
            let events = self.events.clone();
            let queue_stats = queue_stats.clone();
            let dsp_health = dsp_health.clone();
            #[cfg(feature = "store")]
            let dsp_session = session.clone();
            #[cfg(feature = "store")]
            let dsp_stats = queue_stats.clone();
            let spawned = std::thread::Builder::new()
                .name("tc-dsp".into())
                .spawn(move || {
                    // Паника в DSP раньше молча убивала нарезку: запись «шла»,
                    // а интервалы не появлялись. Ловим, сообщаем и переводим
                    // сессию в Error — симметрично ветке Disconnected.
                    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        dsp_loop(
                            dsp_channels,
                            cfg,
                            runtime,
                            metrics,
                            events.clone(),
                            thread_stop.clone(),
                            tx,
                            queue_stats,
                            dsp_health,
                        );
                    }));
                    if let Err(panic) = outcome {
                        thread_stop.store(true, Ordering::SeqCst);
                        events.emit(CoreEvent::Error {
                            code: ErrorCode::Internal,
                            message: format!(
                                "DSP thread panicked: {}; recording stopped",
                                panic_message(&panic)
                            ),
                        });
                        events.emit(CoreEvent::StateChanged {
                            state: SessionState::Error,
                        });
                        #[cfg(feature = "store")]
                        close_session(&dsp_session, SESSION_STOP_ERROR);
                    }
                    // Потеря ASR-воркера (`try_enqueue_job` → Disconnected) —
                    // тот же аварийный конец сессии: DSP выходит штатно, но
                    // запись уже остановлена и `StateChanged{Error}` отправлен.
                    #[cfg(feature = "store")]
                    if dsp_stats.receiver_disconnected.load(Ordering::Acquire) {
                        close_session(&dsp_session, SESSION_STOP_ERROR);
                    }
                });
            match spawned {
                Ok(h) => handles.push(h),
                Err(e) => {
                    self.abort_partial_start(
                        &stop,
                        handles,
                        #[cfg(feature = "store")]
                        &session,
                    );
                    return Err(CoreError::Internal(format!("spawn dsp: {e}")));
                }
            }
        }
        // ASR worker thread
        {
            let backend = self.backend.clone();
            let metrics = self.metrics.clone();
            let events = self.events.clone();
            let cfg = cfg.clone();
            let runtime = self.runtime.clone();
            let abort = abort.clone();
            let asr_done = asr_done.clone();
            let queue_stats = queue_stats.clone();
            #[cfg(feature = "store")]
            let store = self.store.clone();
            let spawned = std::thread::Builder::new()
                .name("tc-asr".into())
                .spawn(move || {
                    asr_loop(
                        rx,
                        backend,
                        runtime,
                        metrics,
                        events,
                        abort,
                        asr_done,
                        queue_stats,
                        cfg,
                        #[cfg(feature = "store")]
                        store,
                    );
                });
            match spawned {
                Ok(h) => handles.push(h),
                Err(e) => {
                    // rx уже уничтожен вместе с замыканием; stop выставляем
                    // ДО join, чтобы DSP не принял это за аварию воркера.
                    self.abort_partial_start(
                        &stop,
                        handles,
                        #[cfg(feature = "store")]
                        &session,
                    );
                    return Err(CoreError::Internal(format!("spawn asr: {e}")));
                }
            }
        }
        // Metrics ticker (+ фоновое обслуживание хранилища по сроку хранения)
        {
            let metrics = self.metrics.clone();
            let events = self.events.clone();
            let thread_stop = stop.clone();
            let abort = abort.clone();
            let asr_done = asr_done.clone();
            let dsp_health = dsp_health.clone();
            #[cfg(feature = "store")]
            let store = self.store.clone();
            #[cfg(feature = "store")]
            let config = self.config.clone();
            #[cfg(feature = "store")]
            let tick_session = session.clone();
            let spawned = std::thread::Builder::new()
                .name("tc-tick".into())
                .spawn(move || {
                    // Чистка по сроку хранения — на старте сессии и далее раз в
                    // сутки. Живёт в тикере, а не в `start()`/DSP: удаление и
                    // `PRAGMA optimize` могут занять секунды на большой базе, и
                    // ни UI-поток, ни realtime-нарезку тормозить нельзя.
                    #[cfg(feature = "store")]
                    let mut since_maintenance = Duration::ZERO;
                    #[cfg(feature = "store")]
                    {
                        // Значение снимается ДО чистки: держать мьютекс конфига
                        // всё время удаления нельзя — на нём же сидит
                        // `configure()` из UI-потока.
                        let days = config.lock().retention_days;
                        sweep_retention(&store, &events, days);
                    }
                    let mut since_emit = Duration::ZERO;
                    loop {
                        std::thread::sleep(TICK_STEP);
                        let stopping = thread_stop.load(Ordering::SeqCst);
                        // Во время Stopping тикер ЖИВЁТ дальше: UI должен
                        // видеть, как убывает очередь («осталось N»). Выходим,
                        // когда ASR-воркер закончил или остановку прервали.
                        if abort.load(Ordering::SeqCst)
                            || (stopping && asr_done.load(Ordering::Acquire))
                        {
                            break;
                        }
                        // Срок хранения перечитывается из актуального конфига:
                        // `configure()` меняет его горячо, как и остальные
                        // «мягкие» параметры.
                        #[cfg(feature = "store")]
                        {
                            since_maintenance += TICK_STEP;
                            if since_maintenance >= RETENTION_PERIOD {
                                since_maintenance = Duration::ZERO;
                                let days = config.lock().retention_days;
                                sweep_retention(&store, &events, days);
                            }
                        }
                        since_emit += TICK_STEP;
                        let period = if stopping {
                            Duration::from_millis(200)
                        } else {
                            Duration::from_millis(1000)
                        };
                        if since_emit < period {
                            continue;
                        }
                        since_emit = Duration::ZERO;
                        metrics.sample_system();
                        events.emit(CoreEvent::Metrics {
                            snapshot: metrics.snapshot(),
                        });
                        if !stopping && dsp_health.stalled_event_due() {
                            events.emit(CoreEvent::Error {
                                code: ErrorCode::Internal,
                                message: format!(
                                    "DSP thread stalled for more than {}s; audio may be dropped",
                                    DSP_STALL_TIMEOUT.as_secs()
                                ),
                            });
                            events.emit(CoreEvent::StateChanged {
                                state: SessionState::Error,
                            });
                            // Watchdog: сессия кончилась аварийно, даже если
                            // оболочка ещё не позвала stop().
                            #[cfg(feature = "store")]
                            close_session(&tick_session, SESSION_STOP_ERROR);
                        }
                    }
                });
            match spawned {
                Ok(h) => handles.push(h),
                Err(e) => {
                    self.abort_partial_start(
                        &stop,
                        handles,
                        #[cfg(feature = "store")]
                        &session,
                    );
                    return Err(CoreError::Internal(format!("spawn ticker: {e}")));
                }
            }
        }

        // Drop our extra tx clone so the channel closes once DSP exits.
        drop(tx);
        *running = Some(Running {
            stop,
            abort,
            producers,
            handles,
            #[cfg(feature = "store")]
            session,
        });
        self.events.emit(CoreEvent::StateChanged {
            state: SessionState::Recording,
        });
        if let Some(message) = vad_warning {
            // Не ошибка запуска: запись идёт, но качество нарезки хуже.
            self.events.emit(CoreEvent::Error {
                code: ErrorCode::ModelLoad,
                message,
            });
        }
        Ok(())
    }

    pub fn push_audio_frame(
        &self,
        channel_id: String,
        pcm: Vec<i16>,
        sample_rate: u32,
        channels: u8,
    ) {
        // Reject invalid capture metadata before entering DSP.  The resampler
        // also validates this contract, but keeping the public boundary cheap
        // and explicit prevents future callers from accidentally treating a
        // zero channel count as mono or dividing by a zero sample rate.
        if sample_rate == 0 || channels == 0 {
            return;
        }
        let mono16 = to_mono_16k_i16(&pcm, sample_rate, channels);
        if mono16.is_empty() {
            return;
        }
        if let Some(running) = self.running.lock().as_mut() {
            if let Some(prod) = running.producers.get_mut(&channel_id) {
                prod.push_samples(&mono16);
            }
        }
    }

    /// Остановить сессию, дав ядру дотранскрибировать уже записанное.
    ///
    /// Порядок: `stop` → DSP сбрасывает хвост и выходит → ASR дорабатывает
    /// очередь (backlog + хвост) → тикер продолжает отдавать метрики, чтобы UI
    /// видел убывающую очередь. Если рабочие потоки не уложились в
    /// [`STOP_DEADLINE`] (почти всегда — зависший нативный вызов ASR), ставится
    /// `abort`: воркер выбрасывает остаток одним событием и выходит. Если и
    /// после [`STOP_ABORT_GRACE`] поток жив, он ОТСОЕДИНЯЕТСЯ — бесконечный
    /// join навсегда подвесил бы UI.
    pub fn stop(&self) -> Result<(), CoreError> {
        let running = self.running.lock().take();
        let Some(running) = running else {
            return Err(CoreError::Config("not running".into()));
        };
        #[cfg(feature = "store")]
        let session = running.session.clone();
        let Running {
            stop,
            abort,
            producers,
            handles,
            ..
        } = running;
        // Кольца больше не нужны: `running` уже снят, push_audio_frame не пишет.
        drop(producers);
        self.metrics.set_stopping(true);
        self.events.emit(CoreEvent::StateChanged {
            state: SessionState::Stopping,
        });
        stop.store(true, Ordering::SeqCst);

        let mut clean = wait_for_workers(&handles, STOP_DEADLINE);
        if !clean {
            abort.store(true, Ordering::SeqCst);
            clean = wait_for_workers(&handles, STOP_ABORT_GRACE);
        }
        for h in handles {
            if h.is_finished() {
                let _ = h.join();
            }
            // Иначе поток отсоединяется вместе с JoinHandle.
        }
        if !clean {
            self.events.emit(CoreEvent::Error {
                code: ErrorCode::Internal,
                message: format!(
                    "рабочий поток не завершился за {}с и отсоединён; часть аудио могла быть потеряна",
                    (STOP_DEADLINE + STOP_ABORT_GRACE).as_secs()
                ),
            });
        }
        // Факт «здесь запись выключили». Прерванная по дедлайну остановка
        // (`abort` + отсоединённый поток) — это авария, а не штатный стоп.
        // Если сессию уже закрыл аварийный путь, его причина остаётся.
        #[cfg(feature = "store")]
        close_session(
            &session,
            if clean {
                SESSION_STOP_USER
            } else {
                SESSION_STOP_ERROR
            },
        );
        self.metrics.set_running(false, false);
        self.metrics.set_stopping(false);
        self.events.emit(CoreEvent::StateChanged {
            state: SessionState::Idle,
        });
        Ok(())
    }

    // ---- queries ----
    pub fn query_intervals(
        &self,
        from: String,
        to: String,
    ) -> Result<Vec<IntervalRecord>, CoreError> {
        #[cfg(feature = "store")]
        {
            self.store.query_intervals(&from, &to)
        }
        #[cfg(not(feature = "store"))]
        {
            let _ = (from, to);
            Err(CoreError::Store("store feature disabled".into()))
        }
    }

    /// Последние `limit` интервалов с текстами, НОВЫЕ ПЕРВЫМИ, без периода.
    ///
    /// Панели меню-бара нужен хвост истории (реплики за прошлые сессии): без
    /// этого её лента после перезапуска приложения пуста, потому что события
    /// живут только в памяти. Запрос «за последние трое суток» ради этого
    /// сканирует диапазон впустую. `limit` подрезается потолком страницы
    /// хранилища.
    pub fn recent_intervals(&self, limit: u32) -> Result<Vec<IntervalRecord>, CoreError> {
        #[cfg(feature = "store")]
        {
            self.store.recent_intervals(limit)
        }
        #[cfg(not(feature = "store"))]
        {
            let _ = limit;
            Err(CoreError::Store("store feature disabled".into()))
        }
    }

    /// Сессии записи за период (ISO-8601 с таймзоной), по возрастанию времени.
    ///
    /// Оболочка рисует по ним разделители единой ленты журнала: «здесь запись
    /// включили», «здесь выключили», «здесь приложение закрылось». Возвращаются
    /// сессии, у которых в период попадает НАЧАЛО ИЛИ КОНЕЦ. Пустой `ended_at`
    /// (и пустой `stop_reason`) — сессия не закрыта штатно: процесс убили.
    pub fn query_sessions(
        &self,
        from: String,
        to: String,
    ) -> Result<Vec<SessionRecord>, CoreError> {
        #[cfg(feature = "store")]
        {
            self.store.sessions(&from, &to)
        }
        #[cfg(not(feature = "store"))]
        {
            let _ = (from, to);
            Err(CoreError::Store("store feature disabled".into()))
        }
    }

    /// Последние `limit` сессий записи, НОВЫЕ ПЕРВЫМИ.
    ///
    /// Для панели меню-бара: она показывает хвост истории без выбора периода.
    pub fn recent_sessions(&self, limit: u32) -> Result<Vec<SessionRecord>, CoreError> {
        #[cfg(feature = "store")]
        {
            self.store.last_sessions(limit)
        }
        #[cfg(not(feature = "store"))]
        {
            let _ = limit;
            Err(CoreError::Store("store feature disabled".into()))
        }
    }

    pub fn intervals_overview(&self) -> Result<Vec<IntervalOverviewItem>, CoreError> {
        #[cfg(feature = "store")]
        {
            self.store.overview()
        }
        #[cfg(not(feature = "store"))]
        {
            Err(CoreError::Store("store feature disabled".into()))
        }
    }
    /// Обзор интервалов за период с постраничной выборкой (без текстов).
    ///
    /// `from`/`to` — ISO-8601 с таймзоной; попадают интервалы, ПЕРЕСЕКАЮЩИЕ
    /// период. `limit` подрезается потолком страницы хранилища.
    pub fn intervals_overview_range(
        &self,
        from: String,
        to: String,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<IntervalOverviewItem>, CoreError> {
        #[cfg(feature = "store")]
        {
            self.store.overview_range(&from, &to, limit, offset)
        }
        #[cfg(not(feature = "store"))]
        {
            let _ = (from, to, limit, offset);
            Err(CoreError::Store("store feature disabled".into()))
        }
    }

    /// Полнотекстовый поиск по расшифровкам. Границы периода опциональны
    /// (ISO-8601 с таймзоной); результат — интервалы целиком, новые сверху.
    ///
    /// Пустой запрос — `CoreError::Config` (это ошибка ввода, не хранилища).
    pub fn search_intervals(
        &self,
        query: String,
        from: Option<String>,
        to: Option<String>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<IntervalRecord>, CoreError> {
        #[cfg(feature = "store")]
        {
            self.store
                .search(&query, from.as_deref(), to.as_deref(), limit, offset)
        }
        #[cfg(not(feature = "store"))]
        {
            let _ = (query, from, to, limit, offset);
            Err(CoreError::Store("store feature disabled".into()))
        }
    }

    /// Один интервал по идентификатору; `None` — такого интервала нет.
    pub fn interval_by_id(&self, id: i64) -> Result<Option<IntervalRecord>, CoreError> {
        #[cfg(feature = "store")]
        {
            self.store.interval_by_id(id)
        }
        #[cfg(not(feature = "store"))]
        {
            let _ = id;
            Err(CoreError::Store("store feature disabled".into()))
        }
    }

    /// Ручное обслуживание базы: удалить историю старше `days` суток и
    /// выполнить дешёвое обслуживание. Возвращает число удалённых строк.
    ///
    /// `days == 0` ничего не удаляет — только обслуживание (эквивалент
    /// «хранить всегда»). Автоматическая чистка настраивается через
    /// `CoreConfig::retention_days` и идёт сама, пока сессия активна.
    pub fn store_maintenance(&self, days: u32) -> Result<u64, CoreError> {
        #[cfg(feature = "store")]
        {
            store_maintenance_inner(&self.store, days)
        }
        #[cfg(not(feature = "store"))]
        {
            let _ = days;
            Err(CoreError::Store("store feature disabled".into()))
        }
    }

    /// Состояние локальной базы: версия схемы, размер, счётчики, наличие FTS.
    pub fn store_info(&self) -> Result<StoreInfo, CoreError> {
        #[cfg(feature = "store")]
        {
            let i = self.store.info()?;
            Ok(StoreInfo {
                path: i.path,
                schema_version: i.schema_version,
                size_bytes: i.size_bytes,
                wal_bytes: i.wal_bytes,
                intervals: i.intervals,
                interval_texts: i.interval_texts,
                voice_events: i.voice_events,
                fts5: i.fts5,
                first_start_at: i.first_start_at.unwrap_or_default(),
                last_end_at: i.last_end_at.unwrap_or_default(),
            })
        }
        #[cfg(not(feature = "store"))]
        {
            Err(CoreError::Store("store feature disabled".into()))
        }
    }

    pub fn voice_activity(
        &self,
        kind: ActivityKind,
        from: String,
        to: String,
    ) -> Result<Vec<ActivityBucket>, CoreError> {
        #[cfg(feature = "store")]
        {
            self.store.voice_activity(kind, &from, &to)
        }
        #[cfg(not(feature = "store"))]
        {
            let _ = (kind, from, to);
            Err(CoreError::Store("store feature disabled".into()))
        }
    }
    pub fn current_state(&self) -> MetricsSnapshot {
        self.metrics.snapshot()
    }

    // ---- models ----
    pub fn list_models(&self) -> Vec<ModelStatus> {
        #[cfg(feature = "download")]
        {
            self.models.list()
        }
        #[cfg(not(feature = "download"))]
        {
            Vec::new()
        }
    }
    pub fn model_status(&self, id: String) -> Result<ModelStatus, CoreError> {
        #[cfg(feature = "download")]
        {
            self.models.status(&id)
        }
        #[cfg(not(feature = "download"))]
        {
            let _ = id;
            Err(CoreError::ModelDownload("download feature disabled".into()))
        }
    }
    pub fn download_model(&self, id: String) -> Result<(), CoreError> {
        #[cfg(feature = "download")]
        {
            let events = self.events.clone();
            self.models.download(&id, &move |st| {
                events.emit(CoreEvent::ModelProgress { status: st });
            })
        }
        #[cfg(not(feature = "download"))]
        {
            let _ = id;
            Err(CoreError::ModelDownload("download feature disabled".into()))
        }
    }
    /// Догрузить служебную модель Silero VAD, если её ещё нет (~1.8 МБ).
    ///
    /// Аддитивный метод: обычно VAD приезжает вместе с ASR-моделью
    /// (`download_model`) и проверяется в `load_model`. Нужен оболочке, чтобы
    /// починить установку, сделанную до появления записи `silero-vad` в
    /// реестре, не перекачивая веса ASR. Идемпотентен.
    pub fn ensure_vad_model(&self) -> Result<(), CoreError> {
        #[cfg(feature = "download")]
        {
            self.models.ensure_vad()
        }
        #[cfg(not(feature = "download"))]
        {
            Err(CoreError::ModelDownload("download feature disabled".into()))
        }
    }

    pub fn delete_model(&self, id: String) -> Result<(), CoreError> {
        #[cfg(feature = "download")]
        {
            self.models.delete(&id)
        }
        #[cfg(not(feature = "download"))]
        {
            let _ = id;
            Err(CoreError::ModelDownload("download feature disabled".into()))
        }
    }

    // ---- optional API ----
    pub fn set_api_enabled(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = self.config.lock();
        cfg.api.enabled = enabled;
        let api_cfg = cfg.api.clone();
        drop(cfg);
        #[cfg(all(feature = "api", feature = "store"))]
        {
            self.stop_api();
            if enabled {
                self.start_api(api_cfg)?;
            }
            Ok(())
        }
        #[cfg(not(all(feature = "api", feature = "store")))]
        {
            let _ = api_cfg;
            Err(CoreError::Api("api feature disabled".into()))
        }
    }
}

impl TranscriberCore {
    /// Свернуть частично поднятую сессию: остановить и дождаться уже
    /// запущенных потоков, вернуть метрики в «не пишем», закрыть строку
    /// сессии с причиной «авария» (записи не было, но факт запуска уже есть).
    ///
    /// Без этого сбой `spawn` на втором/третьем потоке оставлял бы работающие
    /// потоки без владельца: `running` не выставлен, `stop()` их уже не увидит.
    fn abort_partial_start(
        &self,
        stop: &Arc<AtomicBool>,
        handles: Vec<JoinHandle<()>>,
        #[cfg(feature = "store")] session: &Option<Arc<SessionLog>>,
    ) {
        stop.store(true, Ordering::SeqCst);
        for h in handles {
            let _ = h.join();
        }
        self.metrics.set_running(false, false);
        #[cfg(feature = "store")]
        close_session(session, SESSION_STOP_ERROR);
    }

    #[cfg(all(feature = "api", feature = "store"))]
    fn start_api(&self, cfg: ApiConfig) -> Result<(), CoreError> {
        let server = crate::api::ApiServer::start(cfg, self.store.clone(), self.metrics.clone())?;
        *self.api.lock() = Some(server);
        Ok(())
    }
    #[cfg(all(feature = "api", feature = "store"))]
    fn stop_api(&self) {
        if let Some(server) = self.api.lock().take() {
            server.stop();
        }
    }
}

/// Обслуживание хранилища: чистка истории старше `days` суток + дешёвое
/// обслуживание базы (`PRAGMA optimize` + подрезка WAL).
///
/// `days == 0` означает «хранить всегда»: не удаляется ничего, выполняется
/// только обслуживание. Возвращает число удалённых строк.
#[cfg(feature = "store")]
fn store_maintenance_inner(store: &Store, days: u32) -> Result<u64, CoreError> {
    let deleted = if days == 0 {
        0
    } else {
        store.retention_sweep_all(i64::from(days))?
    };
    store.optimize()?;
    Ok(deleted)
}

/// Фоновая чистка по сроку хранения (вызывается только из тикера).
///
/// При `days == 0` не делает ничего. Сбой обслуживания не фатален: сессия
/// продолжается, а причина уходит в диагностический лог и событием `Error`,
/// чтобы оболочка могла её показать.
#[cfg(feature = "store")]
fn sweep_retention(store: &Store, events: &EventBus, days: u32) {
    if days == 0 {
        return;
    }
    match store_maintenance_inner(store, days) {
        Ok(deleted) => crate::diag::log(&format!(
            "retention: срок хранения {days} сут, удалено строк: {deleted}"
        )),
        Err(e) => {
            crate::diag::log(&format!(
                "retention: обслуживание хранилища не удалось: {e}"
            ));
            events.emit(CoreEvent::Error {
                code: ErrorCode::Store,
                message: format!("обслуживание хранилища не удалось: {e}"),
            });
        }
    }
}

/// Ждать завершения рабочих потоков не дольше `deadline`.
///
/// `JoinHandle::join` блокирует безусловно, а зависший нативный вызов ASR
/// отменить нечем — поэтому ждём опросом и умеем сдаться.
fn wait_for_workers(handles: &[JoinHandle<()>], deadline: Duration) -> bool {
    let until = Instant::now() + deadline;
    loop {
        if handles.iter().all(|h| h.is_finished()) {
            return true;
        }
        if Instant::now() >= until {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn model_name(m: &ModelSpec) -> String {
    match m {
        ModelSpec::Whisper { id } => format!("whisper:{id}"),
        ModelSpec::Parakeet { id } => format!("parakeet:{id}"),
    }
}

/// Идентификатор модели в реестре загрузчика (без префикса семейства).
#[cfg(feature = "download")]
fn model_id(m: &ModelSpec) -> &str {
    match m {
        ModelSpec::Whisper { id } | ModelSpec::Parakeet { id } => id,
    }
}

// ---------------------------------------------------------------------------
// DSP thread
// ---------------------------------------------------------------------------

struct ChannelDsp {
    id: String,
    consumer: PcmConsumer,
    vad: Box<dyn Vad>,
    buffer: Vec<i16>,
    partial: Vec<i16>,
    speech_flags: Vec<bool>,
}

/// Попытаться передать готовый интервал без блокировки DSP.
///
/// Переполненная очередь — ожидаемая перегрузка медленного ASR: аудио этого
/// интервала отбрасывается, а поток продолжает опустошать rings и вести
/// координатор. Ошибка ограничена по частоте, чтобы длительная перегрузка не
/// превратилась в собственный event-storm. `allow_when_stopping` нужен для
/// хвоста: его потеря при полном queue учитывается той же политикой, даже
/// когда общий stop-флаг уже установлен.
#[allow(clippy::too_many_arguments)]
fn try_enqueue_job(
    tx: &crossbeam_channel::Sender<AsrMsg>,
    msg: AsrMsg,
    stop: &AtomicBool,
    queue_stats: &QueueStats,
    events: &EventBus,
    mono_now: f64,
    last_error_mono: &mut f64,
    allow_when_stopping: bool,
) -> bool {
    if !allow_when_stopping && stop.load(Ordering::Acquire) {
        return true;
    }
    match tx.try_send(msg) {
        Ok(()) => true,
        Err(crossbeam_channel::TrySendError::Full(_)) => {
            queue_stats.dropped_jobs.fetch_add(1, Ordering::Relaxed);
            if *last_error_mono < 0.0 || mono_now - *last_error_mono >= QUEUE_ERROR_INTERVAL_S {
                *last_error_mono = mono_now;
                events.emit(CoreEvent::Error {
                    code: ErrorCode::Internal,
                    message: "ASR queue full; interval dropped".into(),
                });
            }
            true
        }
        Err(crossbeam_channel::TrySendError::Disconnected(_)) => {
            // A receiver disappearing while stop is false means the ASR
            // worker exited unexpectedly.  Report before the caller stores
            // stop=true; during an intentional stop the disconnect is normal.
            let stopping = stop.load(Ordering::Acquire);
            if !stopping
                && !queue_stats
                    .receiver_disconnected
                    .swap(true, Ordering::AcqRel)
            {
                events.emit(CoreEvent::Error {
                    code: ErrorCode::Internal,
                    message: "ASR worker disconnected; recording stopped".into(),
                });
                // SessionState::Error is part of the stable contract; shells
                // use it to leave Recording immediately and offer relaunch.
                events.emit(CoreEvent::StateChanged {
                    state: SessionState::Error,
                });
            }
            false
        }
    }
}

// Потоки получают владение явными зависимостями; сворачивать их в глобальный
// контекст было бы менее безопасно для остановки и тестов.
#[allow(clippy::too_many_arguments)]
fn dsp_loop(
    mut channels: Vec<ChannelDsp>,
    cfg: CoreConfig,
    runtime: Arc<Mutex<RuntimeParams>>,
    metrics: Arc<Metrics>,
    events: EventBus,
    stop: Arc<AtomicBool>,
    tx: crossbeam_channel::Sender<AsrMsg>,
    queue_stats: Arc<QueueStats>,
    dsp_health: Arc<DspHealth>,
) {
    let mut coord = IntervalCutCoordinator::new(
        cfg.min_interval_s as f64,
        cfg.max_interval_s as f64,
        cfg.silence_cut_ms as f64,
    );
    for ch in &channels {
        coord.register_channel(&ch.id);
    }
    let start = Instant::now();
    let mut scratch: Vec<i16> = Vec::new();
    let mut last_queue_error_mono = f64::NEG_INFINITY;
    // Кэш RFC3339 начала интервала: строка меняется только при резе, а не 100
    // раз в секунду (форматирование даты — самая дорогая часть тика).
    let mut cached_start: Option<(chrono::DateTime<chrono::Local>, String)> = None;
    let mut tick: u64 = 0;
    dsp_health.touch();

    loop {
        // Обновляем heartbeat в каждом проходе, включая пустой audio ring.
        dsp_health.touch();
        let stopping = stop.load(Ordering::SeqCst);
        let mono_now = start.elapsed().as_secs_f64();
        // Нарезка обязана идти каждые 10мс, а перечитывание настроек и метрики —
        // нет. Раз в ~200мс достаточно для UI и на порядок дешевле по CPU в
        // простое. При остановке делаем полный проход обязательно, чтобы
        // финальные значения дошли до оболочки.
        let slow_tick = tick % DSP_SLOW_TICK_EVERY == 0 || stopping;
        tick = tick.wrapping_add(1);

        // 0. Горячее применение настроек: перечитываем общий блок и проталкиваем
        // интервалы/тишину в координатор, а пороги — в каждый VAD.
        if slow_tick {
            let rp = runtime.lock().clone();
            coord.set_params(rp.min_interval_s, rp.max_interval_s, rp.silence_cut_ms);
            for ch in &mut channels {
                ch.vad.set_threshold(rp.silero_threshold, rp.rms_fallback);
            }
        }

        // 1. Drain rings, frame at 30ms, run VAD, report silence.
        for ch in &mut channels {
            scratch.clear();
            ch.consumer.drain_into(&mut scratch);
            if !scratch.is_empty() {
                ch.partial.extend_from_slice(&scratch);
            }
            while ch.partial.len() >= FRAME_SAMPLES {
                let frame: Vec<i16> = ch.partial.drain(..FRAME_SAMPLES).collect();
                let speech = ch.vad.is_speech(&frame);
                ch.buffer.extend_from_slice(&frame);
                ch.speech_flags.push(speech);
                coord.report_silence(&ch.id, !speech, mono_now);
            }
            if slow_tick {
                let dropped = ch.consumer.dropped();
                // Проход по флагам кадров — O(длина интервала) (до 10к кадров),
                // поэтому только на медленном тике.
                let speech_secs = ch.speech_flags.iter().filter(|&&s| s).count() as f32
                    * (crate::vad::FRAME_MS as f32 / 1000.0);
                // NB: не репортим длину буфера интервала как queue_size — это
                // сырые сэмплы (миллионы) и читаются в UI как бессмысленное
                // «N в очереди». Глубина очереди — через set_queue_depth.
                metrics.update_source(
                    &ch.id,
                    SourcePatch {
                        dropped_chunks: Some(dropped),
                        speech_seconds: Some(speech_secs),
                        ..Default::default()
                    },
                );
            }
        }

        // 2. Check for a cut.
        if let Some(cut) = coord.check_cut(mono_now) {
            let job = slice_interval(&mut channels, cut.sample_offset, cut.start_at, cut.end_at);
            if !try_enqueue_job(
                &tx,
                AsrMsg::Interval(job),
                &stop,
                &queue_stats,
                &events,
                mono_now,
                &mut last_queue_error_mono,
                false,
            ) {
                stop.store(true, Ordering::Release);
                break;
            }
        }

        if slow_tick {
            // Реальная глубина очереди ожидающих транскрибации интервалов.
            metrics.set_queue_depth(tx.len() as u32, cfg.bg_queue_size);
            metrics.set_dropped_intervals(
                queue_stats
                    .dropped_jobs
                    .load(Ordering::Relaxed)
                    .min(u32::MAX as u64) as u32,
            );

            // 3. Surface current interval info to metrics.
            let info = coord.current_interval_info(mono_now);
            let start_rfc = match &cached_start {
                Some((dt, s)) if *dt == info.start_at => s.clone(),
                _ => {
                    let s = info.start_at.to_rfc3339();
                    cached_start = Some((info.start_at, s.clone()));
                    s
                }
            };
            metrics.update_current_interval(&start_rfc, info.elapsed_s as f32, info.all_silent);
        }

        if stopping {
            // Flush the tail and exit.
            if let Some(cut) = coord.flush_current(mono_now) {
                let job =
                    slice_interval(&mut channels, cut.sample_offset, cut.start_at, cut.end_at);
                // Хвост ставим в очередь даже при выставленном stop: воркер
                // штатно дорабатывает всё, что уже накоплено. Потеря возможна
                // только при переполненной очереди — по той же политике учёта.
                let _ = try_enqueue_job(
                    &tx,
                    AsrMsg::Tail(job),
                    &stop,
                    &queue_stats,
                    &events,
                    mono_now,
                    &mut last_queue_error_mono,
                    true,
                );
            }
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    // Signal the ASR worker to finish. Полная очередь — не проблема: воркер
    // всё равно увидит Disconnected, когда этот tx уйдёт вместе с потоком.
    let _ = tx.try_send(AsrMsg::Finish);
}

/// Slice each channel buffer at `offset`, returning the completed audio and
/// keeping the remainder for the next interval (ported `split_buffer`).
fn slice_interval(
    channels: &mut [ChannelDsp],
    offset: usize,
    start_at: chrono::DateTime<chrono::Local>,
    end_at: chrono::DateTime<chrono::Local>,
) -> IntervalJob {
    let mut chunks = HashMap::new();
    for ch in channels.iter_mut() {
        let cut = offset.min(ch.buffer.len());
        let completed: Vec<i16> = ch.buffer.drain(..cut).collect();
        // Trim the matching prefix of frame flags.
        let frame_off = (cut / FRAME_SAMPLES).min(ch.speech_flags.len());
        ch.speech_flags.drain(..frame_off);
        chunks.insert(ch.id.clone(), completed);
    }
    (start_at, end_at, chunks)
}

// ---------------------------------------------------------------------------
// ASR worker thread
// ---------------------------------------------------------------------------

/// Рабочий поток транскрибации.
///
/// Семантика остановки (продуктовое решение): штатный `stop` НЕ отбрасывает
/// работу — интервалы, уже стоящие в очереди, это записанная речь
/// пользователя, и её вместе с хвостом нужно довести до хранилища. Выход
/// происходит по `Finish`/Disconnected, то есть после того, как DSP завершился
/// и очередь опустела. Единственный путь потерять backlog — `abort`, который
/// `stop()` ставит только по дедлайну (зависший нативный вызов).
#[allow(clippy::too_many_arguments)]
fn asr_loop(
    rx: crossbeam_channel::Receiver<AsrMsg>,
    backend: Arc<Mutex<Option<Box<dyn AsrBackend>>>>,
    runtime: Arc<Mutex<RuntimeParams>>,
    metrics: Arc<Metrics>,
    events: EventBus,
    abort: Arc<AtomicBool>,
    asr_done: Arc<AtomicBool>,
    queue_stats: Arc<QueueStats>,
    cfg: CoreConfig,
    #[cfg(feature = "store")] store: Arc<Store>,
) {
    // Ограничение: вызов native AsrBackend не имеет cancellation API. Если
    // sherpa/whisper зависнет внутри C/C++, Rust перестанет выдавать новые
    // jobs, но не может безопасно убить этот поток; `stop()` поэтому умеет
    // сдаться по таймауту и отсоединить его.
    loop {
        if abort.load(Ordering::Acquire) {
            break;
        }
        // Ограниченный таймаут нужен, чтобы заметить `abort`, пока мы ждём
        // очередной интервал.
        let msg = match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(msg) => msg,
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => continue,
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        };
        let (start_dt, end_dt, chunks) = match msg {
            AsrMsg::Finish => break,
            AsrMsg::Interval(job) | AsrMsg::Tail(job) => job,
        };
        // Глубина очереди при остановке продолжает жить: DSP уже вышел, а UI
        // должен видеть, сколько интервалов осталось дообработать.
        metrics.set_queue_depth(rx.len() as u32, cfg.bg_queue_size);
        // Rust-паника при обработке ОДНОГО интервала не должна убивать воркер
        // (иначе транскрипция молча стоит до рестарта сессии): ловим, репортим
        // событием Error (панику в лог пишет и хук diag.rs) и живём дальше.
        // C++ abort из ONNX Runtime это не ловит — его закрывает diag.rs.
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            // Защитный autorelease-пул на КАЖДЫЙ интервал: если когда-нибудь будет
            // выбран CoreML-провайдер, его autoreleased ObjC-объекты сливаются здесь,
            // а не копятся на этом не-Cocoa потоке. На не-Apple платформах — no-op.
            let _arpool = autorelease_pool();
            let duration_s = (end_dt - start_dt).num_milliseconds() as f64 / 1000.0;
            // Горячий язык: перечитываем на КАЖДОМ интервале (а не снимок старта).
            let language = runtime.lock().language.clone();
            let mut channel_texts: Vec<ChannelText> = Vec::new();

            for (channel_id, audio) in &chunks {
                if audio.is_empty() {
                    continue;
                }
                metrics.update_source(
                    channel_id,
                    SourcePatch {
                        busy: Some(true),
                        status: Some("processing".into()),
                        ..Default::default()
                    },
                );
                let audio_secs = audio.len() as f32 / TARGET_SAMPLE_RATE as f32;
                let t0 = Instant::now();
                let (text, stats) = {
                    let mut guard = backend.lock();
                    match guard.as_mut() {
                        Some(b) => transcribe_audio(b.as_mut(), audio, &language),
                        None => (String::new(), TranscribeStats::default()),
                    }
                };
                // Сбой ASR на чанках раньше проглатывался молча (интервал просто
                // терял текст) — теперь UI узнаёт через событие Error. Одно событие
                // на канал за интервал — спама нет (интервалы ≥10с).
                if stats.failed_chunks > 0 {
                    events.emit(CoreEvent::Error {
                        code: ErrorCode::Backend,
                        message: format!(
                            "ASR failed on {}/{} chunks (channel {channel_id}); see logs/core.log",
                            stats.failed_chunks, stats.total_chunks
                        ),
                    });
                }
                let proc_secs = t0.elapsed().as_secs_f32();
                metrics.record_processing(channel_id, audio_secs, proc_secs);
                let words = count_words(&text);
                metrics.update_source(
                    channel_id,
                    SourcePatch {
                        busy: Some(false),
                        status: Some("listening".into()),
                        last_text: Some(text.chars().take(200).collect()),
                        words_add: Some(words),
                        ..Default::default()
                    },
                );
                if words > 0 {
                    #[cfg(feature = "store")]
                    let _ = store.log_voice_event(channel_id, &start_dt.to_rfc3339());
                    events.emit(CoreEvent::VoiceActivity {
                        channel_id: channel_id.clone(),
                        at: start_dt.to_rfc3339(),
                    });
                }
                channel_texts.push(ChannelText {
                    channel_id: channel_id.clone(),
                    text,
                    words,
                    language: language_label(&language),
                });
            }

            let total_words: u32 = channel_texts.iter().map(|c| c.words).sum();
            metrics.record_interval(total_words);

            #[cfg(feature = "store")]
            {
                match store.write_interval(
                    &start_dt.to_rfc3339(),
                    &end_dt.to_rfc3339(),
                    duration_s,
                    &channel_texts,
                ) {
                    Ok(id) => {
                        events.emit(CoreEvent::IntervalCommitted {
                            interval: IntervalRecord {
                                id,
                                start_at: start_dt.to_rfc3339(),
                                end_at: end_dt.to_rfc3339(),
                                duration_s,
                                channels: channel_texts,
                            },
                        });
                    }
                    Err(e) => events.emit(CoreEvent::Error {
                        code: e.code(),
                        message: e.to_string(),
                    }),
                }
            }
            #[cfg(not(feature = "store"))]
            {
                events.emit(CoreEvent::IntervalCommitted {
                    interval: IntervalRecord {
                        id: 0,
                        start_at: start_dt.to_rfc3339(),
                        end_at: end_dt.to_rfc3339(),
                        duration_s,
                        channels: channel_texts,
                    },
                });
            }
        })); // catch_unwind
        if let Err(panic) = outcome {
            // Источники могли остаться в "processing" — вернуть в рабочее состояние.
            for channel_id in chunks.keys() {
                metrics.update_source(
                    channel_id,
                    SourcePatch {
                        busy: Some(false),
                        status: Some("listening".into()),
                        ..Default::default()
                    },
                );
            }
            events.emit(CoreEvent::Error {
                code: ErrorCode::Internal,
                message: format!(
                    "ASR worker panicked: {}; interval dropped, worker continues",
                    panic_message(&panic)
                ),
            });
        }
    }

    // Прерванная остановка: всё, что осталось в очереди, потеряно. Сообщаем
    // ОДНИМ событием с числом интервалов — иначе потеря выглядит как «просто
    // тишина». При штатном завершении очередь уже пуста и события нет.
    let discarded = rx
        .try_iter()
        .filter(|msg| !matches!(msg, AsrMsg::Finish))
        .count();
    if discarded > 0 {
        let total = queue_stats
            .dropped_jobs
            .fetch_add(discarded as u64, Ordering::Relaxed)
            + discarded as u64;
        metrics.set_dropped_intervals(total.min(u32::MAX as u64) as u32);
        events.emit(CoreEvent::Error {
            code: ErrorCode::Internal,
            message: format!(
                "остановка прервана по таймауту: {discarded} интервал(ов) не транскрибировано"
            ),
        });
    }
    metrics.set_queue_depth(0, cfg.bg_queue_size);
    asr_done.store(true, Ordering::Release);
}

/// Best-effort human-readable payload of a caught panic.
fn panic_message(panic: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = panic.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = panic.downcast_ref::<String>() {
        s.clone()
    } else {
        "<non-string panic payload>".to_string()
    }
}

/// Учёт сбоев ASR по чанкам одного канала за интервал: раньше ошибка
/// `transcribe_once` молча съедала текст чанка, и снаружи это было неотличимо
/// от тишины.
#[derive(Debug, Default, Clone, Copy)]
struct TranscribeStats {
    /// Non-silent chunks attempted.
    total_chunks: u32,
    /// Chunks where the backend returned an error (for multi-candidate — where
    /// ALL candidates errored).
    failed_chunks: u32,
    /// Internal count of non-silent tails shorter than
    /// [`MIN_ASR_AUDIO_SAMPLES`].  These are expected input loss at an
    /// interval boundary, not backend failures, and therefore do not
    /// contribute to `total_chunks` or public error/metrics events.
    skipped_chunks: u32,
}

/// Transcribe one interval's audio for a channel: 30s chunks, whisper
/// multi-candidate language pick (ported `_transcribe_audio_chunk`).
fn transcribe_audio(
    backend: &mut dyn AsrBackend,
    audio: &[i16],
    language: &LanguageMode,
) -> (String, TranscribeStats) {
    let multi = backend.supports_multi_candidate();
    let mut parts: Vec<String> = Vec::new();
    let mut stats = TranscribeStats::default();
    for chunk in audio.chunks(TRANSCRIBE_CHUNK_SAMPLES) {
        if chunk.is_empty() || chunk.iter().all(|&s| s == 0) {
            continue;
        }
        // A VAD cut can leave a short, non-zero tail.  Do not even construct a
        // backend input for it: sherpa/ORT may reduce this to a zero-length
        // feature axis and abort outside Rust's unwind boundary.  The tail is
        // tracked separately for the worker's internal accounting/tests; this
        // round intentionally does not add a public telemetry field or event.
        if chunk.len() < MIN_ASR_AUDIO_SAMPLES {
            stats.skipped_chunks += 1;
            continue;
        }
        let f32buf: Vec<f32> = chunk.iter().map(|&s| s as f32 / 32768.0).collect();
        // Reuse the backend boundary predicate after normalization so every
        // path shares the same floor and finite-value contract.  i16 input is
        // finite by construction, but keeping this check here prevents future
        // conversion changes from bypassing the native-runtime guard.
        if !is_safe_asr_audio(&f32buf) {
            stats.skipped_chunks += 1;
            continue;
        }
        stats.total_chunks += 1;

        let best = match language {
            LanguageMode::Fixed { code } => {
                run_one(backend, &f32buf, Some(code), &mut stats.failed_chunks)
            }
            LanguageMode::Auto if multi => run_candidates(
                backend,
                &f32buf,
                &["__auto__", "ru", "en"],
                &mut stats.failed_chunks,
            ),
            LanguageMode::Candidates { codes } if multi => {
                let refs: Vec<&str> = codes.iter().map(|s| s.as_str()).collect();
                run_candidates(backend, &f32buf, &refs, &mut stats.failed_chunks)
            }
            _ => run_one(backend, &f32buf, None, &mut stats.failed_chunks),
        };
        if let Some(t) = best {
            if !t.is_empty() {
                parts.push(t);
            }
        }
    }
    (parts.join(" "), stats)
}

fn run_one(
    backend: &mut dyn AsrBackend,
    audio: &[f32],
    lang: Option<&str>,
    failed: &mut u32,
) -> Option<String> {
    match backend.transcribe_once(audio, lang) {
        Ok(r) => {
            let t = clean_transcribed_text(&r.text);
            if t.is_empty() {
                None
            } else {
                Some(t)
            }
        }
        Err(_) => {
            *failed += 1;
            None
        }
    }
}

fn run_candidates(
    backend: &mut dyn AsrBackend,
    audio: &[f32],
    codes: &[&str],
    failed: &mut u32,
) -> Option<String> {
    let mut cands = Vec::new();
    let mut errors: u32 = 0;
    for &code in codes {
        let (lang, is_auto) = if code == "__auto__" {
            (None, true)
        } else {
            (Some(code), false)
        };
        match backend.transcribe_once(audio, lang) {
            Ok(r) => cands.push(Candidate {
                text: clean_transcribed_text(&r.text),
                language: r.language.or_else(|| lang.map(|s| s.to_string())),
                is_auto,
            }),
            Err(_) => errors += 1,
        }
    }
    // Чанк считается сбойным, только если НИ ОДИН кандидат не отработал.
    if !codes.is_empty() && errors as usize == codes.len() {
        *failed += 1;
    }
    pick_best_candidate(&cands).map(|c| c.text)
}

fn language_label(mode: &LanguageMode) -> String {
    match mode {
        LanguageMode::Auto => "auto".into(),
        LanguageMode::Fixed { code } => code.clone(),
        LanguageMode::Candidates { .. } => "auto".into(),
    }
}

/// Открывает Cocoa autorelease-пул и закрывает его при Drop (Apple-платформы).
/// На прочих ОС — пустой no-op guard, чтобы код компилировался везде.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn autorelease_pool() -> ArPool {
    ArPool(unsafe { objc_autoreleasePoolPush() })
}
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn autorelease_pool() -> ArPool {
    ArPool
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
#[link(name = "objc")]
extern "C" {
    fn objc_autoreleasePoolPush() -> *mut std::os::raw::c_void;
    fn objc_autoreleasePoolPop(pool: *mut std::os::raw::c_void);
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
struct ArPool(*mut std::os::raw::c_void);
#[cfg(any(target_os = "macos", target_os = "ios"))]
impl Drop for ArPool {
    fn drop(&mut self) {
        unsafe { objc_autoreleasePoolPop(self.0) }
    }
}
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
struct ArPool;

// ---------------------------------------------------------------------------
// Behavior tests: ASR failure visibility + worker panic resilience
// ---------------------------------------------------------------------------

#[cfg(all(test, feature = "store"))]
mod worker_tests {
    use super::*;
    use crate::asr::AsrResult;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering as AtomicOrdering};
    use std::sync::Mutex as StdMutex;

    /// Backend that always errors — every non-silent chunk must be counted.
    struct FailingBackend;
    impl AsrBackend for FailingBackend {
        fn transcribe_once(
            &mut self,
            _a: &[f32],
            _l: Option<&str>,
        ) -> Result<AsrResult, CoreError> {
            Err(CoreError::Backend("boom".into()))
        }
        fn supports_multi_candidate(&self) -> bool {
            false
        }
    }

    /// Backend that panics — the worker itself must survive.
    struct PanickyBackend;
    impl AsrBackend for PanickyBackend {
        fn transcribe_once(
            &mut self,
            _a: &[f32],
            _l: Option<&str>,
        ) -> Result<AsrResult, CoreError> {
            panic!("synthetic backend panic");
        }
        fn supports_multi_candidate(&self) -> bool {
            false
        }
    }

    /// Spy backend used to assert the pipeline's input contract without
    /// loading a native model.  It returns one stable word for each call.
    struct SpyBackend {
        calls: Arc<AtomicUsize>,
    }

    impl AsrBackend for SpyBackend {
        fn transcribe_once(
            &mut self,
            _a: &[f32],
            _l: Option<&str>,
        ) -> Result<AsrResult, CoreError> {
            self.calls.fetch_add(1, AtomicOrdering::SeqCst);
            Ok(AsrResult {
                text: "speech".into(),
                ..Default::default()
            })
        }

        fn supports_multi_candidate(&self) -> bool {
            false
        }
    }

    /// Медленный backend с управляемым барьером.  Нужен для проверки, что
    /// остановка отбрасывает очередь после текущего native-вызова, а не ждёт
    /// её последовательного опустошения.
    struct GateBackend {
        entered: Arc<AtomicBool>,
        release: Arc<AtomicBool>,
        calls: Arc<AtomicUsize>,
    }

    impl AsrBackend for GateBackend {
        fn transcribe_once(
            &mut self,
            _a: &[f32],
            _l: Option<&str>,
        ) -> Result<AsrResult, CoreError> {
            self.calls.fetch_add(1, AtomicOrdering::SeqCst);
            self.entered.store(true, AtomicOrdering::Release);
            while !self.release.load(AtomicOrdering::Acquire) {
                std::thread::sleep(Duration::from_millis(1));
            }
            Ok(AsrResult {
                text: "speech".into(),
                ..Default::default()
            })
        }

        fn supports_multi_candidate(&self) -> bool {
            false
        }
    }

    struct Recorder(std::sync::Arc<StdMutex<Vec<CoreEvent>>>);
    impl CoreEventListener for Recorder {
        fn on_event(&self, event: CoreEvent) {
            self.0.lock().unwrap().push(event);
        }
    }

    fn one_second_audio() -> Vec<i16> {
        (0..16_000)
            .map(|n| if n % 2 == 0 { 1000 } else { -1000 })
            .collect()
    }

    fn wait_until(flag: &AtomicBool) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !flag.load(AtomicOrdering::Acquire) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(
            flag.load(AtomicOrdering::Acquire),
            "test backend did not start"
        );
    }

    fn run_loop_with_store(
        backend: Box<dyn AsrBackend>,
        jobs: Vec<IntervalJob>,
    ) -> (Vec<CoreEvent>, Arc<Store>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let cfg = crate::config::default_config(
            dir.path().to_string_lossy(),
            dir.path().join("models").to_string_lossy(),
        );
        let store = Arc::new(Store::open(&format!("{}/t.sqlite", dir.path().display())).unwrap());
        let events = EventBus::new();
        let log = std::sync::Arc::new(StdMutex::new(Vec::new()));
        events.set_listener(Box::new(Recorder(log.clone())));

        let (tx, rx) = crossbeam_channel::bounded::<AsrMsg>(8);
        for j in jobs {
            tx.send(AsrMsg::Interval(j)).unwrap();
        }
        tx.send(AsrMsg::Finish).unwrap(); // graceful stop

        asr_loop(
            rx,
            Arc::new(Mutex::new(Some(backend))),
            Arc::new(Mutex::new(RuntimeParams::from_config(&cfg))),
            Arc::new(Metrics::new()),
            events,
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicBool::new(false)),
            Arc::new(QueueStats::default()),
            cfg,
            store.clone(),
        );
        let out = log.lock().unwrap().clone();
        (out, store, dir)
    }

    fn run_loop_with(backend: Box<dyn AsrBackend>, jobs: Vec<IntervalJob>) -> Vec<CoreEvent> {
        let (events, _store, _dir) = run_loop_with_store(backend, jobs);
        events
    }

    fn job() -> IntervalJob {
        let start = chrono::Local::now();
        let end = start + chrono::Duration::seconds(1);
        let mut chunks = HashMap::new();
        chunks.insert("mic".to_string(), one_second_audio());
        (start, end, chunks)
    }

    #[test]
    fn full_asr_queue_drops_without_blocking_and_rate_limits_errors() {
        let (tx, _rx) = crossbeam_channel::bounded::<AsrMsg>(1);
        tx.try_send(AsrMsg::Interval(job())).unwrap();
        let stats = QueueStats::default();
        let events = EventBus::new();
        let log = Arc::new(StdMutex::new(Vec::new()));
        events.set_listener(Box::new(Recorder(log.clone())));
        let stop = AtomicBool::new(false);
        let mut last_error = f64::NEG_INFINITY;

        // All calls return immediately despite the full queue.  Errors are
        // emitted once initially and once after the 30s rate-limit window.
        for now in [0.0, 1.0, 31.0] {
            assert!(try_enqueue_job(
                &tx,
                AsrMsg::Interval(job()),
                &stop,
                &stats,
                &events,
                now,
                &mut last_error,
                false,
            ));
        }
        assert_eq!(stats.dropped_jobs.load(AtomicOrdering::Relaxed), 3);
        assert_eq!(tx.len(), 1, "the original queued interval remains intact");
        let errors = log
            .lock()
            .unwrap()
            .iter()
            .filter(|event| matches!(event, CoreEvent::Error { .. }))
            .count();
        assert_eq!(errors, 2, "queue overload errors must be rate limited");
    }

    #[test]
    fn stop_tail_full_queue_uses_drop_accounting_and_error_policy() {
        let (tx, _rx) = crossbeam_channel::bounded::<AsrMsg>(1);
        tx.try_send(AsrMsg::Interval(job())).unwrap();
        let stats = QueueStats::default();
        let events = EventBus::new();
        let log = Arc::new(StdMutex::new(Vec::new()));
        events.set_listener(Box::new(Recorder(log.clone())));
        let stop = AtomicBool::new(true);
        let mut last_error = f64::NEG_INFINITY;

        // Tail delivery is allowed to attempt a nonblocking enqueue even after
        // stop.  A full queue must still increment the same counter and emit
        // the same rate-limited overload error as a regular interval.
        assert!(try_enqueue_job(
            &tx,
            AsrMsg::Tail(job()),
            &stop,
            &stats,
            &events,
            0.0,
            &mut last_error,
            true,
        ));
        assert_eq!(stats.dropped_jobs.load(AtomicOrdering::Relaxed), 1);
        assert_eq!(
            log.lock()
                .unwrap()
                .iter()
                .filter(|event| matches!(event, CoreEvent::Error { .. }))
                .count(),
            1
        );
    }

    #[test]
    fn disconnected_asr_receiver_reports_once_before_stop_is_set() {
        let (tx, rx) = crossbeam_channel::bounded::<AsrMsg>(1);
        drop(rx);
        let stats = QueueStats::default();
        let events = EventBus::new();
        let log = Arc::new(StdMutex::new(Vec::new()));
        events.set_listener(Box::new(Recorder(log.clone())));
        let stop = AtomicBool::new(false);
        let mut last_error = f64::NEG_INFINITY;

        assert!(!try_enqueue_job(
            &tx,
            AsrMsg::Interval(job()),
            &stop,
            &stats,
            &events,
            0.0,
            &mut last_error,
            false,
        ));
        assert!(
            !stop.load(AtomicOrdering::Acquire),
            "the disconnect error must be emitted before DSP sets stop"
        );
        // A second failed enqueue cannot create an event storm.
        assert!(!try_enqueue_job(
            &tx,
            AsrMsg::Interval(job()),
            &stop,
            &stats,
            &events,
            1.0,
            &mut last_error,
            false,
        ));

        let errors = log.lock().unwrap();
        assert_eq!(errors.len(), 2);
        assert!(matches!(
            &errors[0],
            CoreEvent::Error { code: ErrorCode::Internal, message }
                if message.contains("ASR worker disconnected")
        ));
        assert!(matches!(
            &errors[1],
            CoreEvent::StateChanged {
                state: SessionState::Error
            }
        ));
        drop(errors);
        stop.store(true, AtomicOrdering::Release);
    }

    #[test]
    fn dsp_keeps_draining_when_asr_queue_is_full() {
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = crate::config::default_config(
            dir.path().to_string_lossy(),
            dir.path().join("models").to_string_lossy(),
        );
        // Directly exercise the worker with a zero-length test coordinator so
        // several cuts happen in milliseconds rather than waiting 10 seconds
        // for the validated production minimum.
        cfg.min_interval_s = 0;
        cfg.max_interval_s = 0;
        cfg.silence_cut_ms = 2_000;

        let (mut producer, consumer) = crate::audio::ring::pcm_ring(8_192);
        let channels = vec![ChannelDsp {
            id: "mic".into(),
            consumer,
            vad: Box::new(crate::vad::RmsVad::new(&cfg.vad)),
            buffer: Vec::new(),
            partial: Vec::new(),
            speech_flags: Vec::new(),
        }];
        let runtime = Arc::new(Mutex::new(RuntimeParams::from_config(&cfg)));
        let metrics = Arc::new(Metrics::new());
        let events = EventBus::new();
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, _rx) = crossbeam_channel::bounded::<AsrMsg>(1);
        let queue_stats = Arc::new(QueueStats::default());
        let worker_queue_stats = queue_stats.clone();
        let health = Arc::new(DspHealth::new());
        let (done_tx, done_rx) = crossbeam_channel::bounded::<()>(1);

        let worker_stop = stop.clone();
        let worker = std::thread::spawn(move || {
            dsp_loop(
                channels,
                cfg,
                runtime,
                metrics.clone(),
                events,
                worker_stop,
                tx,
                worker_queue_stats,
                health,
            );
            let _ = done_tx.send(());
            metrics
        });

        // Keep producing while the queue is already full.  A blocking
        // Sender::send in DSP would prevent the stop signal from being
        // observed; try_send must let this test finish promptly.
        let producer_stop = stop.clone();
        let producer_thread = std::thread::spawn(move || {
            let frame = [1_000_i16; FRAME_SAMPLES];
            while !producer_stop.load(AtomicOrdering::Acquire) {
                producer.push_samples(&frame);
                std::thread::yield_now();
            }
            producer
        });
        std::thread::sleep(Duration::from_millis(100));
        stop.store(true, AtomicOrdering::Release);
        let _producer = producer_thread.join().expect("producer thread");
        assert!(
            done_rx.recv_timeout(Duration::from_secs(2)).is_ok(),
            "DSP must stop without waiting for a full ASR queue"
        );
        let metrics = worker.join().expect("DSP worker");
        assert!(
            queue_stats.dropped_jobs.load(AtomicOrdering::Relaxed) > 0,
            "full ASR queue should increment the internal drop counter"
        );
        assert!(
            metrics
                .snapshot()
                .sources
                .iter()
                .any(|source| source.speech_seconds > 0.0),
            "DSP should continue framing audio while ASR queue is full"
        );
    }

    /// Между интервалами не должно «застревать» аудио.
    ///
    /// Раньше следующий интервал начинался в момент СНЯТИЯ реза, а не в самом
    /// резе, поэтому ~`silence_cut_ms/2` аудио на каждый рез оставалось в
    /// буфере канала навсегда: эта речь не попадала ни в один интервал (и
    /// буфер рос ~1.9 МБ/ч на канал). Проверяем по сумме сэмплов: всё, что
    /// подали, обязано уехать в интервалы (последний — хвост при остановке).
    #[test]
    fn dsp_does_not_strand_audio_between_intervals() {
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = crate::config::default_config(
            dir.path().to_string_lossy(),
            dir.path().join("models").to_string_lossy(),
        );
        // Тестовая нарезка: минимума нет, режем по коротким паузам, чтобы
        // несколько резов уложились в секунды, а не в минуты.
        cfg.min_interval_s = 0;
        cfg.max_interval_s = 300;
        cfg.silence_cut_ms = 800;

        let (mut producer, consumer) = crate::audio::ring::pcm_ring(160_000);
        let channels = vec![ChannelDsp {
            id: "mic".into(),
            consumer,
            vad: Box::new(crate::vad::RmsVad::new(&cfg.vad)),
            buffer: Vec::new(),
            partial: Vec::new(),
            speech_flags: Vec::new(),
        }];
        let runtime = Arc::new(Mutex::new(RuntimeParams::from_config(&cfg)));
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = crossbeam_channel::bounded::<AsrMsg>(64);
        let worker_cfg = cfg.clone();
        let worker_stop = stop.clone();
        let worker = std::thread::spawn(move || {
            dsp_loop(
                channels,
                worker_cfg,
                runtime,
                Arc::new(Metrics::new()),
                EventBus::new(),
                worker_stop,
                tx,
                Arc::new(QueueStats::default()),
                Arc::new(DspHealth::new()),
            );
        });

        // Подаём аудио в РЕАЛЬНОМ времени (иначе смещения резов, считаемые по
        // часам, не сопоставимы с числом сэмплов): 3 цикла «речь/пауза».
        let mut pushed = 0usize;
        let speech = [6000_i16; FRAME_SAMPLES];
        let silence = [0_i16; FRAME_SAMPLES];
        for _ in 0..3 {
            for (frames, block) in [(7, &speech), (30, &silence)] {
                for _ in 0..frames {
                    producer.push_samples(block);
                    pushed += FRAME_SAMPLES;
                    std::thread::sleep(Duration::from_millis(30));
                }
            }
        }
        std::thread::sleep(Duration::from_millis(120));
        stop.store(true, AtomicOrdering::Release);
        worker.join().expect("DSP worker");

        let mut committed = 0usize;
        let mut intervals = 0usize;
        for msg in rx.try_iter() {
            match msg {
                AsrMsg::Interval(job) | AsrMsg::Tail(job) => {
                    intervals += 1;
                    committed += job.2.get("mic").map(|v| v.len()).unwrap_or(0);
                }
                AsrMsg::Finish => {}
            }
        }
        assert!(
            intervals >= 3,
            "ожидались резы по тишине, получено {intervals}"
        );
        assert!(committed <= pushed, "нарезано больше, чем подано");
        let stranded = pushed - committed;
        assert!(
            stranded <= TARGET_SAMPLE_RATE as usize / 2,
            "в буфере застряло {stranded} сэмплов (~{:.2}с) из {pushed}",
            stranded as f64 / TARGET_SAMPLE_RATE as f64
        );
    }

    #[test]
    fn dsp_health_reports_one_event_per_stall_and_no_idle_false_positive() {
        let health = DspHealth::with_timeout(Duration::from_millis(10));
        health.touch();
        std::thread::sleep(Duration::from_millis(20));
        assert!(health.stalled_event_due());
        assert!(!health.stalled_event_due(), "same stall must emit once");

        health.touch();
        assert!(
            !health.stalled_event_due(),
            "a resumed DSP clears the stall"
        );
    }

    /// Воркер на управляемом барьере: даёт остановить тест ровно в момент,
    /// когда нативный вызов ASR ещё не вернулся.
    struct GatedWorker {
        tx: crossbeam_channel::Sender<AsrMsg>,
        /// Взведён, когда backend вошёл в `transcribe_once`.
        entered: Arc<AtomicBool>,
        /// Отпускает backend из барьера.
        release: Arc<AtomicBool>,
        abort: Arc<AtomicBool>,
        asr_done: Arc<AtomicBool>,
        /// Сколько раз backend реально вызывался.
        calls: Arc<AtomicUsize>,
        worker: std::thread::JoinHandle<()>,
        _dir: tempfile::TempDir,
    }

    /// `prefill` кладётся в очередь ДО старта воркера — так тест точно знает
    /// глубину очереди в момент первого вызова backend'а.
    fn spawn_gated_worker(
        events: EventBus,
        metrics: Arc<Metrics>,
        queue_stats: Arc<QueueStats>,
        prefill: Vec<AsrMsg>,
    ) -> GatedWorker {
        let dir = tempfile::tempdir().unwrap();
        let cfg = crate::config::default_config(
            dir.path().to_string_lossy(),
            dir.path().join("models").to_string_lossy(),
        );
        let store = Arc::new(Store::open(&format!("{}/t.sqlite", dir.path().display())).unwrap());
        let entered = Arc::new(AtomicBool::new(false));
        let release = Arc::new(AtomicBool::new(false));
        let calls = Arc::new(AtomicUsize::new(0));
        let abort = Arc::new(AtomicBool::new(false));
        let asr_done = Arc::new(AtomicBool::new(false));
        let backend = GateBackend {
            entered: entered.clone(),
            release: release.clone(),
            calls: calls.clone(),
        };
        let (tx, rx) = crossbeam_channel::bounded::<AsrMsg>(8);
        for msg in prefill {
            tx.send(msg).unwrap();
        }
        let worker_abort = abort.clone();
        let worker_done = asr_done.clone();
        let worker = std::thread::spawn(move || {
            asr_loop(
                rx,
                Arc::new(Mutex::new(Some(Box::new(backend) as Box<dyn AsrBackend>))),
                Arc::new(Mutex::new(RuntimeParams::from_config(&cfg))),
                metrics,
                events,
                worker_abort,
                worker_done,
                queue_stats,
                cfg,
                store,
            )
        });
        GatedWorker {
            tx,
            entered,
            release,
            abort,
            asr_done,
            calls,
            worker,
            _dir: dir,
        }
    }

    /// Прерывание остановки (дедлайн `stop()`): воркер выходит сразу после
    /// текущего нативного вызова, а остаток очереди выбрасывается ОДНИМ
    /// событием с числом потерянных интервалов.
    #[test]
    fn abort_discards_queued_backlog_after_current_backend_call() {
        let events = EventBus::new();
        let log = Arc::new(StdMutex::new(Vec::new()));
        events.set_listener(Box::new(Recorder(log.clone())));
        let metrics = Arc::new(Metrics::new());
        let queue_stats = Arc::new(QueueStats::default());
        let w = spawn_gated_worker(events, metrics.clone(), queue_stats.clone(), Vec::new());

        w.tx.send(AsrMsg::Interval(job())).unwrap();
        wait_until(&w.entered);
        // Первый интервал внутри transcribe_once; ставим backlog, который
        // прерванная остановка обязана выбросить.
        for _ in 0..3 {
            w.tx.send(AsrMsg::Interval(job())).unwrap();
        }
        w.abort.store(true, AtomicOrdering::Release);
        w.release.store(true, AtomicOrdering::Release);
        drop(w.tx);
        w.worker
            .join()
            .expect("ASR worker must exit after current call");

        assert_eq!(w.calls.load(AtomicOrdering::SeqCst), 1);
        assert!(w.asr_done.load(AtomicOrdering::Acquire));
        assert_eq!(queue_stats.dropped_jobs.load(AtomicOrdering::Relaxed), 3);
        assert_eq!(metrics.snapshot().dropped_intervals, 3);
        let losses: Vec<String> = log
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                CoreEvent::Error { message, .. } if message.contains("не транскрибировано") => {
                    Some(message.clone())
                }
                _ => None,
            })
            .collect();
        assert_eq!(losses.len(), 1, "о потере сообщаем ровно один раз");
        assert!(
            losses[0].contains('3'),
            "видно, сколько потеряно: {losses:?}"
        );
    }

    /// Штатная остановка НЕ выбрасывает работу: и уже стоящие в очереди
    /// интервалы, и хвост должны быть транскрибированы и записаны.
    #[test]
    fn graceful_stop_transcribes_backlog_and_tail() {
        let events = EventBus::new();
        let log = Arc::new(StdMutex::new(Vec::new()));
        events.set_listener(Box::new(Recorder(log.clone())));
        let metrics = Arc::new(Metrics::new());
        let queue_stats = Arc::new(QueueStats::default());
        let w = spawn_gated_worker(events, metrics.clone(), queue_stats.clone(), Vec::new());

        w.tx.send(AsrMsg::Interval(job())).unwrap();
        wait_until(&w.entered);
        // Backlog + хвост приходят, пока воркер занят первым интервалом —
        // ровно та ситуация, в которой раньше терялась запись.
        w.tx.send(AsrMsg::Interval(job())).unwrap();
        w.tx.send(AsrMsg::Tail(job())).unwrap();
        w.tx.send(AsrMsg::Finish).unwrap();
        w.release.store(true, AtomicOrdering::Release);
        w.worker.join().expect("ASR worker must drain the queue");

        assert_eq!(
            w.calls.load(AtomicOrdering::SeqCst),
            3,
            "backlog и хвост обязаны быть транскрибированы"
        );
        assert!(w.asr_done.load(AtomicOrdering::Acquire));
        assert_eq!(queue_stats.dropped_jobs.load(AtomicOrdering::Relaxed), 0);
        assert_eq!(metrics.snapshot().dropped_intervals, 0);
        let committed = log
            .lock()
            .unwrap()
            .iter()
            .filter(|e| matches!(e, CoreEvent::IntervalCommitted { .. }))
            .count();
        assert_eq!(committed, 3);
    }

    /// Пока идёт остановка, UI должен видеть, сколько интервалов осталось:
    /// DSP уже вышел, поэтому глубину очереди публикует сам ASR-воркер.
    #[test]
    fn queue_depth_stays_visible_while_the_queue_drains() {
        let metrics = Arc::new(Metrics::new());
        let prefill = vec![
            AsrMsg::Interval(job()),
            AsrMsg::Interval(job()),
            AsrMsg::Interval(job()),
            AsrMsg::Tail(job()),
            AsrMsg::Finish,
        ];
        let w = spawn_gated_worker(
            EventBus::new(),
            metrics.clone(),
            Arc::new(QueueStats::default()),
            prefill,
        );

        // Воркер забрал первый интервал и стоит в backend'е: в очереди ровно
        // оставшиеся 4 сообщения (2 интервала + хвост + Finish).
        wait_until(&w.entered);
        assert_eq!(metrics.snapshot().bg_queue_depth, 4);

        w.release.store(true, AtomicOrdering::Release);
        w.worker.join().expect("worker");
        assert_eq!(w.calls.load(AtomicOrdering::SeqCst), 4);
        assert_eq!(
            metrics.snapshot().bg_queue_depth,
            0,
            "после остановки очередь пуста"
        );
    }

    /// `stop()` не должен висеть на join бесконечно: ожидание ограничено.
    #[test]
    fn worker_wait_gives_up_after_the_deadline() {
        let keep_running = Arc::new(AtomicBool::new(true));
        let flag = keep_running.clone();
        let handle = std::thread::spawn(move || {
            while flag.load(AtomicOrdering::Acquire) {
                std::thread::sleep(Duration::from_millis(1));
            }
        });
        let handles = vec![handle];

        let t0 = Instant::now();
        assert!(!wait_for_workers(&handles, Duration::from_millis(80)));
        assert!(t0.elapsed() < Duration::from_secs(2), "ожидание ограничено");

        keep_running.store(false, AtomicOrdering::Release);
        assert!(wait_for_workers(&handles, Duration::from_secs(2)));
        for h in handles {
            let _ = h.join();
        }
    }

    #[test]
    fn asr_chunk_failure_emits_backend_error_event() {
        let events = run_loop_with(Box::new(FailingBackend), vec![job()]);
        let err = events.iter().find_map(|e| match e {
            CoreEvent::Error { code, message } => Some((*code, message.clone())),
            _ => None,
        });
        let (code, message) = err.expect("chunk failure must surface as an Error event");
        assert!(matches!(code, ErrorCode::Backend));
        assert!(
            message.contains("ASR failed on 1/1 chunks"),
            "got: {message}"
        );
        // Интервал всё равно закоммичен (пустой текст) — пайплайн не встал.
        assert!(events
            .iter()
            .any(|e| matches!(e, CoreEvent::IntervalCommitted { .. })));
    }

    #[test]
    fn worker_survives_backend_panic_and_processes_next_interval() {
        // Первый интервал паникует; второй должен быть обработан тем же воркером.
        let events = run_loop_with(Box::new(PanickyBackend), vec![job(), job()]);
        let panics = events
            .iter()
            .filter(|e| matches!(e, CoreEvent::Error { code: ErrorCode::Internal, message } if message.contains("panicked")))
            .count();
        assert_eq!(
            panics, 2,
            "both intervals reported, i.e. the worker survived the first panic"
        );
    }

    #[test]
    fn transcribe_audio_counts_failed_chunks() {
        let mut b = FailingBackend;
        let (text, stats) = transcribe_audio(&mut b, &one_second_audio(), &LanguageMode::Auto);
        assert!(text.is_empty());
        assert_eq!(stats.total_chunks, 1);
        assert_eq!(stats.failed_chunks, 1);
    }

    #[test]
    fn short_nonzero_audio_is_skipped_without_backend_call() {
        let calls = Arc::new(AtomicUsize::new(0));
        let mut backend = SpyBackend {
            calls: calls.clone(),
        };
        let short = vec![1200_i16; MIN_ASR_AUDIO_SAMPLES - 1];

        let (text, stats) = transcribe_audio(&mut backend, &short, &LanguageMode::Auto);

        assert!(text.is_empty());
        assert_eq!(calls.load(AtomicOrdering::SeqCst), 0);
        assert_eq!(stats.total_chunks, 0);
        assert_eq!(stats.failed_chunks, 0);
        assert_eq!(stats.skipped_chunks, 1);
    }

    #[test]
    fn exact_minimum_audio_is_transcribed() {
        let calls = Arc::new(AtomicUsize::new(0));
        let mut backend = SpyBackend {
            calls: calls.clone(),
        };
        let exact = vec![1200_i16; MIN_ASR_AUDIO_SAMPLES];

        let (text, stats) = transcribe_audio(&mut backend, &exact, &LanguageMode::Auto);

        assert_eq!(text, "speech");
        assert_eq!(calls.load(AtomicOrdering::SeqCst), 1);
        assert_eq!(stats.total_chunks, 1);
        assert_eq!(stats.failed_chunks, 0);
        assert_eq!(stats.skipped_chunks, 0);
    }

    #[test]
    fn short_tail_after_full_chunk_is_not_sent_to_backend() {
        let calls = Arc::new(AtomicUsize::new(0));
        let mut backend = SpyBackend {
            calls: calls.clone(),
        };
        let mut audio = vec![1200_i16; TRANSCRIBE_CHUNK_SAMPLES];
        audio.extend(std::iter::repeat(1200_i16).take(MIN_ASR_AUDIO_SAMPLES - 1));

        let (text, stats) = transcribe_audio(&mut backend, &audio, &LanguageMode::Auto);

        assert_eq!(text, "speech");
        assert_eq!(calls.load(AtomicOrdering::SeqCst), 1);
        assert_eq!(stats.total_chunks, 1);
        assert_eq!(stats.failed_chunks, 0);
        assert_eq!(stats.skipped_chunks, 1);
    }

    #[test]
    fn multichannel_short_input_commits_interval_without_error_or_text() {
        let calls = Arc::new(AtomicUsize::new(0));
        let normal = one_second_audio();
        let short = vec![1200_i16; MIN_ASR_AUDIO_SAMPLES - 1];
        let start = chrono::Local::now();
        let end = start + chrono::Duration::seconds(1);
        let mut chunks = HashMap::new();
        chunks.insert("normal".to_string(), normal);
        chunks.insert("short".to_string(), short);

        let (events, store, _dir) = run_loop_with_store(
            Box::new(SpyBackend {
                calls: calls.clone(),
            }),
            vec![(start, end, chunks)],
        );

        // Exactly one native/backend request: the short channel was filtered
        // before dispatch, while the normal channel still produced text.
        assert_eq!(calls.load(AtomicOrdering::SeqCst), 1);
        assert!(!events.iter().any(|event| {
            matches!(
                event,
                CoreEvent::Error {
                    code: ErrorCode::Backend,
                    ..
                }
            )
        }));
        assert!(events
            .iter()
            .any(|event| matches!(event, CoreEvent::IntervalCommitted { .. })));
        assert!(events.iter().any(|event| {
            matches!(
                event,
                CoreEvent::VoiceActivity { channel_id, .. } if channel_id == "normal"
            )
        }));
        assert!(!events.iter().any(|event| {
            matches!(
                event,
                CoreEvent::VoiceActivity { channel_id, .. } if channel_id == "short"
            )
        }));

        let intervals = store
            .query_intervals("2000-01-01T00:00:00+00:00", "2100-01-01T00:00:00+00:00")
            .expect("query committed interval");
        assert_eq!(intervals.len(), 1);
        // The interval remains a two-channel record: the short channel is
        // represented as an empty text row rather than a backend failure.
        assert_eq!(intervals[0].channels.len(), 2);
        let normal_text = intervals[0]
            .channels
            .iter()
            .find(|channel| channel.channel_id == "normal")
            .expect("normal channel row");
        assert_eq!(normal_text.text, "speech");
        let short_text = intervals[0]
            .channels
            .iter()
            .find(|channel| channel.channel_id == "short")
            .expect("short channel row");
        assert!(short_text.text.is_empty());
        assert_eq!(short_text.words, 0);
    }

    #[test]
    fn push_audio_frame_rejects_invalid_capture_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = crate::config::default_config(
            dir.path().to_string_lossy(),
            dir.path().join("models").to_string_lossy(),
        );
        let log = Arc::new(StdMutex::new(Vec::new()));
        let core = TranscriberCore::new(cfg, Box::new(Recorder(log))).unwrap();

        // These calls must be harmless even before a recording session is
        // started; in particular, the zero sample rate must not reach a
        // division in the resampler and zero channels must not become mono.
        core.push_audio_frame("mic".into(), vec![1, 2], 0, 1);
        core.push_audio_frame("mic".into(), vec![1, 2], 16_000, 0);
    }

    /// Аварийные пути (паника DSP, потеря ASR-воркера, watchdog) закрывают
    /// сессию причиной `error`, и последующая штатная остановка её НЕ
    /// переписывает — иначе авария маскировалась бы обычным стопом.
    ///
    /// Проверяем сам учёт сессии, а не реальный watchdog: гонять зависший DSP
    /// в юнит-тесте пришлось бы десятками секунд.
    #[test]
    fn crash_path_closes_session_with_error_and_wins_over_user_stop() {
        let dir = tempfile::tempdir().unwrap();
        let store =
            Arc::new(Store::open(&format!("{}/sessions.sqlite", dir.path().display())).unwrap());

        let session = SessionLog::open(&store);
        assert!(session.is_some(), "сессия должна открыться");
        let open = store.last_sessions(1).unwrap();
        assert_eq!(open.len(), 1);
        assert!(
            open[0].ended_at.is_empty() && open[0].stop_reason.is_empty(),
            "пока запись идёт, сессия не закрыта: {:?}",
            open[0]
        );

        close_session(&session, SESSION_STOP_ERROR);
        close_session(&session, SESSION_STOP_USER);

        let got = store.last_sessions(1).unwrap();
        assert_eq!(got[0].stop_reason, SESSION_STOP_ERROR);
        assert!(!got[0].ended_at.is_empty(), "конец сессии записан");
    }

    /// Ошибка учёта сессии не должна ронять запись: `None` просто означает
    /// «сессия не учтена», а закрытие такого «ничего» — no-op.
    #[test]
    fn session_accounting_failure_is_not_fatal() {
        close_session(&None, SESSION_STOP_USER);
    }
}
