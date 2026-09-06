//! Thread-safe live metrics store. OWNER: module agent. Mirrors the legacy
//! `MetricsStore`/`SourceMetrics`. Internally guarded (parking_lot::Mutex);
//! all methods take &self.

use std::collections::HashMap;
use std::collections::VecDeque;
use std::time::Instant;

use chrono::Local;
use parking_lot::Mutex;

use crate::types::{MetricsSnapshot, SessionState, SourceMetrics};

/// Размер скользящего окна сэмплов CPU%. При тике ~1/с это примерно 2 минуты
/// истории, по которым считаем медиану и 90-й перцентиль.
const CPU_WINDOW: usize = 120;

/// Placeholder timestamp matching the legacy "—" sentinel used when a field
/// has no real value yet.
const NO_TS: &str = "\u{2014}";

fn iso_now() -> String {
    Local::now().to_rfc3339()
}

/// Internal, mutex-guarded state. Mirrors the Python `MetricsStore` fields plus
/// the snapshot-only system/queue/interval fields the Rust contract exposes.
struct State {
    running: bool,
    loading: bool,
    stopping: bool,
    model_loaded: bool,
    model_name: String,
    started_at: String,
    last_write_at: String,
    last_error: String,

    total_words: u32,
    total_intervals: u32,

    bg_queue_depth: u32,
    bg_queue_capacity: u32,
    /// Интервалы, потерянные за прогон (переполнение очереди / прерванная
    /// остановка). Видимость дропов для UI.
    dropped_intervals: u32,

    current_interval_elapsed_s: f32,
    current_interval_start_at: String,
    channels_silent: bool,

    /// Текущая загрузка CPU% (последний сэмпл).
    cpu_percent: f32,
    /// Текущий RSS процесса в байтах.
    memory_rss_bytes: u64,
    /// Пиковый RSS за окно/сессию в байтах.
    memory_rss_peak_bytes: u64,

    /// Скользящее окно последних сэмплов CPU% для расчёта перцентилей.
    cpu_window: VecDeque<f32>,
    /// Предыдущий сэмпл процессорного времени задачи и момент его снятия —
    /// нужны, чтобы вычислить CPU% как дельту процессорного времени, делённую
    /// на дельту реального времени. `None` до первого сэмпла.
    cpu_prev: Option<CpuSample>,

    /// Insertion order of channels, so snapshots are deterministic.
    order: Vec<String>,
    sources: HashMap<String, SourceMetrics>,
}

/// Снимок процессорного времени задачи (в секундах) и момент его снятия.
#[derive(Clone, Copy)]
struct CpuSample {
    /// Суммарное процессорное время (user + system) задачи в секундах.
    cpu_seconds: f64,
    /// Момент снятия сэмпла в монотонных часах.
    at: Instant,
}

impl State {
    fn new() -> Self {
        Self {
            running: false,
            loading: false,
            stopping: false,
            model_loaded: false,
            model_name: String::new(),
            started_at: iso_now(),
            last_write_at: NO_TS.to_string(),
            last_error: String::new(),
            total_words: 0,
            total_intervals: 0,
            bg_queue_depth: 0,
            bg_queue_capacity: 0,
            dropped_intervals: 0,
            current_interval_elapsed_s: 0.0,
            current_interval_start_at: NO_TS.to_string(),
            channels_silent: true,
            cpu_percent: 0.0,
            memory_rss_bytes: 0,
            memory_rss_peak_bytes: 0,
            cpu_window: VecDeque::with_capacity(CPU_WINDOW),
            cpu_prev: None,
            order: Vec::new(),
            sources: HashMap::new(),
        }
    }

