//! End-to-end pipeline test against the mock ASR backend: register channels,
//! load model, start, push audio, stop, then assert an interval was committed
//! to the store and is queryable. Exercises DSP -> coordinator -> ASR worker
//! -> store wiring without any real ML runtime.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use transcriber_core::config::default_config;
use transcriber_core::events::CoreEventListener;
use transcriber_core::types::*;
use transcriber_core::TranscriberCore;

struct CountingListener {
    committed: Arc<AtomicU32>,
}
impl CoreEventListener for CountingListener {
    fn on_event(&self, event: CoreEvent) {
        if let CoreEvent::IntervalCommitted { .. } = event {
            self.committed.fetch_add(1, Ordering::SeqCst);
        }
    }
}

#[test]
fn pushes_audio_and_commits_interval_via_flush() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("store").to_string_lossy().to_string();
    let models = dir.path().join("models").to_string_lossy().to_string();
    std::fs::create_dir_all(&storage).unwrap();

    let cfg = default_config(storage, models); // default model = Parakeet (mock backend here)
    let committed = Arc::new(AtomicU32::new(0));
    let listener = Box::new(CountingListener {
        committed: committed.clone(),
    });

    let core = TranscriberCore::new(cfg, listener).expect("core");
    core.register_channel(ChannelSpec {
        id: "mic".into(),
        label: "Mic".into(),
    })
    .unwrap();
    core.load_model().expect("load mock model");
    core.start().expect("start");

    // Push ~1s of loud (speech) audio at 16kHz mono in 30ms blocks.
    let frame: Vec<i16> = vec![6000; 480];
    for _ in 0..40 {
        core.push_audio_frame("mic".into(), frame.clone(), 16_000, 1);
        std::thread::sleep(std::time::Duration::from_millis(15));
    }
    // Ensure the interval has been recording for >= 0.5s so flush emits it.
    std::thread::sleep(std::time::Duration::from_millis(300));

    core.stop().expect("stop");

    // The flushed tail should have produced exactly one committed interval.
    assert!(
        committed.load(Ordering::SeqCst) >= 1,
        "expected >=1 committed interval"
    );

    let intervals = core
        .query_intervals(
            "2000-01-01T00:00:00+00:00".into(),
            "2100-01-01T00:00:00+00:00".into(),
        )
        .expect("query");
    assert!(!intervals.is_empty(), "store should hold the interval");
    let iv = &intervals[0];
    let mic = iv
        .channels
        .iter()
        .find(|c| c.channel_id == "mic")
        .expect("mic text");
    assert!(
        mic.words >= 1,
        "mock backend should yield words, got {}",
        mic.words
    );
    assert!(!mic.text.is_empty());

    let state = core.current_state();
    assert!(state.total_intervals >= 1);
}

/// Слушатель, сохраняющий все события сессии.
struct RecordingListener {
    events: Arc<std::sync::Mutex<Vec<CoreEvent>>>,
}
impl CoreEventListener for RecordingListener {
    fn on_event(&self, event: CoreEvent) {
        self.events.lock().unwrap().push(event);
    }
}

/// Смена модели «на лету» под работающим ASR-потоком — это либо зависание
/// записи на мьютексе бэкенда, либо интервал, посчитанный двумя разными
/// моделями. Ядро обязано отказать; оболочка делает стоп → загрузку → старт.
#[test]
fn load_model_is_rejected_while_recording() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("store").to_string_lossy().to_string();
    let models = dir.path().join("models").to_string_lossy().to_string();
    std::fs::create_dir_all(&storage).unwrap();

    let core = TranscriberCore::new(
        default_config(storage, models),
        Box::new(CountingListener {
            committed: Arc::new(AtomicU32::new(0)),
        }),
    )
    .expect("core");
    core.register_channel(ChannelSpec {
        id: "mic".into(),
        label: "Mic".into(),
    })
    .unwrap();
    core.load_model().expect("load mock model");
    core.start().expect("start");

    let err = core.load_model().expect_err("во время записи — отказ");
    assert!(
        format!("{err}").contains("running"),
        "ошибка должна объяснять причину: {err}"
    );

    core.stop().expect("stop");
    // После остановки загрузка снова разрешена.
    core.load_model().expect("reload after stop");
}