    /// Get-or-create a channel entry, preserving insertion order.
    fn entry(&mut self, channel_id: &str) -> &mut SourceMetrics {
        if !self.sources.contains_key(channel_id) {
            self.order.push(channel_id.to_string());
            let src = SourceMetrics {
                channel_id: channel_id.to_string(),
                status: "idle".to_string(),
                ..Default::default()
            };
            self.sources.insert(channel_id.to_string(), src);
        }
        self.sources.get_mut(channel_id).expect("just inserted")
    }
}

pub struct Metrics {
    state: Mutex<State>,
}

impl Default for Metrics {
    fn default() -> Self {
        Self::new()
    }
}

impl Metrics {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(State::new()),
        }
    }

    /// Begin a fresh run: reset counters/timestamps but keep declared channels
    /// (preserving their `enabled` flag), mirroring the legacy reset.
    pub fn reset_for_run(&self, model_name: &str) {
        let mut s = self.state.lock();
        s.started_at = iso_now();
        s.last_write_at = NO_TS.to_string();
        s.last_error = String::new();
        s.model_name = model_name.to_string();
        s.stopping = false;
        s.model_loaded = false;
        s.total_words = 0;
        s.total_intervals = 0;
        s.bg_queue_depth = 0;
        s.dropped_intervals = 0;
        s.current_interval_elapsed_s = 0.0;
        s.current_interval_start_at = NO_TS.to_string();
        s.channels_silent = true;

        // Сбрасываем системные метрики и историю окна на старте нового прогона.
        s.cpu_percent = 0.0;
        s.memory_rss_bytes = 0;
        s.memory_rss_peak_bytes = 0;
        s.cpu_window.clear();
        s.cpu_prev = None;

        // Re-init each channel, preserving only its static config (enabled).
        let ids: Vec<String> = s.order.clone();
        for id in ids {
            let enabled = s.sources.get(&id).map(|c| c.enabled).unwrap_or(false);
            s.sources.insert(
                id.clone(),
                SourceMetrics {
                    channel_id: id,
                    enabled,
                    status: "idle".to_string(),
                    ..Default::default()
                },
            );
        }
    }

    pub fn set_running(&self, running: bool, loading: bool) {
        let mut s = self.state.lock();
        s.running = running;
        s.loading = loading;
        if running {
            s.stopping = false;
        }
    }

    pub fn set_model_loaded(&self) {
        let mut s = self.state.lock();
        s.model_loaded = true;
        s.loading = false;
    }

    pub fn set_stopping(&self, stopping: bool) {
        let mut s = self.state.lock();
        s.stopping = stopping;
    }

    pub fn set_error(&self, message: &str) {
        let mut s = self.state.lock();
        s.last_error = message.to_string();
        s.loading = false;
        s.running = false;
        s.stopping = false;
    }

    /// Declare/refresh a channel's static config.
    pub fn set_source(&self, channel_id: &str, enabled: bool, status: &str) {
        let mut s = self.state.lock();
        let src = s.entry(channel_id);
        src.enabled = enabled;
        src.status = status.to_string();
    }

    /// Update one channel's mutable fields (status/busy/queue/last_text/...).
    pub fn update_source(&self, channel_id: &str, patch: SourcePatch) {
        let mut s = self.state.lock();
        let src = s.entry(channel_id);
        if let Some(v) = patch.status {
            src.status = v;
        }
        if let Some(v) = patch.busy {
            src.busy = v;
        }
        if let Some(v) = patch.queue_size {
            src.queue_size = v;
        }
        if let Some(v) = patch.dropped_chunks {
            src.dropped_chunks = v;
        }
        if let Some(v) = patch.last_text {
            src.last_text = v;
        }
        if let Some(v) = patch.last_language {
            src.last_language = v;
        }
        if let Some(v) = patch.words_add {
            src.words = src.words.saturating_add(v);
        }
        if let Some(v) = patch.speech_seconds {
            src.speech_seconds = v;
        }
        if let Some(v) = patch.last_error {
            // Surface the most recent channel error globally too.
            s.last_error = v;
        }
    }

    /// Record one transcription's timing -> updates rtf/lag for the channel.
    pub fn record_processing(&self, channel_id: &str, audio_s: f32, proc_s: f32) {
        let mut s = self.state.lock();
        let src = s.entry(channel_id);
        src.last_rtf = if audio_s > 0.0 { proc_s / audio_s } else { 0.0 };
        src.lag_estimate_s = (proc_s - audio_s).max(0.0);
    }

    /// Record a committed interval (adds words, bumps counts, last_write_at).
    pub fn record_interval(&self, total_words: u32) {
        let mut s = self.state.lock();
        s.total_words = s.total_words.saturating_add(total_words);
        s.total_intervals = s.total_intervals.saturating_add(1);
        s.last_write_at = iso_now();
    }

    pub fn update_current_interval(&self, start_at: &str, elapsed_s: f32, all_silent: bool) {
        let mut s = self.state.lock();
        s.current_interval_start_at = start_at.to_string();
        s.current_interval_elapsed_s = elapsed_s;
        s.channels_silent = all_silent;
    }

    pub fn set_queue_depth(&self, depth: u32, capacity: u32) {
        let mut s = self.state.lock();
        s.bg_queue_depth = depth;
        s.bg_queue_capacity = capacity;
    }

    /// Число интервалов, потерянных за текущий прогон (монотонно растёт до
    /// `reset_for_run`). Источник истины — счётчик пайплайна.
    pub fn set_dropped_intervals(&self, dropped: u32) {
        let mut s = self.state.lock();
        s.dropped_intervals = dropped;
    }

    /// Снимает реальные системные метрики процесса (best-effort).
    ///
    /// Вызывается тикером примерно раз в секунду. На Apple-платформах читает RSS
    /// и суммарное процессорное время задачи через mach `task_info` (см.
    /// `platform::sample_process`). CPU% считается как дельта процессорного
    /// времени, делённая на дельту реального времени между вызовами (может быть
    /// >100% при многих потоках). Текущий CPU% кладётся в скользящее окно, по
    /// > которому пересчитываются медиана и 90-й перцентиль; RSS обновляет текущее
    /// > значение и пик. На прочих ОС (Android/Linux) — no-op (метрики не в
    /// > скоупе). Метод никогда не паникует.
    pub fn sample_system(&self) {
        // Снимаем сэмпл железа ВНЕ мьютекса: системные вызовы не должны держать
        // лок дольше необходимого.
        let raw = platform::sample_process();

        let mut s = self.state.lock();

        if let Some(rss) = raw.rss_bytes {
            s.memory_rss_bytes = rss;
            if rss > s.memory_rss_peak_bytes {
                s.memory_rss_peak_bytes = rss;
            }
        }

        // CPU% по дельте процессорного времени между соседними сэмплами.
        if let Some(cpu_seconds) = raw.cpu_seconds {
            let now = Instant::now();
            if let Some(prev) = s.cpu_prev {
                let wall = now.duration_since(prev.at).as_secs_f64();
                let cpu_delta = cpu_seconds - prev.cpu_seconds;
                // Защита от деления на ноль и от отрицательной дельты (например,
                // если кто-то сбросил состояние между вызовами).
                if wall > 0.0 && cpu_delta >= 0.0 {
                    let pct = (cpu_delta / wall * 100.0) as f32;
                    s.cpu_percent = pct;
                    push_window(&mut s.cpu_window, pct);
                }
            }
            s.cpu_prev = Some(CpuSample {
                cpu_seconds,
                at: now,
            });
        }
        // Перцентили p50/p90 считаются по окну лениво в `snapshot`; здесь нам
        // достаточно обновить текущий CPU% и пик RSS.
    }

    pub fn snapshot(&self) -> MetricsSnapshot {
        let s = self.state.lock();
        let sources: Vec<SourceMetrics> = s
            .order
            .iter()
            .filter_map(|id| s.sources.get(id).cloned())
            .collect();
        // Копируем окно CPU% и считаем перцентили чистой функцией.
        let cpu_window: Vec<f32> = s.cpu_window.iter().copied().collect();
        let cpu_p50 = percentile(&cpu_window, 50.0);
        let cpu_p90 = percentile(&cpu_window, 90.0);
        MetricsSnapshot {
            state_running: s.running,
            state_loading: s.loading,
            state_stopping: s.stopping,
            model_loaded: s.model_loaded,
            model_name: s.model_name.clone(),
            started_at: s.started_at.clone(),
            last_write_at: s.last_write_at.clone(),
            total_words: s.total_words,
            total_intervals: s.total_intervals,
            bg_queue_depth: s.bg_queue_depth,
            bg_queue_capacity: s.bg_queue_capacity,
            current_interval_elapsed_s: s.current_interval_elapsed_s,
            current_interval_start_at: s.current_interval_start_at.clone(),
            channels_silent: s.channels_silent,
            sources,
            cpu_percent: s.cpu_percent,
            cpu_p50,
            cpu_p90,
            memory_rss_bytes: s.memory_rss_bytes,
            memory_rss_peak_bytes: s.memory_rss_peak_bytes,
            last_error: s.last_error.clone(),
            dropped_intervals: s.dropped_intervals,
        }
    }

    pub fn source_snapshot(&self, channel_id: &str) -> Option<SourceMetrics> {
        let s = self.state.lock();
        s.sources.get(channel_id).cloned()
    }
}