/// Отсутствие модели Silero — свойство сессии, а не канала: пользователь должен
/// получить ОДНО понятное предупреждение, а запись — продолжиться на
/// RMS-детекторе.
#[test]
fn missing_silero_model_warns_once_per_session() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("store").to_string_lossy().to_string();
    let models = dir.path().join("models").to_string_lossy().to_string();
    std::fs::create_dir_all(&storage).unwrap();

    let events = Arc::new(std::sync::Mutex::new(Vec::new()));
    let core = TranscriberCore::new(
        default_config(storage, models),
        Box::new(RecordingListener {
            events: events.clone(),
        }),
    )
    .expect("core");
    for id in ["mic", "remote"] {
        core.register_channel(ChannelSpec {
            id: id.into(),
            label: id.into(),
        })
        .unwrap();
    }
    core.load_model().expect("load mock model");
    core.start().expect("start");

    let frame: Vec<i16> = vec![6000; 480];
    for _ in 0..20 {
        core.push_audio_frame("mic".into(), frame.clone(), 16_000, 1);
        std::thread::sleep(std::time::Duration::from_millis(15));
    }
    std::thread::sleep(std::time::Duration::from_millis(300));
    core.stop().expect("stop");

    let warnings: Vec<String> = events
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            CoreEvent::Error { message, .. } if message.contains("Silero") => Some(message.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        warnings.len(),
        1,
        "ровно одно предупреждение на сессию, а не по каналу: {warnings:?}"
    );

    // Деградация не должна ломать запись: интервал всё равно закоммичен.
    assert!(events
        .lock()
        .unwrap()
        .iter()
        .any(|e| matches!(e, CoreEvent::IntervalCommitted { .. })));
}

#[test]
fn rejects_start_without_model_or_channels() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("s").to_string_lossy().to_string();
    let models = dir.path().join("m").to_string_lossy().to_string();
    std::fs::create_dir_all(&storage).unwrap();
    let cfg = default_config(storage, models);
    let core = TranscriberCore::new(
        cfg,
        Box::new(CountingListener {
            committed: Arc::new(AtomicU32::new(0)),
        }),
    )
    .unwrap();

    // No channels, no model loaded.
    assert!(core.start().is_err());
    core.register_channel(ChannelSpec {
        id: "mic".into(),
        label: "Mic".into(),
    })
    .unwrap();
    // Still no model.
    assert!(core.start().is_err());
}

// ---------------------------------------------------------------------------
// Срок хранения и поиск по истории
// ---------------------------------------------------------------------------

/// Текущее время в epoch-миллисекундах (без chrono — тесту хватает арифметики).
#[cfg(feature = "store")]
fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// Записать интервал МИМО ядра, задав ему произвольное время. Так тест
/// подкладывает «старую» историю, не гоняя пайплайн сутками.
#[cfg(feature = "store")]
fn seed_interval(storage: &str, start_ms: i64, text: &str) -> i64 {
    use transcriber_core::store::{ms_to_iso_utc, Store};
    let db = std::path::Path::new(storage).join("transcriber.sqlite");
    let store = Store::open(db.to_string_lossy().as_ref()).expect("открыть базу");
    store
        .write_interval(
            &ms_to_iso_utc(start_ms),
            &ms_to_iso_utc(start_ms + 60_000),
            60.0,
            &[ChannelText {
                channel_id: "mic".into(),
                text: text.into(),
                words: text.split_whitespace().count() as u32,
                language: "ru".into(),
            }],
        )
        .expect("записать интервал")
}

#[cfg(feature = "store")]
const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// При `retention_days > 0` старт сессии обязан вычистить историю старше срока
/// и НЕ трогать свежую: это единственный момент, когда чистка гарантированно
/// случится у пользователя, который включает запись раз в сутки.
#[cfg(feature = "store")]
#[test]
fn retention_sweeps_stale_history_on_start() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("store").to_string_lossy().to_string();
    let models = dir.path().join("models").to_string_lossy().to_string();
    std::fs::create_dir_all(&storage).unwrap();

    let mut cfg = default_config(storage.clone(), models);
    cfg.retention_days = 30;

    let core = TranscriberCore::new(
        cfg,
        Box::new(CountingListener {
            committed: Arc::new(AtomicU32::new(0)),
        }),
    )
    .expect("core");

    let stale_id = seed_interval(&storage, now_ms() - 400 * DAY_MS, "старая запись");
    let fresh_id = seed_interval(&storage, now_ms() - 60 * 60 * 1000, "свежая запись");

    core.register_channel(ChannelSpec {
        id: "mic".into(),
        label: "Mic".into(),
    })
    .unwrap();
    core.load_model().expect("load mock model");
    core.start().expect("start");

    // Чистка идёт в фоновом тикере — ждём её результата, а не спим наугад.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while std::time::Instant::now() < deadline {
        if core.interval_by_id(stale_id).unwrap().is_none() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    core.stop().expect("stop");

    assert!(
        core.interval_by_id(stale_id).unwrap().is_none(),
        "интервал старше срока хранения должен исчезнуть"
    );
    assert!(
        core.interval_by_id(fresh_id).unwrap().is_some(),
        "свежая история удаляться не должна"
    );
    let info = core.store_info().expect("store_info");
    assert_eq!(info.intervals, 1, "в базе остаётся только свежий интервал");
}