/// Map the running/loading/stopping/error flags to a coarse `SessionState`.
/// Provided for callers that want an enum view; not stored directly.
#[allow(dead_code)]
fn derive_state(s: &State) -> SessionState {
    if !s.last_error.is_empty() {
        SessionState::Error
    } else if s.stopping {
        SessionState::Stopping
    } else if s.loading {
        SessionState::Loading
    } else if s.running {
        SessionState::Recording
    } else {
        SessionState::Idle
    }
}

/// Кладёт новый сэмпл в скользящее окно, вытесняя самый старый при переполнении.
fn push_window(window: &mut VecDeque<f32>, value: f32) {
    if window.len() == CPU_WINDOW {
        window.pop_front();
    }
    window.push_back(value);
}

/// Считает `p`-й перцентиль (0.0..=100.0) набора значений методом «nearest-rank».
///
/// Чистая функция: не зависит от состояния и не мутирует вход (работает по
/// копии). Для пустого набора возвращает 0.0. `p` зажимается в [0, 100].
fn percentile(values: &[f32], p: f32) -> f32 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted: Vec<f32> = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let p = p.clamp(0.0, 100.0);
    let n = sorted.len();
    // Nearest-rank: rank = ceil(p/100 * n), индекс = rank - 1, зажат в границы.
    let rank = (p / 100.0 * n as f32).ceil() as usize;
    let idx = rank.saturating_sub(1).min(n - 1);
    sorted[idx]
}

/// Текущий RSS процесса в байтах (best-effort, Apple-платформы). `None`, если
/// платформа не поддерживается или снять не удалось. Публично — используется в
/// тестах расхода памяти и во внешней диагностике.
pub fn process_rss_bytes() -> Option<u64> {
    platform::sample_process().rss_bytes
}

/// Платформенный слой снятия сырых метрик процесса.
mod platform {
    /// Сырой сэмпл: RSS в байтах и суммарное процессорное время задачи в
    /// секундах. `None` означает «не удалось снять» (или платформа не
    /// поддерживается) — вызывающий просто оставляет прежние значения.
    pub struct ProcessSample {
        pub rss_bytes: Option<u64>,
        pub cpu_seconds: Option<f64>,
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    pub fn sample_process() -> ProcessSample {
        apple::sample_process()
    }

    /// Best-effort заглушка для прочих ОС (Android/Linux): метрики не в скоупе.
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    pub fn sample_process() -> ProcessSample {
        ProcessSample {
            rss_bytes: None,
            cpu_seconds: None,
        }
    }

    /// Реализация для Apple-платформ через mach `task_info`.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    mod apple {
        use super::ProcessSample;
        use std::os::raw::{c_int, c_uint};

        // --- Сырые объявления mach C-API ---------------------------------
        // Описываем ровно то, что используем, чтобы не тянуть тяжёлый крейт.