/// `retention_days = 0` — «хранить всегда»: ни старт сессии, ни ручное
/// обслуживание с `days = 0` не должны удалить ни строки.
#[cfg(feature = "store")]
#[test]
fn store_maintenance_with_zero_days_keeps_history() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("store").to_string_lossy().to_string();
    let models = dir.path().join("models").to_string_lossy().to_string();
    std::fs::create_dir_all(&storage).unwrap();

    let core = TranscriberCore::new(
        default_config(storage.clone(), models),
        Box::new(CountingListener {
            committed: Arc::new(AtomicU32::new(0)),
        }),
    )
    .expect("core");
    let stale_id = seed_interval(&storage, now_ms() - 400 * DAY_MS, "старая запись");

    assert_eq!(
        core.store_maintenance(0).expect("обслуживание"),
        0,
        "days = 0 не удаляет ничего"
    );
    assert!(
        core.interval_by_id(stale_id).unwrap().is_some(),
        "история должна остаться нетронутой"
    );

    // Контраст: с явным сроком та же запись удаляется (интервал + его текст).
    let deleted = core.store_maintenance(30).expect("обслуживание");
    assert!(
        deleted >= 2,
        "ожидались удалённые строки, получено {deleted}"
    );
    assert!(core.interval_by_id(stale_id).unwrap().is_none());
}

// ---------------------------------------------------------------------------
// Сессии записи (разделители единой ленты журнала)
// ---------------------------------------------------------------------------

/// Границы «всё время» для запросов истории.
#[cfg(feature = "store")]
const ALL_FROM: &str = "2000-01-01T00:00:00+00:00";
#[cfg(feature = "store")]
const ALL_TO: &str = "2100-01-01T00:00:00+00:00";

/// `start()` обязан зафиксировать факт «здесь запись включили», а `stop()` —
/// «здесь выключили» с причиной `user`. Пока запись идёт, сессия видна
/// незакрытой: именно так UI отличает «идёт запись» от «приложение закрылось».
#[cfg(feature = "store")]
#[test]
fn start_and_stop_record_one_closed_session() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("store").to_string_lossy().to_string();
    let models = dir.path().join("models").to_string_lossy().to_string();
    std::fs::create_dir_all(&storage).unwrap();

    let core = TranscriberCore::new(
        default_config(storage, models),
        Box::new(CountingListener {
            committed: Arc::new(AtomicU32::new(0)),
        }),
    )
    .expect("core");
    core.register_channel(ChannelSpec {
        id: "mic".into(),
        label: "Mic".into(),
    })
    .unwrap();
    core.load_model().expect("load mock model");

    assert!(
        core.recent_sessions(10).expect("сессии").is_empty(),
        "до первого старта истории сессий нет"
    );

    core.start().expect("start");
    let during = core.recent_sessions(10).expect("сессии");
    assert_eq!(during.len(), 1, "старт открывает ровно одну сессию");
    assert!(
        during[0].ended_at.is_empty() && during[0].stop_reason.is_empty(),
        "идущая запись — незакрытая сессия: {:?}",
        during[0]
    );

    core.stop().expect("stop");
    let after = core.recent_sessions(10).expect("сессии");
    assert_eq!(after.len(), 1, "стоп не создаёт вторую сессию");
    assert_eq!(after[0].id, during[0].id);
    assert_eq!(after[0].stop_reason, "user");
    assert!(
        !after[0].ended_at.is_empty(),
        "конец записан: {:?}",
        after[0]
    );

    // Тот же факт доступен и запросом за период (по нему UI рисует разделители).
    let ranged = core
        .query_sessions(ALL_FROM.into(), ALL_TO.into())
        .expect("сессии за период");
    assert_eq!(ranged, after);

    // Вторая сессия — отдельная строка; незакрытую предыдущую никто не трогает.
    core.start().expect("start again");
    let two = core.recent_sessions(10).expect("сессии");
    assert_eq!(two.len(), 2, "новый старт — новая сессия");
    assert_eq!(two[1].id, after[0].id, "новые первыми");
    assert_eq!(two[1].stop_reason, "user", "прошлая сессия не переписана");
    core.stop().expect("stop again");
}