        // mach_port_t — это просто 32-битный целочисленный идентификатор порта.
        type MachPortT = c_uint;
        // Тип «вкуса» (flavor) и счётчика для task_info.
        type TaskFlavorT = c_uint;
        type MachMsgTypeNumberT = c_uint;
        type KernReturnT = c_int;

        // Константы вкусов task_info из <mach/task_info.h>.
        const MACH_TASK_BASIC_INFO: TaskFlavorT = 20;
        const TASK_THREAD_TIMES_INFO: TaskFlavorT = 3;
        const KERN_SUCCESS: KernReturnT = 0;

        /// mach_task_basic_info — даёт resident_size (RSS) задачи.
        /// Раскладка соответствует <mach/task_info.h>.
        #[repr(C)]
        #[derive(Default)]
        struct MachTaskBasicInfo {
            virtual_size: u64,
            resident_size: u64,
            resident_size_max: u64,
            user_time: TimeValue,
            system_time: TimeValue,
            policy: c_int,
            suspend_count: c_int,
        }

        /// time_value_t: секунды + микросекунды.
        #[repr(C)]
        #[derive(Default, Clone, Copy)]
        struct TimeValue {
            seconds: c_int,
            microseconds: c_int,
        }

        /// task_thread_times_info — процессорное время ЖИВЫХ потоков задачи
        /// (user + system). Вместе с накопленным временем завершённых потоков
        /// из basic_info это и есть суммарное процессорное время процесса.
        #[repr(C)]
        #[derive(Default)]
        struct TaskThreadTimesInfo {
            user_time: TimeValue,
            system_time: TimeValue,
        }

        extern "C" {
            /// Возвращает send-right на порт задачи текущего процесса.
            fn mach_task_self() -> MachPortT;
            /// Заполняет буфер `task_info_out` информацией о задаче.
            fn task_info(
                target_task: MachPortT,
                flavor: TaskFlavorT,
                task_info_out: *mut c_int,
                task_info_count: *mut MachMsgTypeNumberT,
            ) -> KernReturnT;
        }

        /// Переводит time_value_t в секунды (f64).
        fn tv_secs(tv: TimeValue) -> f64 {
            tv.seconds as f64 + tv.microseconds as f64 / 1_000_000.0
        }

        pub fn sample_process() -> ProcessSample {
            // SAFETY: вызываем mach `task_info` для собственной задачи.
            // `mach_task_self()` всегда валиден для текущего процесса. Передаём
            // указатель на корректно выровненную структуру и счётчик в единицах
            // c_int (натуральных словах), как требует ABI mach. task_info не
            // освобождает и не сохраняет наши указатели, пишет ровно
            // `*count * sizeof(c_int)` байт в буфер; мы выделяем достаточно.
            unsafe {
                let task = mach_task_self();

                // --- RSS из basic_info ---
                let mut basic = MachTaskBasicInfo::default();
                let mut count = (std::mem::size_of::<MachTaskBasicInfo>()
                    / std::mem::size_of::<c_int>())
                    as MachMsgTypeNumberT;
                let kr = task_info(
                    task,
                    MACH_TASK_BASIC_INFO,
                    &mut basic as *mut _ as *mut c_int,
                    &mut count,
                );
                let rss_bytes = if kr == KERN_SUCCESS {
                    Some(basic.resident_size)
                } else {
                    None
                };

                // --- Процессорное время: завершённые потоки (basic_info) +
                //     живые потоки (thread_times_info) ---
                let cpu_seconds = if kr == KERN_SUCCESS {
                    let mut times = TaskThreadTimesInfo::default();
                    let mut tcount = (std::mem::size_of::<TaskThreadTimesInfo>()
                        / std::mem::size_of::<c_int>())
                        as MachMsgTypeNumberT;
                    let tkr = task_info(
                        task,
                        TASK_THREAD_TIMES_INFO,
                        &mut times as *mut _ as *mut c_int,
                        &mut tcount,
                    );
                    let mut total = tv_secs(basic.user_time) + tv_secs(basic.system_time);
                    if tkr == KERN_SUCCESS {
                        total += tv_secs(times.user_time) + tv_secs(times.system_time);
                    }
                    Some(total)
                } else {
                    None
                };

                ProcessSample {
                    rss_bytes,
                    cpu_seconds,
                }
            }
        }
    }
}

/// Partial update for a channel's live fields.
#[derive(Clone, Debug, Default)]
pub struct SourcePatch {
    pub status: Option<String>,
    pub busy: Option<bool>,
    pub queue_size: Option<u32>,
    pub dropped_chunks: Option<u64>,
    pub last_text: Option<String>,
    pub last_language: Option<String>,
    pub words_add: Option<u32>,
    pub speech_seconds: Option<f32>,
    pub last_error: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_processing_computes_rtf_and_lag() {
        let m = Metrics::new();
        m.set_source("mic", true, "idle");
        // proc 2.0s for 4.0s of audio -> rtf 0.5, lag 0 (faster than realtime).
        m.record_processing("mic", 4.0, 2.0);
        let src = m.source_snapshot("mic").expect("channel exists");
        assert!((src.last_rtf - 0.5).abs() < 1e-6, "rtf={}", src.last_rtf);
        assert_eq!(src.lag_estimate_s, 0.0, "lag should clamp to 0");

        // proc 6.0s for 4.0s of audio -> rtf 1.5, lag 2.0.
        m.record_processing("mic", 4.0, 6.0);
        let src = m.source_snapshot("mic").unwrap();
        assert!((src.last_rtf - 1.5).abs() < 1e-6, "rtf={}", src.last_rtf);
        assert!(
            (src.lag_estimate_s - 2.0).abs() < 1e-6,
            "lag={}",
            src.lag_estimate_s
        );

        // audio_s == 0 -> rtf 0.0 (no division).
        m.record_processing("mic", 0.0, 3.0);
        let src = m.source_snapshot("mic").unwrap();
        assert_eq!(src.last_rtf, 0.0);
        assert!((src.lag_estimate_s - 3.0).abs() < 1e-6);
    }

    #[test]
    fn record_interval_accumulates_words_and_counts() {
        let m = Metrics::new();
        m.record_interval(5);
        m.record_interval(7);
        let snap = m.snapshot();
        assert_eq!(snap.total_words, 12);
        assert_eq!(snap.total_intervals, 2);
        assert_ne!(snap.last_write_at, NO_TS, "last_write_at should be set");
    }

    #[test]
    fn set_and_update_source_reflected_in_snapshot() {
        let m = Metrics::new();
        m.set_source("remote", true, "listening");
        m.update_source(
            "remote",
            SourcePatch {
                status: Some("busy".to_string()),
                busy: Some(true),
                queue_size: Some(3),
                dropped_chunks: Some(2),
                last_text: Some("hello world".to_string()),
                last_language: Some("en".to_string()),
                words_add: Some(4),
                speech_seconds: Some(1.5),
                last_error: None,
            },
        );
        m.update_source(
            "remote",
            SourcePatch {
                words_add: Some(6),
                ..Default::default()
            },
        );

        let snap = m.snapshot();
        assert_eq!(snap.sources.len(), 1);
        let src = &snap.sources[0];
        assert_eq!(src.channel_id, "remote");
        assert!(src.enabled);
        assert_eq!(src.status, "busy");
        assert!(src.busy);
        assert_eq!(src.queue_size, 3);
        assert_eq!(src.dropped_chunks, 2);
        assert_eq!(src.last_text, "hello world");
        assert_eq!(src.last_language, "en");
        assert_eq!(src.words, 10, "words_add should accumulate (4+6)");
        assert!((src.speech_seconds - 1.5).abs() < 1e-6);

        // Per-channel snapshot agrees.
        let direct = m.source_snapshot("remote").unwrap();
        assert_eq!(direct.words, 10);
    }