/// `recent_intervals(limit)` — хвост истории для панели меню-бара: реплики
/// прошлых сессий, без указания периода и без падения на пустой базе.
#[cfg(feature = "store")]
#[test]
fn recent_intervals_returns_history_tail() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("store").to_string_lossy().to_string();
    let models = dir.path().join("models").to_string_lossy().to_string();
    std::fs::create_dir_all(&storage).unwrap();

    let core = TranscriberCore::new(
        default_config(storage.clone(), models),
        Box::new(CountingListener {
            committed: Arc::new(AtomicU32::new(0)),
        }),
    )
    .expect("core");

    assert!(
        core.recent_intervals(20).expect("хвост").is_empty(),
        "на пустой базе — пустой список, не ошибка"
    );

    // Три интервала «прошлых сессий» с разным временем.
    for (n, back) in [(1, 3 * DAY_MS), (2, 2 * DAY_MS), (3, DAY_MS)] {
        seed_interval(&storage, now_ms() - back, &format!("реплика {n}"));
    }

    let tail = core.recent_intervals(2).expect("хвост");
    assert_eq!(tail.len(), 2, "ровно limit последних");
    assert!(
        tail[0].start_at > tail[1].start_at,
        "новые первыми: {:?}",
        tail.iter().map(|iv| &iv.start_at).collect::<Vec<_>>()
    );
    assert_eq!(tail[0].channels[0].text, "реплика 3");
    assert_eq!(core.recent_intervals(100).expect("хвост").len(), 3);
}

/// Поиск обязан находить слово из уже закоммиченного интервала — это контракт
/// экрана истории (и FTS-, и LIKE-сборки ядра).
#[cfg(feature = "store")]
#[test]
fn search_intervals_finds_committed_text() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("store").to_string_lossy().to_string();
    let models = dir.path().join("models").to_string_lossy().to_string();
    std::fs::create_dir_all(&storage).unwrap();

    let committed = Arc::new(AtomicU32::new(0));
    let core = TranscriberCore::new(
        default_config(storage, models),
        Box::new(CountingListener {
            committed: committed.clone(),
        }),
    )
    .expect("core");
    core.register_channel(ChannelSpec {
        id: "mic".into(),
        label: "Mic".into(),
    })
    .unwrap();
    core.load_model().expect("load mock model");
    core.start().expect("start");

    let frame: Vec<i16> = vec![6000; 480];
    for _ in 0..40 {
        core.push_audio_frame("mic".into(), frame.clone(), 16_000, 1);
        std::thread::sleep(std::time::Duration::from_millis(15));
    }
    std::thread::sleep(std::time::Duration::from_millis(300));
    core.stop().expect("stop");
    assert!(
        committed.load(Ordering::SeqCst) >= 1,
        "нужен интервал в базе"
    );

    // Mock-бэкенд пишет слово "mock" — ищем именно его.
    let found = core
        .search_intervals("mock".into(), None, None, 50, 0)
        .expect("поиск");
    assert!(!found.is_empty(), "слово из расшифровки должно находиться");
    assert!(found
        .iter()
        .flat_map(|iv| iv.channels.iter())
        .any(|c| c.text.contains("mock")));

    let missing = core
        .search_intervals("такогословатонет".into(), None, None, 50, 0)
        .expect("поиск");
    assert!(missing.is_empty(), "чужое слово находиться не должно");

    // Обзор за период отдаёт тот же интервал (пагинация — аддитивный контракт).
    let overview = core
        .intervals_overview_range(
            "2000-01-01T00:00:00+00:00".into(),
            "2100-01-01T00:00:00+00:00".into(),
            10,
            0,
        )
        .expect("обзор");
    assert!(!overview.is_empty());
    assert!(core.interval_by_id(overview[0].id).unwrap().is_some());
}