    #[test]
    fn snapshot_consistent_after_reset_and_set_running() {
        let m = Metrics::new();
        // Declare channels and dirty some state.
        m.set_source("mic", true, "idle");
        m.set_source("remote", false, "idle");
        m.record_interval(9);
        m.update_source(
            "mic",
            SourcePatch {
                words_add: Some(3),
                ..Default::default()
            },
        );
        m.set_error("boom");

        // Reset clears counters/error, keeps channels + enabled flags.
        m.reset_for_run("parakeet-int8");
        m.set_running(true, false);

        let snap = m.snapshot();
        assert!(snap.state_running);
        assert!(!snap.state_loading);
        assert!(!snap.state_stopping);
        assert!(!snap.model_loaded, "model not loaded yet after reset");
        assert_eq!(snap.model_name, "parakeet-int8");
        assert_eq!(snap.total_words, 0, "words reset");
        assert_eq!(snap.total_intervals, 0, "intervals reset");
        assert_eq!(snap.last_error, "", "error cleared on reset");
        assert_eq!(snap.last_write_at, NO_TS);

        // Channels preserved with enabled flags; per-channel words reset.
        assert_eq!(snap.sources.len(), 2);
        let mic = snap.sources.iter().find(|c| c.channel_id == "mic").unwrap();
        let remote = snap
            .sources
            .iter()
            .find(|c| c.channel_id == "remote")
            .unwrap();
        assert!(mic.enabled);
        assert!(!remote.enabled);
        assert_eq!(mic.words, 0, "per-channel words reset");

        // set_running cleared the stopping flag.
        m.set_stopping(true);
        m.set_running(true, false);
        assert!(!m.snapshot().state_stopping);
    }

    #[test]
    fn queue_and_current_interval_reflected() {
        let m = Metrics::new();
        m.set_queue_depth(2, 16);
        m.update_current_interval("2026-06-18T10:00:00+00:00", 12.5, false);
        let snap = m.snapshot();
        assert_eq!(snap.bg_queue_depth, 2);
        assert_eq!(snap.bg_queue_capacity, 16);
        assert!((snap.current_interval_elapsed_s - 12.5).abs() < 1e-6);
        assert_eq!(snap.current_interval_start_at, "2026-06-18T10:00:00+00:00");
        assert!(!snap.channels_silent);
    }

    /// Потери интервалов должны быть видны UI и обнуляться на новом прогоне —
    /// иначе перегрузка ASR выглядит как «просто тишина».
    #[test]
    fn dropped_intervals_are_visible_and_reset_per_run() {
        let m = Metrics::new();
        assert_eq!(m.snapshot().dropped_intervals, 0);

        m.set_dropped_intervals(3);
        assert_eq!(m.snapshot().dropped_intervals, 3);

        m.reset_for_run("model");
        assert_eq!(m.snapshot().dropped_intervals, 0);
    }

    #[test]
    fn sample_system_never_panics() {
        let m = Metrics::new();
        // Несколько вызовов подряд: первый только инициализирует базу для CPU%,
        // последующие могут посчитать дельту. Главное — не паникует, а значения
        // неотрицательны и согласованы.
        m.sample_system();
        m.sample_system();
        let snap = m.snapshot();
        assert!(snap.cpu_percent >= 0.0);
        assert!(snap.cpu_p50 >= 0.0);
        assert!(snap.cpu_p90 >= 0.0);
        // Пик RSS не меньше текущего RSS.
        assert!(snap.memory_rss_peak_bytes >= snap.memory_rss_bytes);
    }

    #[test]
    fn percentile_known_sets() {
        // Набор 1..=10: p50 ~ 5 (nearest-rank: rank=5 -> значение 5),
        // p90 -> rank=9 -> значение 9, p100 -> 10, p0 -> 1.
        let v: Vec<f32> = (1..=10).map(|x| x as f32).collect();
        assert_eq!(percentile(&v, 0.0), 1.0);
        assert_eq!(percentile(&v, 50.0), 5.0);
        assert_eq!(percentile(&v, 90.0), 9.0);
        assert_eq!(percentile(&v, 100.0), 10.0);
    }

    #[test]
    fn percentile_handles_unsorted_and_single() {
        // Несортированный вход даёт тот же результат, что и сортированный.
        let v = [9.0_f32, 1.0, 5.0, 3.0, 7.0];
        assert_eq!(percentile(&v, 50.0), 5.0);
        assert_eq!(percentile(&v, 90.0), 9.0);
        // Один элемент — любой перцентиль это он сам.
        assert_eq!(percentile(&[42.0], 50.0), 42.0);
        assert_eq!(percentile(&[42.0], 90.0), 42.0);
    }

    #[test]
    fn percentile_empty_is_zero() {
        let empty: [f32; 0] = [];
        assert_eq!(percentile(&empty, 50.0), 0.0);
        assert_eq!(percentile(&empty, 90.0), 0.0);
    }

    #[test]
    fn push_window_evicts_oldest_when_full() {
        let mut w = VecDeque::new();
        for i in 0..(CPU_WINDOW + 5) {
            push_window(&mut w, i as f32);
        }
        // Окно не превышает лимит и хранит ПОСЛЕДНИЕ CPU_WINDOW значений.
        assert_eq!(w.len(), CPU_WINDOW);
        assert_eq!(*w.front().unwrap(), 5.0);
        assert_eq!(*w.back().unwrap(), (CPU_WINDOW + 4) as f32);
    }

    #[test]
    fn rss_peak_tracks_max_and_resets() {
        // Трекинг пика через публичный API, без реальных mach-вызовов:
        // напрямую правим внутреннее состояние, эмулируя сэмплы RSS.
        let m = Metrics::new();
        {
            let mut s = m.state.lock();
            for rss in [100u64, 300, 200, 250] {
                s.memory_rss_bytes = rss;
                if rss > s.memory_rss_peak_bytes {
                    s.memory_rss_peak_bytes = rss;
                }
            }
        }
        let snap = m.snapshot();
        assert_eq!(snap.memory_rss_bytes, 250, "текущее — последний сэмпл");
        assert_eq!(snap.memory_rss_peak_bytes, 300, "пик — максимум за окно");

        // reset_for_run очищает текущее значение и пик.
        m.reset_for_run("model");
        let snap = m.snapshot();
        assert_eq!(snap.memory_rss_bytes, 0);
        assert_eq!(snap.memory_rss_peak_bytes, 0);
        assert_eq!(snap.cpu_p50, 0.0, "окно CPU очищено");
        assert_eq!(snap.cpu_p90, 0.0);
    }

    #[test]
    fn cpu_percentiles_from_window() {
        // Заполняем окно CPU% известными значениями напрямую и проверяем, что
        // snapshot отдаёт ожидаемые p50/p90 (логика расчёта, без железа).
        let m = Metrics::new();
        {
            let mut s = m.state.lock();
            for v in 1..=10 {
                push_window(&mut s.cpu_window, v as f32);
            }
        }
        let snap = m.snapshot();
        assert_eq!(snap.cpu_p50, 5.0);
        assert_eq!(snap.cpu_p90, 9.0);
    }
}
