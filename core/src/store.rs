//! SQLite persistence (replaces intervals.jsonl + voice_activity.jsonl).
//! OWNER: module agent. rusqlite (bundled), WAL mode.
//!
//! Схема версионируется через `PRAGMA user_version`; миграции выполняются
//! пошагово, каждая в своей транзакции (см. [`migrate`]). Текущая версия —
//! [`SCHEMA_VERSION`]. База с версией новее кода не открывается (понятная
//! `CoreError::Store`, а не «unknown column»).
//!
//! Схема v3:
//! ```sql
//! intervals(id INTEGER PK, start_at TEXT, end_at TEXT, duration_s REAL,
//!           total_words INTEGER, start_ms INTEGER, end_ms INTEGER)
//!     index(start_at), index(start_ms), index(end_ms)
//! interval_texts(interval_id INTEGER, channel_id TEXT, text TEXT,
//!                words INTEGER, language TEXT)          index(interval_id)
//! voice_events(id INTEGER PK, ts TEXT, channel_id TEXT, date TEXT,
//!              hour INTEGER, ts_ms INTEGER)
//!     index(ts), index(channel_id,date), index(ts_ms)
//! sessions(id INTEGER PK, started_at TEXT, started_ms INTEGER,
//!          ended_at TEXT NULL, ended_ms INTEGER NULL,
//!          stop_reason TEXT NULL)                       index(started_ms)
//! interval_texts_fts — FTS5 (external content над interval_texts), если
//!     сборка SQLite умеет FTS5; иначе поиск идёт через LIKE.
//! ```
//!
//! Времена: `*_ms` — epoch-миллисекунды UTC, по ним идут ВСЕ диапазонные
//! `WHERE`/`ORDER BY` (лексикографическое сравнение ISO-строк врёт при смене
//! таймзоны/DST). ISO-строки остаются для отображения и обратной совместимости
//! публичных типов — сигнатуры вида `query_intervals(&str, &str)` не менялись:
//! ISO на входе конвертируется в мс, невалидный ISO — `CoreError::Config`.
//!
//! Прочее:
//! - `query_intervals(from,to)`: интервалы, ПЕРЕСЕКАЮЩИЕ [from,to]
//!   (`start_ms < to AND end_ms > from`), тексты подтягиваются одним JOIN.
//! - `recent_intervals(limit)`: последние `limit` интервалов с текстами
//!   (новые первыми) — дешёвый «хвост истории» без выбора периода.
//! - `voice_activity(Hourly|Daily)`: бакеты по [from,to) с заполнением пустых.
//! - `sessions(from,to)`: сессии записи, у которых НАЧАЛО ИЛИ КОНЕЦ попадает
//!   в период (именно они дают разделители в ленте журнала);
//!   `last_sessions(limit)` — последние N сессий, новые первыми.
//! - `retention_sweep_all(days)`: чистит intervals + interval_texts +
//!   voice_events старше cutoff.

use std::collections::BTreeMap;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, FixedOffset, TimeZone, Timelike, Utc};
use parking_lot::Mutex;
use rusqlite::Connection;

use crate::errors::CoreError;
use crate::types::{
    ActivityBucket, ActivityKind, ChannelCount, ChannelText, IntervalOverviewItem, IntervalRecord,
    SessionRecord,
};

/// Версия схемы, которую понимает этот код (`PRAGMA user_version`).
pub const SCHEMA_VERSION: i64 = 3;

/// `sessions.stop_reason`: запись остановил пользователь.
pub const SESSION_STOP_USER: &str = "user";

/// `sessions.stop_reason`: сессия закрыта аварийно (паника DSP, потеря
/// ASR-воркера, watchdog зависшего DSP, прерванная по дедлайну остановка).
pub const SESSION_STOP_ERROR: &str = "error";

/// Потолок для `limit` в постраничных выборках.
pub const MAX_PAGE_LIMIT: u32 = 1000;

/// Сколько последних интервалов отдаёт `overview()` без параметров.
pub const OVERVIEW_DEFAULT_LIMIT: u32 = 1000;

/// Имя FTS5-таблицы над `interval_texts.text`.
const FTS_TABLE: &str = "interval_texts_fts";

/// Map any rusqlite error into a `CoreError::Store`.
fn store_err<E: std::fmt::Display>(e: E) -> CoreError {
    CoreError::Store(format!("{e}"))
}

/// Разбор ISO-8601 строки, ПРИШЕДШЕЙ ИЗ БАЗЫ (испорченная строка — дефект
/// хранилища, поэтому `CoreError::Store`).
fn parse_ts(s: &str) -> Result<DateTime<FixedOffset>, CoreError> {
    DateTime::parse_from_rfc3339(s)
        .map_err(|e| CoreError::Store(format!("invalid ISO-8601 timestamp {s:?}: {e}")))
}

/// Разбор ISO-8601 строки, ПРИШЕДШЕЙ ОТ ВЫЗЫВАЮЩЕГО (UI/API/CLI). Это ошибка
/// ввода, а не хранилища — `CoreError::Config`, чтобы API отдал 400, не 500.
pub fn parse_input_ts(s: &str) -> Result<DateTime<FixedOffset>, CoreError> {
    DateTime::parse_from_rfc3339(s).map_err(|e| {
        CoreError::Config(format!(
            "невалидное время {s:?}: ожидается ISO-8601 с таймзоной ({e})"
        ))
    })
}

/// ISO-8601 (с таймзоной) → epoch-миллисекунды UTC.
pub fn iso_to_ms(s: &str) -> Result<i64, CoreError> {
    Ok(parse_input_ts(s)?.timestamp_millis())
}

/// Опциональные ISO-границы → epoch-мс (`None` = «без границы»).
fn optional_bounds_ms(from: Option<&str>, to: Option<&str>) -> Result<(i64, i64), CoreError> {
    Ok((
        match from {
            Some(s) => iso_to_ms(s)?,
            None => i64::MIN,
        },
        match to {
            Some(s) => iso_to_ms(s)?,
            None => i64::MAX,
        },
    ))
}

/// epoch-миллисекунды UTC → RFC3339 в UTC (для служебных нужд/тестов).
pub fn ms_to_iso_utc(ms: i64) -> String {
    Utc.timestamp_millis_opt(ms)
        .single()
        .map(|d| d.to_rfc3339())
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Форматирование выгрузок
// ---------------------------------------------------------------------------

/// Сборка человекочитаемых/файловых представлений истории.
///
/// Живёт рядом с хранилищем, потому что ОДНА и та же форма нужна и HTTP API
/// (`/api/v1/transcript`, `/api/v1/export`), и CLI (`transcript`, `today`,
/// `export`), а общего «презентационного» модуля в ядре нет. Форма документа
/// повторяет экспорт журнала в macOS-приложении (`JournalExport.swift`).
pub mod export {
    use crate::types::IntervalRecord;

    /// `HH:MM` из ISO-строки (та же логика, что в приложении).
    pub fn hhmm(iso: &str) -> String {
        match iso.split_once('T') {
            Some((_, rest)) if rest.len() >= 5 => rest[..5].to_string(),
            _ => iso.to_string(),
        }
    }

    /// Плоский текст: по строке на непустую реплику канала.
    pub fn transcript_text(items: &[IntervalRecord]) -> String {
        let mut out = String::new();
        for iv in items {
            for ch in &iv.channels {
                if ch.text.trim().is_empty() {
                    continue;
                }
                out.push_str(&format!(
                    "[{}] {}: {}\n",
                    hhmm(&iv.start_at),
                    ch.channel_id,
                    ch.text.trim()
                ));
            }
        }
        out
    }

    /// Markdown-транскрипция за период.
    pub fn transcript_markdown(
        items: &[IntervalRecord],
        from: &str,
        to: &str,
        channel: Option<&str>,
    ) -> String {
        let mut s = String::from("# Транскрипция Chronica\n\n");
        if !from.is_empty() || !to.is_empty() {
            s.push_str(&format!("- Период: {from} — {to}\n"));
        }
        if let Some(ch) = channel {
            s.push_str(&format!("- Канал: {ch}\n"));
        }
        s.push_str(&format!("- Интервалов: {}\n\n", items.len()));
        s.push_str(&channels_markdown(items));
        s
    }

    /// Документ журнала в форме, которую строит приложение
    /// (`JournalExport.swift`): camelCase-ключи, `activities` +
    /// `transcription.intervals` → каналы. Ядро не хранит экранный журнал,
    /// поэтому `activities` всегда пустой.
    pub fn journal_document(
        items: &[IntervalRecord],
        from: &str,
        to: &str,
        exported_at: &str,
    ) -> serde_json::Value {
        let intervals: Vec<serde_json::Value> = items
            .iter()
            .map(|iv| {
                serde_json::json!({
                    "id": iv.id,
                    "startAt": iv.start_at,
                    "endAt": iv.end_at,
                    "durationS": iv.duration_s,
                    "channels": iv.channels.iter().map(|c| serde_json::json!({
                        "channelId": c.channel_id,
                        "text": c.text,
                        "words": c.words,
                        "language": c.language,
                    })).collect::<Vec<_>>(),
                })
            })
            .collect();

        serde_json::json!({
            "product": "Chronica",
            "exportedAt": exported_at,
            "from": from,
            "to": to,
            "activities": [],
            "transcription": {
                "count": intervals.len(),
                "intervals": intervals,
            }
        })
    }

    /// Markdown-вариант того же документа (структура как в приложении).
    pub fn journal_markdown(
        items: &[IntervalRecord],
        from: &str,
        to: &str,
        exported_at: &str,
    ) -> String {
        let mut s = String::from("# Журнал Chronica\n\n");
        s.push_str(&format!("- Период: {from} — {to}\n"));
        s.push_str(&format!("- Экспортировано: {exported_at}\n\n"));
        s.push_str("## Дела (0)\n\n_Нет записанных дел за период._\n\n");
        s.push_str(&format!("## Транскрипция ({} интервалов)\n\n", items.len()));
        if items.is_empty() {
            s.push_str("_Нет записанной речи за период._\n\n");
        }
        s.push_str(&channels_markdown(items));
        s
    }

    /// Общее тело: интервалы с непустыми репликами, поканально.
    fn channels_markdown(items: &[IntervalRecord]) -> String {
        let mut s = String::new();
        for iv in items {
            let non_empty: Vec<_> = iv
                .channels
                .iter()
                .filter(|c| !c.text.trim().is_empty())
                .collect();
            if non_empty.is_empty() {
                continue;
            }
            s.push_str(&format!(
                "### {}–{}\n\n",
                hhmm(&iv.start_at),
                hhmm(&iv.end_at)
            ));
            for c in non_empty {
                s.push_str(&format!(
                    "**{}** (`{}`): {}\n\n",
                    c.channel_id,
                    c.language,
                    c.text.trim()
                ));
            }
        }
        s
    }
}

// ---------------------------------------------------------------------------
// Дополнительные (аддитивные) типы результата
// ---------------------------------------------------------------------------

/// Страница интервалов с курсором на следующую (keyset-пагинация).
#[derive(Clone, Debug, PartialEq)]
pub struct IntervalPage {
    pub items: Vec<IntervalRecord>,
    /// Непрозрачный курсор `start_ms:id` для следующей страницы; `None` — конец.
    pub next_cursor: Option<String>,
}

/// Агрегаты по одному каналу за период.
#[derive(Clone, Debug, PartialEq)]
pub struct ChannelStats {
    pub channel_id: String,
    /// Число интервалов, где на этом канале была распознана речь.
    pub intervals: i64,
    pub words: i64,
    /// Сумма длительностей интервалов с речью на этом канале (оценка сверху).
    pub speech_seconds: f64,
}

/// Сводка за период.
#[derive(Clone, Debug, PartialEq)]
pub struct RangeStats {
    pub from: String,
    pub to: String,
    pub intervals: i64,
    pub words: i64,
    pub duration_seconds: f64,
    pub channels: Vec<ChannelStats>,
}

/// Состояние файла базы (для `db info` в CLI и `/api/v1/health`).
#[derive(Clone, Debug, PartialEq)]
pub struct DbInfo {
    pub path: String,
    pub schema_version: i64,
    pub fts5: bool,
    /// Размер основной базы (page_count × page_size).
    pub size_bytes: u64,
    /// Размер WAL-файла рядом с базой, если он есть.
    pub wal_bytes: u64,
    pub intervals: i64,
    pub interval_texts: i64,
    pub voice_events: i64,
    /// Сколько сессий записи (v3) лежит в базе.
    pub sessions: i64,
    pub first_start_at: Option<String>,
    pub last_end_at: Option<String>,
}

/// Одно попадание поиска: интервал целиком, канал, в тексте которого нашлись
/// слова запроса, и фрагмент этого текста вокруг совпадения.
///
/// Аддитивная надстройка над [`Store::search`]: тот отдаёт интервалы целиком
/// (по несколько тысяч символов) и остаётся ради FFI, а UI/CLI/HTTP берут
/// [`Store::search_hits`], чтобы печатать читаемый фрагмент.
#[derive(Clone, Debug, PartialEq)]
pub struct SearchHit {
    pub interval: IntervalRecord,
    /// Канал с совпадением (если совпадения нет ни в одном — первый непустой).
    pub channel_id: String,
    /// Фрагмент текста канала: см. [`make_snippet`].
    pub snippet: String,
}

// ---------------------------------------------------------------------------
// Фрагменты (snippets) для выдачи поиска
// ---------------------------------------------------------------------------

/// Сколько символов контекста брать с каждой стороны совпадения по умолчанию:
/// вместе с самим словом фрагмент выходит ≈200 символов — одна-две строки
/// терминала.
pub const SNIPPET_RADIUS: usize = 90;

/// Маркер начала совпадения внутри `snippet` (как у `snippet()` в FTS5).
/// CLI заменяет пару маркеров на ANSI-жирный, когда stdout — терминал.
pub const SNIPPET_OPEN: &str = "«";

/// Маркер конца совпадения внутри `snippet`.
pub const SNIPPET_CLOSE: &str = "»";

/// Символ обрыва текста слева/справа от фрагмента.
pub const SNIPPET_ELLIPSIS: &str = "…";

/// Фрагмент текста вокруг ПЕРВОГО совпадения слов запроса, с выделением всех
/// совпадений маркерами [`SNIPPET_OPEN`]/[`SNIPPET_CLOSE`].
///
/// Одна функция на оба движка поиска (FTS5 и LIKE-фолбэк), поэтому выдача не
/// зависит от того, собран ли SQLite с FTS5. Свойства:
///
/// - `radius` — символы контекста с каждой стороны совпадения;
/// - совпадение ищется без учёта регистра, кириллица работает так же, как латиница;
/// - границы фрагмента не режут слова: край сдвигается до пробела;
/// - обрыв текста помечается [`SNIPPET_ELLIPSIS`];
/// - переводы строк и повторные пробелы схлопываются в один пробел (фрагмент
///   печатается одной строкой);
/// - если слов запроса в тексте нет (FTS5 мог совпасть по другому каналу), —
///   отдаётся начало текста той же длины.
pub fn make_snippet(text: &str, query: &str, radius: usize) -> String {
    snippet_of(text, query, radius).0
}

/// Рабочая версия [`make_snippet`]; второй элемент — нашлись ли слова запроса
/// в этом тексте (нужно, чтобы выбрать канал попадания).
fn snippet_of(text: &str, query: &str, radius: usize) -> (String, bool) {
    let flat: Vec<char> = {
        let mut out: Vec<char> = Vec::with_capacity(text.len());
        for (i, word) in text.split_whitespace().enumerate() {
            if i > 0 {
                out.push(' ');
            }
            out.extend(word.chars());
        }
        out
    };
    if flat.is_empty() {
        return (String::new(), false);
    }
    let lower: Vec<char> = flat.iter().map(|c| lower_char(*c)).collect();

    let tokens: Vec<Vec<char>> = query
        .split_whitespace()
        .map(|t| t.trim_matches(|c: char| !c.is_alphanumeric()))
        .filter(|t| !t.is_empty())
        .map(|t| t.chars().map(lower_char).collect())
        .collect();

    // Вхождения слов запроса. Для КАЖДОГО слова берём лучший класс совпадения:
    // целое слово > начало слова > подстрока в середине. Иначе на запрос
    // «тест» фрагмент цеплялся бы за «не тестировали» вместо настоящего
    // «тест» дальше по тексту (FTS5 совпал именно по слову).
    let word_char = |i: usize| flat.get(i).is_some_and(|c: &char| c.is_alphanumeric());
    let mut raw: Vec<(usize, usize)> = Vec::new();
    for token in &tokens {
        if token.is_empty() || token.len() > lower.len() {
            continue;
        }
        let mut by_rank: [Vec<(usize, usize)>; 3] = Default::default();
        let mut i = 0;
        while i + token.len() <= lower.len() {
            if lower[i..i + token.len()] == token[..] {
                let end = i + token.len();
                let rank = match (i > 0 && word_char(i - 1), word_char(end)) {
                    (false, false) => 0,
                    (false, true) => 1,
                    _ => 2,
                };
                by_rank[rank].push((i, end));
                i = end;
            } else {
                i += 1;
            }
        }
        if let Some(best) = by_rank.iter_mut().find(|v| !v.is_empty()) {
            raw.append(best);
        }
    }
    raw.sort_unstable();
    let mut hits: Vec<(usize, usize)> = Vec::with_capacity(raw.len());
    for (s, e) in raw {
        match hits.last_mut() {
            Some(last) if s <= last.1 => last.1 = last.1.max(e),
            _ => hits.push((s, e)),
        }
    }

    let found = !hits.is_empty();
    let (hit_start, hit_end) = hits.first().copied().unwrap_or((0, 0));
    let mut start = hit_start.saturating_sub(radius);
    let mut end = if found {
        (hit_end + radius).min(flat.len())
    } else {
        radius.saturating_mul(2).min(flat.len())
    };

    // Не начинать и не заканчивать посреди слова (само совпадение не режем).
    if start > 0 {
        while start < hit_start && !flat[start - 1].is_whitespace() {
            start += 1;
        }
    }
    if end < flat.len() {
        while end > hit_end && !flat[end].is_whitespace() {
            end -= 1;
        }
    }
    while start < end && flat[start].is_whitespace() {
        start += 1;
    }
    while end > start && flat[end - 1].is_whitespace() {
        end -= 1;
    }

    let mut out = String::new();
    if start > 0 {
        out.push_str(SNIPPET_ELLIPSIS);
    }
    let mut i = start;
    for &(s, e) in &hits {
        if s < i || e > end {
            continue;
        }
        out.extend(&flat[i..s]);
        out.push_str(SNIPPET_OPEN);
        out.extend(&flat[s..e]);
        out.push_str(SNIPPET_CLOSE);
        i = e;
    }
    out.extend(&flat[i..end]);
    if end < flat.len() {
        out.push_str(SNIPPET_ELLIPSIS);
    }
    (out, found)
}

/// Приведение символа к нижнему регистру БЕЗ смены длины: индексы текста и его
/// «нижнего» отражения должны совпадать один к одному.
fn lower_char(c: char) -> char {
    let mut it = c.to_lowercase();
    match (it.next(), it.next()) {
        (Some(l), None) => l,
        _ => c,
    }
}

/// Канал интервала, в тексте которого нашлись слова запроса (иначе — первый
/// непустой), и фрагмент его текста.
fn hit_channel(iv: &IntervalRecord, query: &str, radius: usize) -> (String, String) {
    let mut fallback: Option<(String, String)> = None;
    for ch in &iv.channels {
        if ch.text.trim().is_empty() {
            continue;
        }
        let (snippet, found) = snippet_of(&ch.text, query, radius);
        if found {
            return (ch.channel_id.clone(), snippet);
        }
        if fallback.is_none() {
            fallback = Some((ch.channel_id.clone(), snippet));
        }
    }
    fallback.unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

pub struct Store {
    conn: Mutex<Connection>,
    db_path: String,
    fts: bool,
}

impl Store {
    pub fn open(db_path: &str) -> Result<Self, CoreError> {
        let mut conn = Connection::open(db_path).map_err(store_err)?;

        // WAL for concurrent reads while writing. `query_row` because
        // journal_mode pragma returns the resulting mode.
        conn.query_row("PRAGMA journal_mode=WAL;", [], |_row| Ok(()))
            .map_err(store_err)?;
        // Низкая нагрузка на диск: NORMAL не делает fsync на каждый коммит
        // (WAL сам по себе крэш-безопасен), WAL не растёт бесконечно, а
        // конкурентная запись ждёт до 3с вместо мгновенного SQLITE_BUSY.
        conn.busy_timeout(StdDuration::from_millis(3000))
            .map_err(store_err)?;
        conn.execute_batch(
            "PRAGMA synchronous=NORMAL;
             PRAGMA journal_size_limit=8388608;
             PRAGMA temp_store=MEMORY;",
        )
        .map_err(store_err)?;

        migrate(&mut conn)?;
        let fts = ensure_fts(&conn);

        Ok(Self {
            conn: Mutex::new(conn),
            db_path: db_path.to_string(),
            fts,
        })
    }

    /// Путь к файлу базы, с которым открыт этот `Store`.
    pub fn db_path(&self) -> &str {
        &self.db_path
    }

    /// Версия схемы открытой базы.
    pub fn schema_version(&self) -> Result<i64, CoreError> {
        let conn = self.conn.lock();
        user_version(&conn)
    }

    /// Доступен ли полнотекстовый индекс FTS5 (иначе `search` идёт по LIKE).
    pub fn fts_enabled(&self) -> bool {
        self.fts
    }

    /// Дешёвая проверка живости базы (для `/api/v1/health`).
    pub fn health_ok(&self) -> bool {
        let conn = self.conn.lock();
        conn.query_row("SELECT 1", [], |r| r.get::<_, i64>(0))
            .is_ok()
    }

    pub fn write_interval(
        &self,
        start_at: &str,
        end_at: &str,
        duration_s: f64,
        channels: &[ChannelText],
    ) -> Result<i64, CoreError> {
        let total_words: u32 = channels.iter().map(|c| c.words).sum();
        let start_ms = iso_to_ms(start_at)?;
        let end_ms = iso_to_ms(end_at)?;

        let mut conn = self.conn.lock();
        let tx = conn.transaction().map_err(store_err)?;

        tx.execute(
            "INSERT INTO intervals (start_at, end_at, duration_s, total_words, start_ms, end_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![start_at, end_at, duration_s, total_words, start_ms, end_ms],
        )
        .map_err(store_err)?;

        let interval_id = tx.last_insert_rowid();

        {
            let mut stmt = tx
                .prepare(
                    "INSERT INTO interval_texts
                        (interval_id, channel_id, text, words, language)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                )
                .map_err(store_err)?;
            for ch in channels {
                stmt.execute(rusqlite::params![
                    interval_id,
                    ch.channel_id,
                    ch.text,
                    ch.words,
                    ch.language,
                ])
                .map_err(store_err)?;
            }
        }

        tx.commit().map_err(store_err)?;
        Ok(interval_id)
    }

    /// Интервалы, пересекающие [from, to]. ISO-8601 на входе.
    pub fn query_intervals(&self, from: &str, to: &str) -> Result<Vec<IntervalRecord>, CoreError> {
        self.query_intervals_ms(iso_to_ms(from)?, iso_to_ms(to)?)
    }

    /// То же, но границы уже в epoch-мс UTC (быстрый путь для API/CLI).
    pub fn query_intervals_ms(
        &self,
        from_ms: i64,
        to_ms: i64,
    ) -> Result<Vec<IntervalRecord>, CoreError> {
        let conn = self.conn.lock();
        // Один JOIN вместо N+1 SELECT-ов текстов.
        let mut stmt = conn
            .prepare(
                "SELECT iv.id, iv.start_at, iv.end_at, iv.duration_s,
                        t.channel_id, t.text, t.words, t.language
                 FROM intervals iv
                 LEFT JOIN interval_texts t ON t.interval_id = iv.id
                 WHERE iv.start_ms < ?1 AND iv.end_ms > ?2
                 ORDER BY iv.start_ms, iv.id, t.rowid",
            )
            .map_err(store_err)?;
        collect_joined(&mut stmt, rusqlite::params![to_ms, from_ms])
    }

    /// Последние `limit` интервалов с текстами, НОВЫЕ ПЕРВЫМИ.
    ///
    /// Дешёвый «хвост истории» для панели меню-бара: ей нужны последние реплики
    /// (в том числе за прошлые сессии), а не период. Запрос за «последние трое
    /// суток» ради этого сканировал бы диапазон впустую, поэтому здесь ровно
    /// `ORDER BY start_ms DESC LIMIT ?` по индексу и тот же JOIN текстов, что в
    /// [`Store::query_intervals_ms`] (никаких N+1 выборок).
    ///
    /// `limit` зажимается диапазоном `1..=`[`MAX_PAGE_LIMIT`].
    pub fn recent_intervals(&self, limit: u32) -> Result<Vec<IntervalRecord>, CoreError> {
        let limit = limit.clamp(1, MAX_PAGE_LIMIT);
        let conn = self.conn.lock();
        // Внутренний SELECT ограничивает именно ИНТЕРВАЛЫ: LIMIT после JOIN
        // обрезал бы строки текстов на границе страницы.
        let mut stmt = conn
            .prepare(
                "SELECT iv.id, iv.start_at, iv.end_at, iv.duration_s,
                        t.channel_id, t.text, t.words, t.language
                 FROM (
                     SELECT id, start_at, end_at, duration_s, start_ms
                     FROM intervals
                     ORDER BY start_ms DESC, id DESC
                     LIMIT ?1
                 ) iv
                 LEFT JOIN interval_texts t ON t.interval_id = iv.id
                 ORDER BY iv.start_ms DESC, iv.id DESC, t.rowid",
            )
            .map_err(store_err)?;
        collect_joined(&mut stmt, rusqlite::params![limit as i64])
    }

    /// Страница интервалов с keyset-пагинацией по `(start_ms, id)`.
    ///
    /// `channel` — фильтр по каналу: остаются только интервалы, где этот канал
    /// присутствует, и только его тексты. `cursor` — значение `next_cursor`
    /// предыдущей страницы (`"start_ms:id"`).
    pub fn query_intervals_page(
        &self,
        from_ms: i64,
        to_ms: i64,
        channel: Option<&str>,
        limit: u32,
        cursor: Option<&str>,
    ) -> Result<IntervalPage, CoreError> {
        let limit = limit.clamp(1, MAX_PAGE_LIMIT);
        let (cur_ms, cur_id) = match cursor {
            Some(c) => {
                let parsed = parse_cursor(c)?;
                (parsed.0, parsed.1)
            }
            None => (i64::MIN, i64::MIN),
        };
        let has_cursor = cursor.is_some();

        let conn = self.conn.lock();
        // Внутренний SELECT ограничивает именно ИНТЕРВАЛЫ (LIMIT после JOIN
        // резал бы строки текстов), внешний JOIN подтягивает каналы.
        let mut stmt = conn
            .prepare(
                "SELECT iv.id, iv.start_at, iv.end_at, iv.duration_s,
                        t.channel_id, t.text, t.words, t.language
                 FROM (
                     SELECT id, start_at, end_at, duration_s, start_ms
                     FROM intervals
                     WHERE start_ms < ?1 AND end_ms > ?2
                       AND (?3 = 0 OR start_ms > ?4 OR (start_ms = ?4 AND id > ?5))
                       AND (?6 IS NULL OR EXISTS (
                             SELECT 1 FROM interval_texts x
                             WHERE x.interval_id = intervals.id AND x.channel_id = ?6))
                     ORDER BY start_ms, id
                     LIMIT ?7
                 ) iv
                 LEFT JOIN interval_texts t ON t.interval_id = iv.id
                 ORDER BY iv.start_ms, iv.id, t.rowid",
            )
            .map_err(store_err)?;

        let mut items = collect_joined(
            &mut stmt,
            rusqlite::params![
                to_ms,
                from_ms,
                i64::from(has_cursor),
                cur_ms,
                cur_id,
                channel,
                limit as i64,
            ],
        )?;
        drop(stmt);
        drop(conn);

        if let Some(ch) = channel {
            for iv in &mut items {
                iv.channels.retain(|c| c.channel_id == ch);
            }
        }

        let next_cursor = if items.len() as u32 == limit {
            items.last().map(|iv| {
                let ms = DateTime::parse_from_rfc3339(&iv.start_at)
                    .map(|d| d.timestamp_millis())
                    .unwrap_or(0);
                format!("{ms}:{}", iv.id)
            })
        } else {
            None
        };

        Ok(IntervalPage { items, next_cursor })
    }

    /// Один интервал по идентификатору.
    pub fn interval_by_id(&self, id: i64) -> Result<Option<IntervalRecord>, CoreError> {
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare(
                "SELECT iv.id, iv.start_at, iv.end_at, iv.duration_s,
                        t.channel_id, t.text, t.words, t.language
                 FROM intervals iv
                 LEFT JOIN interval_texts t ON t.interval_id = iv.id
                 WHERE iv.id = ?1
                 ORDER BY t.rowid",
            )
            .map_err(store_err)?;
        let mut out = collect_joined(&mut stmt, rusqlite::params![id])?;
        Ok(out.pop())
    }

    /// Последние [`OVERVIEW_DEFAULT_LIMIT`] интервалов (по возрастанию времени).
    ///
    /// Раньше метод читал ВСЮ таблицу; лимит держит расход памяти/диска
    /// предсказуемым. Полная выборка — через [`Store::overview_range`].
    pub fn overview(&self) -> Result<Vec<IntervalOverviewItem>, CoreError> {
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare(
                "SELECT id, start_at, end_at, duration_s, total_words
                 FROM intervals
                 ORDER BY start_ms DESC, id DESC
                 LIMIT ?1",
            )
            .map_err(store_err)?;
        let mut out = collect_overview(&mut stmt, rusqlite::params![OVERVIEW_DEFAULT_LIMIT])?;
        out.reverse();
        Ok(out)
    }

    /// Обзор за период с постраничной выборкой. ISO-8601 на входе.
    pub fn overview_range(
        &self,
        from: &str,
        to: &str,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<IntervalOverviewItem>, CoreError> {
        self.overview_range_ms(iso_to_ms(from)?, iso_to_ms(to)?, limit, offset)
    }

    /// То же, но границы в epoch-мс UTC.
    pub fn overview_range_ms(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<IntervalOverviewItem>, CoreError> {
        let limit = limit.clamp(1, MAX_PAGE_LIMIT);
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare(
                "SELECT id, start_at, end_at, duration_s, total_words
                 FROM intervals
                 WHERE start_ms < ?1 AND end_ms > ?2
                 ORDER BY start_ms, id
                 LIMIT ?3 OFFSET ?4",
            )
            .map_err(store_err)?;
        collect_overview(
            &mut stmt,
            rusqlite::params![to_ms, from_ms, limit as i64, offset as i64],
        )
    }

    pub fn log_voice_event(&self, channel_id: &str, at: &str) -> Result<(), CoreError> {
        let dt = parse_input_ts(at)?;
        let date = dt.format("%Y-%m-%d").to_string();
        let hour = dt.hour() as i64;

        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO voice_events (ts, channel_id, date, hour, ts_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![at, channel_id, date, hour, dt.timestamp_millis()],
        )
        .map_err(store_err)?;
        Ok(())
    }

    pub fn voice_activity(
        &self,
        kind: ActivityKind,
        from: &str,
        to: &str,
    ) -> Result<Vec<ActivityBucket>, CoreError> {
        match kind {
            ActivityKind::Hourly => self.voice_activity_hourly(from, to),
            ActivityKind::Daily => self.voice_activity_daily(from, to),
        }
    }

    fn voice_activity_hourly(
        &self,
        from: &str,
        to: &str,
    ) -> Result<Vec<ActivityBucket>, CoreError> {
        let from_dt = parse_input_ts(from)?;
        let to_dt = parse_input_ts(to)?;
        let raw = self.voice_events_in_range(from_dt, to_dt)?;

        let offset = *from_dt.offset();
        let mut buckets: BTreeMap<String, ChannelCounter> = BTreeMap::new();
        for (ts, channel_id) in raw {
            let dt = parse_ts(&ts)?.with_timezone(&offset);
            let key = truncate_hour(dt).to_rfc3339();
            buckets.entry(key).or_default().bump(&channel_id);
        }

        // Fill empty hourly buckets across [from, to).
        let all_channels = channel_universe(&buckets);
        let mut out = Vec::new();
        let mut cursor = truncate_hour(from_dt);
        let end = to_dt.with_timezone(&offset);
        while cursor < end {
            let key = cursor.to_rfc3339();
            let counts = match buckets.get(&key) {
                Some(c) => c.to_counts(),
                None => zero_counts(&all_channels),
            };
            out.push(ActivityBucket { ts: key, counts });
            cursor += Duration::hours(1);
        }

        Ok(out)
    }

    fn voice_activity_daily(&self, from: &str, to: &str) -> Result<Vec<ActivityBucket>, CoreError> {
        let from_dt = parse_input_ts(from)?;
        let to_dt = parse_input_ts(to)?;
        let raw = self.voice_events_in_range(from_dt, to_dt)?;

        let offset = *from_dt.offset();
        let mut buckets: BTreeMap<String, ChannelCounter> = BTreeMap::new();
        for (ts, channel_id) in raw {
            let dt = parse_ts(&ts)?.with_timezone(&offset);
            let key = dt.format("%Y-%m-%d").to_string();
            buckets.entry(key).or_default().bump(&channel_id);
        }

        // Fill empty daily buckets across [from, to) by calendar date.
        let all_channels = channel_universe(&buckets);
        let mut out = Vec::new();
        let mut cursor = truncate_day(from_dt);
        let end = to_dt.with_timezone(&offset);
        while cursor < end {
            let key = cursor.format("%Y-%m-%d").to_string();
            let counts = match buckets.get(&key) {
                Some(c) => c.to_counts(),
                None => zero_counts(&all_channels),
            };
            out.push(ActivityBucket { ts: key, counts });
            cursor += Duration::days(1);
        }

        Ok(out)
    }

    /// Сырые события речи в [from, to) — отбор по числовому `ts_ms`.
    fn voice_events_in_range(
        &self,
        from: DateTime<FixedOffset>,
        to: DateTime<FixedOffset>,
    ) -> Result<Vec<(String, String)>, CoreError> {
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare(
                "SELECT ts, channel_id
                 FROM voice_events
                 WHERE ts_ms >= ?1 AND ts_ms < ?2
                 ORDER BY ts_ms, id",
            )
            .map_err(store_err)?;
        let rows = stmt
            .query_map(
                rusqlite::params![from.timestamp_millis(), to.timestamp_millis()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(store_err)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(store_err)?);
        }
        Ok(out)
    }

    /// Полнотекстовый поиск по текстам интервалов. ISO-8601 границы (обе
    /// опциональны). Возвращает интервалы целиком, новые сверху.
    ///
    /// Для человеческой выдачи (CLI, HTTP, UI) есть [`Store::search_hits`] —
    /// он добавляет канал попадания и фрагмент вокруг совпадения.
    pub fn search(
        &self,
        query: &str,
        from: Option<&str>,
        to: Option<&str>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<IntervalRecord>, CoreError> {
        let (from_ms, to_ms) = optional_bounds_ms(from, to)?;
        self.search_ms(query, from_ms, to_ms, limit, offset)
    }

    /// То же, но границы в epoch-мс UTC.
    pub fn search_ms(
        &self,
        query: &str,
        from_ms: i64,
        to_ms: i64,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<IntervalRecord>, CoreError> {
        let ids = self.search_ids(query, from_ms, to_ms, limit, offset)?;
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(iv) = self.interval_by_id(id)? {
                out.push(iv);
            }
        }
        Ok(out)
    }

    /// Тот же поиск, что [`Store::search`], но каждый результат — [`SearchHit`]:
    /// интервал + канал совпадения + фрагмент текста вокруг него
    /// (`radius` символов контекста с каждой стороны, см. [`make_snippet`];
    /// разумный дефолт — [`SNIPPET_RADIUS`]).
    ///
    /// Порядок тот же: новые сверху, один результат на интервал, поэтому
    /// `limit`/`offset` считаются в интервалах — как и раньше.
    pub fn search_hits(
        &self,
        query: &str,
        from: Option<&str>,
        to: Option<&str>,
        limit: u32,
        offset: u32,
        radius: usize,
    ) -> Result<Vec<SearchHit>, CoreError> {
        let (from_ms, to_ms) = optional_bounds_ms(from, to)?;
        self.search_hits_ms(query, from_ms, to_ms, limit, offset, radius)
    }

    /// То же, но границы в epoch-мс UTC.
    pub fn search_hits_ms(
        &self,
        query: &str,
        from_ms: i64,
        to_ms: i64,
        limit: u32,
        offset: u32,
        radius: usize,
    ) -> Result<Vec<SearchHit>, CoreError> {
        let ids = self.search_ids(query, from_ms, to_ms, limit, offset)?;
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(iv) = self.interval_by_id(id)? {
                let (channel_id, snippet) = hit_channel(&iv, query, radius);
                out.push(SearchHit {
                    interval: iv,
                    channel_id,
                    snippet,
                });
            }
        }
        Ok(out)
    }

    /// Общая часть обоих поисков: id совпавших интервалов, новые сверху.
    fn search_ids(
        &self,
        query: &str,
        from_ms: i64,
        to_ms: i64,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<i64>, CoreError> {
        let limit = limit.clamp(1, MAX_PAGE_LIMIT);
        if query.trim().is_empty() {
            return Err(CoreError::Config("пустой поисковый запрос".into()));
        }

        let conn = self.conn.lock();
        if self.fts {
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT iv.id, iv.start_ms
                         FROM interval_texts t
                         JOIN intervals iv ON iv.id = t.interval_id
                         WHERE t.rowid IN (
                                 SELECT rowid FROM {FTS_TABLE}
                                 WHERE {FTS_TABLE} MATCH ?1)
                           AND iv.start_ms < ?2 AND iv.end_ms > ?3
                         GROUP BY iv.id
                         ORDER BY iv.start_ms DESC, iv.id DESC
                         LIMIT ?4 OFFSET ?5"
                ))
                .map_err(store_err)?;
            collect_ids(
                &mut stmt,
                rusqlite::params![
                    fts_match_expr(query),
                    to_ms,
                    from_ms,
                    limit as i64,
                    offset as i64
                ],
            )
        } else {
            let mut stmt = conn
                .prepare(
                    "SELECT iv.id, iv.start_ms
                         FROM interval_texts t
                         JOIN intervals iv ON iv.id = t.interval_id
                         WHERE t.text LIKE ?1 ESCAPE '\\'
                           AND iv.start_ms < ?2 AND iv.end_ms > ?3
                         GROUP BY iv.id
                         ORDER BY iv.start_ms DESC, iv.id DESC
                         LIMIT ?4 OFFSET ?5",
                )
                .map_err(store_err)?;
            collect_ids(
                &mut stmt,
                rusqlite::params![
                    format!("%{}%", like_escape(query.trim())),
                    to_ms,
                    from_ms,
                    limit as i64,
                    offset as i64
                ],
            )
        }
    }

    // ---- сессии записи ----

    /// Открыть сессию записи и вернуть её идентификатор.
    ///
    /// `started_at` — ISO-8601 с таймзоной (как у интервалов); `started_ms`
    /// считается из него. Уже существующие НЕЗАКРЫТЫЕ сессии не трогаются: это
    /// исторический факт «тогда приложение закрылось, не остановив запись», а
    /// не мусор, который надо подчистить.
    pub fn open_session(&self, started_at: &str) -> Result<i64, CoreError> {
        let started_ms = iso_to_ms(started_at)?;
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO sessions (started_at, started_ms) VALUES (?1, ?2)",
            rusqlite::params![started_at, started_ms],
        )
        .map_err(store_err)?;
        Ok(conn.last_insert_rowid())
    }

    /// Закрыть сессию: `ended_at`/`ended_ms` + причина
    /// ([`SESSION_STOP_USER`] или [`SESSION_STOP_ERROR`]).
    ///
    /// Идемпотентно и «первая причина побеждает»: `WHERE ended_at IS NULL`.
    /// Закрыть сессию могут разные пути (штатный `stop()`, паника DSP,
    /// watchdog), и переписывать уже записанную причину нельзя — иначе
    /// авария маскируется последующей штатной остановкой. Возвращает `true`,
    /// если этот вызов действительно закрыл сессию.
    pub fn close_session(
        &self,
        id: i64,
        ended_at: &str,
        stop_reason: &str,
    ) -> Result<bool, CoreError> {
        let ended_ms = iso_to_ms(ended_at)?;
        let conn = self.conn.lock();
        let changed = conn
            .execute(
                "UPDATE sessions SET ended_at = ?2, ended_ms = ?3, stop_reason = ?4
                 WHERE id = ?1 AND ended_at IS NULL",
                rusqlite::params![id, ended_at, ended_ms, stop_reason],
            )
            .map_err(store_err)?;
        Ok(changed > 0)
    }

    /// Сессии записи за период. ISO-8601 с таймзоной на входе (как у
    /// [`Store::query_intervals`]).
    pub fn sessions(&self, from: &str, to: &str) -> Result<Vec<SessionRecord>, CoreError> {
        self.sessions_ms(iso_to_ms(from)?, iso_to_ms(to)?)
    }

    /// То же, но границы уже в epoch-мс UTC (быстрый путь для API/CLI).
    ///
    /// Отбираются сессии, у которых в `[from, to)` попадает НАЧАЛО ИЛИ КОНЕЦ, —
    /// то есть те, что дают разделитель внутри показываемого периода. Сессия,
    /// целиком накрывающая период, границ в нём не имеет и не возвращается;
    /// незакрытая сессия (`ended_ms IS NULL`) видна только по своему началу,
    /// иначе одно старое падение приложения лезло бы во все будущие периоды.
    /// Порядок — по возрастанию времени.
    pub fn sessions_ms(&self, from_ms: i64, to_ms: i64) -> Result<Vec<SessionRecord>, CoreError> {
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare(
                "SELECT id, started_at, ended_at, stop_reason
                 FROM sessions
                 WHERE (started_ms >= ?1 AND started_ms < ?2)
                    OR (ended_ms IS NOT NULL AND ended_ms >= ?1 AND ended_ms < ?2)
                 ORDER BY started_ms, id",
            )
            .map_err(store_err)?;
        collect_sessions(&mut stmt, rusqlite::params![from_ms, to_ms])
    }

    /// Последние `limit` сессий, НОВЫЕ ПЕРВЫМИ.
    ///
    /// Для панели меню-бара: она показывает хвост истории без выбора периода.
    /// `limit` зажимается диапазоном `1..=`[`MAX_PAGE_LIMIT`].
    pub fn last_sessions(&self, limit: u32) -> Result<Vec<SessionRecord>, CoreError> {
        let limit = limit.clamp(1, MAX_PAGE_LIMIT);
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare(
                "SELECT id, started_at, ended_at, stop_reason
                 FROM sessions
                 ORDER BY started_ms DESC, id DESC
                 LIMIT ?1",
            )
            .map_err(store_err)?;
        collect_sessions(&mut stmt, rusqlite::params![limit as i64])
    }

    /// Сводка по периоду (интервалы/слова/секунды речи, поканально).
    pub fn stats(&self, from: &str, to: &str) -> Result<RangeStats, CoreError> {
        let stats = self.stats_ms(iso_to_ms(from)?, iso_to_ms(to)?)?;
        Ok(RangeStats {
            from: from.to_string(),
            to: to.to_string(),
            ..stats
        })
    }

    /// То же, но границы в epoch-мс UTC (`from`/`to` в результате — UTC ISO).
    pub fn stats_ms(&self, from_ms: i64, to_ms: i64) -> Result<RangeStats, CoreError> {
        let conn = self.conn.lock();

        let (intervals, words, duration_seconds): (i64, i64, f64) = conn
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(total_words), 0), COALESCE(SUM(duration_s), 0.0)
                 FROM intervals
                 WHERE start_ms < ?1 AND end_ms > ?2",
                rusqlite::params![to_ms, from_ms],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .map_err(store_err)?;

        let mut stmt = conn
            .prepare(
                "SELECT t.channel_id,
                        COUNT(DISTINCT t.interval_id),
                        COALESCE(SUM(t.words), 0),
                        COALESCE(SUM(iv.duration_s), 0.0)
                 FROM interval_texts t
                 JOIN intervals iv ON iv.id = t.interval_id
                 WHERE iv.start_ms < ?1 AND iv.end_ms > ?2 AND t.words > 0
                 GROUP BY t.channel_id
                 ORDER BY t.channel_id",
            )
            .map_err(store_err)?;
        let rows = stmt
            .query_map(rusqlite::params![to_ms, from_ms], |r| {
                Ok(ChannelStats {
                    channel_id: r.get(0)?,
                    intervals: r.get(1)?,
                    words: r.get(2)?,
                    speech_seconds: r.get(3)?,
                })
            })
            .map_err(store_err)?;
        let mut channels = Vec::new();
        for r in rows {
            channels.push(r.map_err(store_err)?);
        }

        Ok(RangeStats {
            from: ms_to_iso_utc(from_ms),
            to: ms_to_iso_utc(to_ms),
            intervals,
            words,
            duration_seconds,
            channels,
        })
    }

    /// Состояние файла базы (версия схемы, размер, счётчики).
    pub fn info(&self) -> Result<DbInfo, CoreError> {
        let conn = self.conn.lock();
        let version = user_version(&conn)?;
        let page_count: i64 = conn
            .query_row("PRAGMA page_count", [], |r| r.get(0))
            .map_err(store_err)?;
        let page_size: i64 = conn
            .query_row("PRAGMA page_size", [], |r| r.get(0))
            .map_err(store_err)?;
        let count = |table: &str| -> Result<i64, CoreError> {
            conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .map_err(store_err)
        };
        let intervals = count("intervals")?;
        let interval_texts = count("interval_texts")?;
        let voice_events = count("voice_events")?;
        let sessions = count("sessions")?;
        let (first_start_at, last_end_at): (Option<String>, Option<String>) = conn
            .query_row(
                "SELECT (SELECT start_at FROM intervals ORDER BY start_ms, id LIMIT 1),
                        (SELECT end_at FROM intervals ORDER BY end_ms DESC, id DESC LIMIT 1)",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(store_err)?;
        let wal_bytes = std::fs::metadata(format!("{}-wal", self.db_path))
            .map(|m| m.len())
            .unwrap_or(0);

        Ok(DbInfo {
            path: self.db_path.clone(),
            schema_version: version,
            fts5: self.fts,
            size_bytes: (page_count.max(0) as u64) * (page_size.max(0) as u64),
            wal_bytes,
            intervals,
            interval_texts,
            voice_events,
            sessions,
            first_start_at,
            last_end_at,
        })
    }

    /// Совместимость: чистит только события речи старше `days`.
    pub fn retention_sweep(&self, days: i64) -> Result<(), CoreError> {
        let cutoff_ms = retention_cutoff_ms(days);
        let conn = self.conn.lock();
        conn.execute(
            "DELETE FROM voice_events WHERE ts_ms IS NOT NULL AND ts_ms < ?1",
            rusqlite::params![cutoff_ms],
        )
        .map_err(store_err)?;
        Ok(())
    }

    /// Полная чистка старше `days` суток: `intervals` + `interval_texts` +
    /// `voice_events`. Возвращает суммарное число удалённых строк.
    ///
    /// Интервал удаляется, когда он ЗАКОНЧИЛСЯ до cutoff (`end_ms < cutoff`).
    pub fn retention_sweep_all(&self, days: i64) -> Result<u64, CoreError> {
        let cutoff_ms = retention_cutoff_ms(days);

        let mut conn = self.conn.lock();
        let tx = conn.transaction().map_err(store_err)?;
        let mut deleted: u64 = 0;
        deleted += tx
            .execute(
                "DELETE FROM interval_texts
                 WHERE interval_id IN (
                     SELECT id FROM intervals WHERE end_ms IS NOT NULL AND end_ms < ?1)",
                rusqlite::params![cutoff_ms],
            )
            .map_err(store_err)? as u64;
        deleted += tx
            .execute(
                "DELETE FROM intervals WHERE end_ms IS NOT NULL AND end_ms < ?1",
                rusqlite::params![cutoff_ms],
            )
            .map_err(store_err)? as u64;
        deleted += tx
            .execute(
                "DELETE FROM voice_events WHERE ts_ms IS NOT NULL AND ts_ms < ?1",
                rusqlite::params![cutoff_ms],
            )
            .map_err(store_err)? as u64;
        tx.commit().map_err(store_err)?;
        Ok(deleted)
    }

    /// Сжать файл базы (после большой чистки). Блокирует запись — вызывать
    /// в обслуживании, не в горячем пути.
    pub fn vacuum(&self) -> Result<(), CoreError> {
        let conn = self.conn.lock();
        conn.execute_batch("VACUUM;").map_err(store_err)
    }

    /// Дешёвое обслуживание: обновить статистику планировщика и подрезать WAL.
    pub fn optimize(&self) -> Result<(), CoreError> {
        let conn = self.conn.lock();
        conn.execute_batch("PRAGMA optimize;").map_err(store_err)?;
        // Возвращаемые строки чекпойнта не нужны — важен побочный эффект.
        let _ = conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Миграции
// ---------------------------------------------------------------------------

fn user_version(conn: &Connection) -> Result<i64, CoreError> {
    conn.query_row("PRAGMA user_version", [], |r| r.get(0))
        .map_err(store_err)
}

fn table_exists(conn: &Connection, name: &str) -> Result<bool, CoreError> {
    let n: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table','view') AND name = ?1",
            rusqlite::params![name],
            |r| r.get(0),
        )
        .map_err(store_err)?;
    Ok(n > 0)
}

/// Приводит базу к [`SCHEMA_VERSION`], шаг за шагом, каждый шаг — транзакция.
///
/// Базы, созданные до версионирования, не имеют `user_version`, но имеют
/// таблицы — такие считаем v1 и просто проставляем версию.
fn migrate(conn: &mut Connection) -> Result<(), CoreError> {
    let mut version = user_version(conn)?;

    if version == 0 && table_exists(conn, "intervals")? {
        conn.execute_batch("PRAGMA user_version = 1;")
            .map_err(store_err)?;
        version = 1;
    }

    if version > SCHEMA_VERSION {
        return Err(CoreError::Store(format!(
            "схема базы версии {version} новее поддерживаемой ({SCHEMA_VERSION}); \
             обновите приложение или укажите другой файл базы"
        )));
    }

    while version < SCHEMA_VERSION {
        let next = version + 1;
        let tx = conn.transaction().map_err(store_err)?;
        match next {
            1 => migrate_to_v1(&tx)?,
            2 => migrate_to_v2(&tx)?,
            3 => migrate_to_v3(&tx)?,
            other => {
                return Err(CoreError::Store(format!(
                    "нет миграции на версию схемы {other}"
                )))
            }
        }
        tx.execute_batch(&format!("PRAGMA user_version = {next};"))
            .map_err(store_err)?;
        tx.commit().map_err(store_err)?;
        version = next;
    }

    Ok(())
}

/// v1 — исходная схема (ISO-строки времени).
fn migrate_to_v1(tx: &rusqlite::Transaction<'_>) -> Result<(), CoreError> {
    tx.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS intervals (
            id          INTEGER PRIMARY KEY,
            start_at    TEXT    NOT NULL,
            end_at      TEXT    NOT NULL,
            duration_s  REAL    NOT NULL,
            total_words INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_intervals_start_at
            ON intervals(start_at);

        CREATE TABLE IF NOT EXISTS interval_texts (
            interval_id INTEGER NOT NULL,
            channel_id  TEXT    NOT NULL,
            text        TEXT    NOT NULL,
            words       INTEGER NOT NULL,
            language    TEXT    NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_interval_texts_interval_id
            ON interval_texts(interval_id);

        CREATE TABLE IF NOT EXISTS voice_events (
            id         INTEGER PRIMARY KEY,
            ts         TEXT    NOT NULL,
            channel_id TEXT    NOT NULL,
            date       TEXT    NOT NULL,
            hour       INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_voice_events_ts
            ON voice_events(ts);
        CREATE INDEX IF NOT EXISTS idx_voice_events_channel_date
            ON voice_events(channel_id, date);
        "#,
    )
    .map_err(store_err)
}

/// v2 — числовое время (epoch-мс UTC) + индексы + backfill из ISO-строк.
fn migrate_to_v2(tx: &rusqlite::Transaction<'_>) -> Result<(), CoreError> {
    tx.execute_batch(
        r#"
        ALTER TABLE intervals    ADD COLUMN start_ms INTEGER;
        ALTER TABLE intervals    ADD COLUMN end_ms   INTEGER;
        ALTER TABLE voice_events ADD COLUMN ts_ms    INTEGER;
        CREATE INDEX IF NOT EXISTS idx_intervals_start_ms   ON intervals(start_ms);
        CREATE INDEX IF NOT EXISTS idx_intervals_end_ms     ON intervals(end_ms);
        CREATE INDEX IF NOT EXISTS idx_voice_events_ts_ms   ON voice_events(ts_ms);
        "#,
    )
    .map_err(store_err)?;

    // Backfill: ISO-строки -> epoch-мс. Нечитаемые строки оставляем NULL —
    // такие строки просто не попадают в диапазонные выборки (и это честнее,
    // чем подставить произвольное время).
    let intervals: Vec<(i64, String, String)> = {
        let mut stmt = tx
            .prepare("SELECT id, start_at, end_at FROM intervals")
            .map_err(store_err)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(store_err)?;
        rows.collect::<Result<_, _>>().map_err(store_err)?
    };
    {
        let mut upd = tx
            .prepare("UPDATE intervals SET start_ms = ?2, end_ms = ?3 WHERE id = ?1")
            .map_err(store_err)?;
        for (id, start_at, end_at) in intervals {
            match (
                DateTime::parse_from_rfc3339(&start_at),
                DateTime::parse_from_rfc3339(&end_at),
            ) {
                (Ok(s), Ok(e)) => {
                    upd.execute(rusqlite::params![
                        id,
                        s.timestamp_millis(),
                        e.timestamp_millis()
                    ])
                    .map_err(store_err)?;
                }
                _ => log::warn!("store: interval {id} has unparsable timestamps, ms left NULL"),
            }
        }
    }

    let events: Vec<(i64, String)> = {
        let mut stmt = tx
            .prepare("SELECT id, ts FROM voice_events")
            .map_err(store_err)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(store_err)?;
        rows.collect::<Result<_, _>>().map_err(store_err)?
    };
    {
        let mut upd = tx
            .prepare("UPDATE voice_events SET ts_ms = ?2 WHERE id = ?1")
            .map_err(store_err)?;
        for (id, ts) in events {
            match DateTime::parse_from_rfc3339(&ts) {
                Ok(t) => {
                    upd.execute(rusqlite::params![id, t.timestamp_millis()])
                        .map_err(store_err)?;
                }
                Err(_) => log::warn!("store: voice_event {id} has unparsable ts, ms left NULL"),
            }
        }
    }

    Ok(())
}

/// v3 — таблица сессий записи (только CREATE, существующие данные не трогает).
///
/// Ничего не переносит и не переписывает: до v3 факта «здесь запись включили»
/// в базе просто не было, восстанавливать его из интервалов было бы
/// эвристикой. Поэтому у обновлённой базы история сессий начинается с первого
/// запуска новой версии, а старые интервалы остаются как есть.
fn migrate_to_v3(tx: &rusqlite::Transaction<'_>) -> Result<(), CoreError> {
    tx.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS sessions (
            id          INTEGER PRIMARY KEY,
            started_at  TEXT    NOT NULL,
            started_ms  INTEGER NOT NULL,
            ended_at    TEXT,
            ended_ms    INTEGER,
            stop_reason TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_started_ms ON sessions(started_ms);
        "#,
    )
    .map_err(store_err)
}

// ---------------------------------------------------------------------------
// FTS5
// ---------------------------------------------------------------------------

/// Умеет ли эта сборка SQLite FTS5 (проверяем созданием временной таблицы).
fn fts5_available(conn: &Connection) -> bool {
    conn.execute_batch(
        "CREATE VIRTUAL TABLE temp.__fts5_probe USING fts5(x);
         DROP TABLE temp.__fts5_probe;",
    )
    .is_ok()
}

/// Создаёт (если нужно и если FTS5 доступен) полнотекстовый индекс над
/// `interval_texts.text` и триггеры синхронизации. Возвращает, есть ли индекс.
///
/// Вызывается на каждом открытии, а не только в миграции: база могла быть
/// мигрирована сборкой без FTS5, а сейчас он есть (и наоборот — тогда просто
/// работает LIKE-фолбэк).
fn ensure_fts(conn: &Connection) -> bool {
    if table_exists(conn, FTS_TABLE).unwrap_or(false) {
        // Таблица может числиться в схеме, но быть неработоспособной (базу
        // правили сборкой SQLite без FTS5, теневые таблицы потерялись). Тогда
        // честнее считать индекс отсутствующим и уйти в LIKE-фолбэк, чем
        // отдавать 500 на каждый поиск.
        let usable = conn
            .query_row(
                &format!("SELECT COUNT(*) FROM {FTS_TABLE} WHERE {FTS_TABLE} MATCH 'chronica'"),
                [],
                |r| r.get::<_, i64>(0),
            )
            .is_ok();
        if usable {
            return true;
        }
        log::warn!("store: FTS5-индекс {FTS_TABLE} неработоспособен, поиск через LIKE");
        return false;
    }
    if !fts5_available(conn) {
        log::info!("store: FTS5 недоступен, поиск работает через LIKE");
        return false;
    }
    let ddl = format!(
        r#"
        CREATE VIRTUAL TABLE {FTS_TABLE} USING fts5(
            text,
            content='interval_texts',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER IF NOT EXISTS interval_texts_ai AFTER INSERT ON interval_texts BEGIN
            INSERT INTO {FTS_TABLE}(rowid, text) VALUES (new.rowid, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS interval_texts_ad AFTER DELETE ON interval_texts BEGIN
            INSERT INTO {FTS_TABLE}({FTS_TABLE}, rowid, text)
                VALUES ('delete', old.rowid, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS interval_texts_au AFTER UPDATE ON interval_texts BEGIN
            INSERT INTO {FTS_TABLE}({FTS_TABLE}, rowid, text)
                VALUES ('delete', old.rowid, old.text);
            INSERT INTO {FTS_TABLE}(rowid, text) VALUES (new.rowid, new.text);
        END;
        INSERT INTO {FTS_TABLE}({FTS_TABLE}) VALUES ('rebuild');
        "#
    );
    match conn.execute_batch(&ddl) {
        Ok(()) => true,
        Err(e) => {
            log::warn!("store: не удалось создать FTS5-индекс ({e}); поиск через LIKE");
            false
        }
    }
}

/// Пользовательский запрос → безопасное выражение FTS5 MATCH.
///
/// Каждое слово оборачивается в кавычки как фраза (внутренние кавычки
/// удваиваются), слова соединяются неявным AND. Так произвольный ввод не может
/// стать синтаксической ошибкой FTS5 и не превращается в 500.
fn fts_match_expr(query: &str) -> String {
    let terms: Vec<String> = query
        .split_whitespace()
        .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
        .collect();
    terms.join(" ")
}

/// Экранирование спецсимволов LIKE (`\` — ESCAPE-символ в наших запросах).
fn like_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' | '%' | '_' => {
                out.push('\\');
                out.push(c);
            }
            _ => out.push(c),
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Вспомогательное
// ---------------------------------------------------------------------------

/// Курсор `start_ms:id`.
fn parse_cursor(cursor: &str) -> Result<(i64, i64), CoreError> {
    let bad = || {
        CoreError::Config(format!(
            "невалидный cursor {cursor:?}: ожидается start_ms:id"
        ))
    };
    let (ms, id) = cursor.split_once(':').ok_or_else(bad)?;
    let ms: i64 = ms.trim().parse().map_err(|_| bad())?;
    let id: i64 = id.trim().parse().map_err(|_| bad())?;
    Ok((ms, id))
}

/// Начало окна хранения: «сейчас минус `days` суток» в epoch-мс UTC.
fn retention_cutoff_ms(days: i64) -> i64 {
    (Utc::now() - Duration::days(days.max(0))).timestamp_millis()
}

/// Собирает `IntervalRecord`-ы из результата JOIN-а intervals × interval_texts.
/// Строки должны идти сгруппированно по интервалу.
fn collect_joined(
    stmt: &mut rusqlite::Statement<'_>,
    params: &[&dyn rusqlite::ToSql],
) -> Result<Vec<IntervalRecord>, CoreError> {
    let mut rows = stmt.query(params).map_err(store_err)?;
    let mut out: Vec<IntervalRecord> = Vec::new();
    while let Some(row) = rows.next().map_err(store_err)? {
        let id: i64 = row.get(0).map_err(store_err)?;
        if out.last().map(|iv| iv.id) != Some(id) {
            out.push(IntervalRecord {
                id,
                start_at: row.get(1).map_err(store_err)?,
                end_at: row.get(2).map_err(store_err)?,
                duration_s: row.get(3).map_err(store_err)?,
                channels: Vec::new(),
            });
        }
        // LEFT JOIN: интервал без текстов даёт одну строку с NULL-ами.
        let channel_id: Option<String> = row.get(4).map_err(store_err)?;
        if let Some(channel_id) = channel_id {
            let iv = out.last_mut().expect("interval pushed above");
            iv.channels.push(ChannelText {
                channel_id,
                text: row.get(5).map_err(store_err)?,
                words: row.get(6).map_err(store_err)?,
                language: row.get(7).map_err(store_err)?,
            });
        }
    }
    Ok(out)
}

/// Строки `sessions` → [`SessionRecord`]. NULL-колонки становятся пустыми
/// строками: `Option` в FFI-контрактах ядра не используется, а «пусто» здесь
/// однозначно читается как «сессия не закрыта».
fn collect_sessions(
    stmt: &mut rusqlite::Statement<'_>,
    params: &[&dyn rusqlite::ToSql],
) -> Result<Vec<SessionRecord>, CoreError> {
    let rows = stmt
        .query_map(params, |row| {
            let ended_at: Option<String> = row.get(2)?;
            let stop_reason: Option<String> = row.get(3)?;
            Ok(SessionRecord {
                id: row.get(0)?,
                started_at: row.get(1)?,
                ended_at: ended_at.unwrap_or_default(),
                stop_reason: stop_reason.unwrap_or_default(),
            })
        })
        .map_err(store_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(store_err)?);
    }
    Ok(out)
}

fn collect_overview(
    stmt: &mut rusqlite::Statement<'_>,
    params: &[&dyn rusqlite::ToSql],
) -> Result<Vec<IntervalOverviewItem>, CoreError> {
    let rows = stmt
        .query_map(params, |row| {
            Ok(IntervalOverviewItem {
                id: row.get(0)?,
                start_at: row.get(1)?,
                end_at: row.get(2)?,
                duration_s: row.get(3)?,
                total_words: row.get(4)?,
            })
        })
        .map_err(store_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(store_err)?);
    }
    Ok(out)
}

fn collect_ids(
    stmt: &mut rusqlite::Statement<'_>,
    params: &[&dyn rusqlite::ToSql],
) -> Result<Vec<i64>, CoreError> {
    let rows = stmt
        .query_map(params, |row| row.get(0))
        .map_err(store_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(store_err)?);
    }
    Ok(out)
}

/// Counts per channel, preserving the order channels were first seen.
#[derive(Default)]
struct ChannelCounter {
    order: Vec<String>,
    counts: std::collections::HashMap<String, u32>,
}

impl ChannelCounter {
    fn bump(&mut self, channel_id: &str) {
        if !self.counts.contains_key(channel_id) {
            self.order.push(channel_id.to_string());
        }
        *self.counts.entry(channel_id.to_string()).or_insert(0) += 1;
    }

    fn to_counts(&self) -> Vec<ChannelCount> {
        self.order
            .iter()
            .map(|ch| ChannelCount {
                channel_id: ch.clone(),
                count: *self.counts.get(ch).unwrap_or(&0),
            })
            .collect()
    }
}

/// Collect every channel id seen across all populated buckets (sorted, so
/// empty buckets get a stable channel set).
fn channel_universe(buckets: &BTreeMap<String, ChannelCounter>) -> Vec<String> {
    let mut set: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for c in buckets.values() {
        for ch in &c.order {
            set.insert(ch.clone());
        }
    }
    set.into_iter().collect()
}

fn zero_counts(channels: &[String]) -> Vec<ChannelCount> {
    channels
        .iter()
        .map(|ch| ChannelCount {
            channel_id: ch.clone(),
            count: 0,
        })
        .collect()
}

fn truncate_hour(dt: DateTime<FixedOffset>) -> DateTime<FixedOffset> {
    dt.with_minute(0)
        .and_then(|d| d.with_second(0))
        .and_then(|d| d.with_nanosecond(0))
        .unwrap_or(dt)
}

fn truncate_day(dt: DateTime<FixedOffset>) -> DateTime<FixedOffset> {
    dt.with_hour(0)
        .and_then(|d| d.with_minute(0))
        .and_then(|d| d.with_second(0))
        .and_then(|d| d.with_nanosecond(0))
        .unwrap_or(dt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::ChannelText;

    fn temp_store() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.db");
        let store = Store::open(path.to_str().unwrap()).unwrap();
        (dir, store)
    }

    fn ct(channel: &str, text: &str, words: u32, lang: &str) -> ChannelText {
        ChannelText {
            channel_id: channel.into(),
            text: text.into(),
            words,
            language: lang.into(),
        }
    }

    #[test]
    fn write_and_query_overlap() {
        let (_dir, store) = temp_store();

        let id = store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[
                    ct("mic", "hello world", 2, "en"),
                    ct("remote", "привет", 1, "ru"),
                ],
            )
            .unwrap();
        assert!(id > 0);

        // Overlapping range.
        let got = store
            .query_intervals("2026-06-18T10:00:30+00:00", "2026-06-18T11:00:00+00:00")
            .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].id, id);
        assert_eq!(got[0].channels.len(), 2);
        let mic = got[0]
            .channels
            .iter()
            .find(|c| c.channel_id == "mic")
            .unwrap();
        assert_eq!(mic.text, "hello world");
        assert_eq!(mic.words, 2);

        // Non-overlapping range (entirely after the interval).
        let none = store
            .query_intervals("2026-06-18T12:00:00+00:00", "2026-06-18T13:00:00+00:00")
            .unwrap();
        assert!(none.is_empty());

        // Non-overlapping range (entirely before).
        let none2 = store
            .query_intervals("2026-06-18T08:00:00+00:00", "2026-06-18T09:00:00+00:00")
            .unwrap();
        assert!(none2.is_empty());
    }

    #[test]
    fn query_sorted_by_start_at() {
        let (_dir, store) = temp_store();
        store
            .write_interval(
                "2026-06-18T11:00:00+00:00",
                "2026-06-18T11:01:00+00:00",
                60.0,
                &[ct("mic", "second", 1, "en")],
            )
            .unwrap();
        store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[ct("mic", "first", 1, "en")],
            )
            .unwrap();

        let got = store
            .query_intervals("2026-06-18T00:00:00+00:00", "2026-06-19T00:00:00+00:00")
            .unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].start_at, "2026-06-18T10:00:00+00:00");
        assert_eq!(got[1].start_at, "2026-06-18T11:00:00+00:00");
    }

    /// Разные локальные смещения: лексикографическое сравнение ISO-строк здесь
    /// врёт, числовое — нет.
    #[test]
    fn range_query_is_timezone_correct() {
        let (_dir, store) = temp_store();
        // 09:30 в зоне +03:00 == 06:30 UTC.
        store
            .write_interval(
                "2026-06-18T09:30:00+03:00",
                "2026-06-18T09:40:00+03:00",
                600.0,
                &[ct("mic", "утро", 1, "ru")],
            )
            .unwrap();

        // Запрос в UTC вокруг 06:30 обязан найти интервал.
        let got = store
            .query_intervals("2026-06-18T06:00:00+00:00", "2026-06-18T07:00:00+00:00")
            .unwrap();
        assert_eq!(
            got.len(),
            1,
            "интервал должен находиться по мировому времени"
        );

        // А запрос вокруг 09:30 UTC — не должен.
        let none = store
            .query_intervals("2026-06-18T09:00:00+00:00", "2026-06-18T10:00:00+00:00")
            .unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn invalid_iso_is_config_error() {
        let (_dir, store) = temp_store();
        let err = store.query_intervals("not-a-date", "2026-01-01T00:00:00Z");
        assert!(matches!(err, Err(CoreError::Config(_))), "{err:?}");
        let err = store.write_interval("nope", "nope", 1.0, &[]);
        assert!(matches!(err, Err(CoreError::Config(_))), "{err:?}");
        let err = store.log_voice_event("mic", "nope");
        assert!(matches!(err, Err(CoreError::Config(_))), "{err:?}");
    }

    #[test]
    fn overview_total_words() {
        let (_dir, store) = temp_store();
        store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[ct("mic", "a b c", 3, "en"), ct("remote", "d e", 2, "en")],
            )
            .unwrap();

        let ov = store.overview().unwrap();
        assert_eq!(ov.len(), 1);
        assert_eq!(ov[0].total_words, 5);
        assert_eq!(ov[0].duration_s, 60.0);
    }

    #[test]
    fn overview_range_paginates() {
        let (_dir, store) = temp_store();
        for h in 0..5 {
            store
                .write_interval(
                    &format!("2026-06-18T1{h}:00:00+00:00"),
                    &format!("2026-06-18T1{h}:01:00+00:00"),
                    60.0,
                    &[ct("mic", "x", 1, "en")],
                )
                .unwrap();
        }
        let page = store
            .overview_range(
                "2026-06-18T00:00:00+00:00",
                "2026-06-19T00:00:00+00:00",
                2,
                0,
            )
            .unwrap();
        assert_eq!(page.len(), 2);
        assert_eq!(page[0].start_at, "2026-06-18T10:00:00+00:00");

        let page2 = store
            .overview_range(
                "2026-06-18T00:00:00+00:00",
                "2026-06-19T00:00:00+00:00",
                2,
                2,
            )
            .unwrap();
        assert_eq!(page2.len(), 2);
        assert_eq!(page2[0].start_at, "2026-06-18T12:00:00+00:00");
    }

    #[test]
    fn interval_page_cursor_walks_all_rows() {
        let (_dir, store) = temp_store();
        for h in 0..5 {
            store
                .write_interval(
                    &format!("2026-06-18T1{h}:00:00+00:00"),
                    &format!("2026-06-18T1{h}:01:00+00:00"),
                    60.0,
                    &[ct("mic", "x", 1, "en")],
                )
                .unwrap();
        }
        let from = iso_to_ms("2026-06-18T00:00:00+00:00").unwrap();
        let to = iso_to_ms("2026-06-19T00:00:00+00:00").unwrap();

        let mut seen = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..10 {
            let page = store
                .query_intervals_page(from, to, None, 2, cursor.as_deref())
                .unwrap();
            seen.extend(page.items.iter().map(|i| i.id));
            match page.next_cursor {
                Some(c) => cursor = Some(c),
                None => break,
            }
        }
        assert_eq!(
            seen.len(),
            5,
            "курсор должен обойти все интервалы: {seen:?}"
        );
        let mut sorted = seen.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), 5, "без дублей: {seen:?}");
    }

    #[test]
    fn interval_page_channel_filter() {
        let (_dir, store) = temp_store();
        store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[ct("mic", "hello", 1, "en"), ct("remote", "world", 1, "en")],
            )
            .unwrap();
        store
            .write_interval(
                "2026-06-18T11:00:00+00:00",
                "2026-06-18T11:01:00+00:00",
                60.0,
                &[ct("remote", "only remote", 2, "en")],
            )
            .unwrap();

        let from = iso_to_ms("2026-06-18T00:00:00+00:00").unwrap();
        let to = iso_to_ms("2026-06-19T00:00:00+00:00").unwrap();
        let page = store
            .query_intervals_page(from, to, Some("mic"), 100, None)
            .unwrap();
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].channels.len(), 1);
        assert_eq!(page.items[0].channels[0].channel_id, "mic");
        assert!(page.next_cursor.is_none());
    }

    #[test]
    fn interval_by_id_roundtrip() {
        let (_dir, store) = temp_store();
        let id = store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[ct("mic", "hello", 1, "en")],
            )
            .unwrap();
        let got = store.interval_by_id(id).unwrap().expect("interval exists");
        assert_eq!(got.id, id);
        assert_eq!(got.channels.len(), 1);
        assert!(store.interval_by_id(id + 999).unwrap().is_none());
    }

    #[test]
    fn voice_activity_hourly_fills_and_counts() {
        let (_dir, store) = temp_store();

        // Two events at 10:xx on mic, one at 10:xx on remote, one at 12:xx on mic.
        store
            .log_voice_event("mic", "2026-06-18T10:05:00+00:00")
            .unwrap();
        store
            .log_voice_event("mic", "2026-06-18T10:40:00+00:00")
            .unwrap();
        store
            .log_voice_event("remote", "2026-06-18T10:50:00+00:00")
            .unwrap();
        store
            .log_voice_event("mic", "2026-06-18T12:15:00+00:00")
            .unwrap();

        let buckets = store
            .voice_activity(
                ActivityKind::Hourly,
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T13:00:00+00:00",
            )
            .unwrap();

        // Hours 10, 11, 12 => 3 buckets, the 11:00 one must be present (empty).
        assert_eq!(buckets.len(), 3);

        // 10:00 bucket
        let h10 = &buckets[0];
        let mic10 = h10.counts.iter().find(|c| c.channel_id == "mic").unwrap();
        assert_eq!(mic10.count, 2);
        let rem10 = h10
            .counts
            .iter()
            .find(|c| c.channel_id == "remote")
            .unwrap();
        assert_eq!(rem10.count, 1);

        // 11:00 bucket — empty, but channels present with 0.
        let h11 = &buckets[1];
        assert!(h11.counts.iter().all(|c| c.count == 0));
        assert!(h11.counts.iter().any(|c| c.channel_id == "mic"));
        assert!(h11.counts.iter().any(|c| c.channel_id == "remote"));

        // 12:00 bucket — one mic event.
        let h12 = &buckets[2];
        let mic12 = h12.counts.iter().find(|c| c.channel_id == "mic").unwrap();
        assert_eq!(mic12.count, 1);
    }

    #[test]
    fn voice_activity_daily_fills_and_counts() {
        let (_dir, store) = temp_store();

        store
            .log_voice_event("mic", "2026-06-16T10:00:00+00:00")
            .unwrap();
        store
            .log_voice_event("mic", "2026-06-16T12:00:00+00:00")
            .unwrap();
        // skip the 17th
        store
            .log_voice_event("remote", "2026-06-18T09:00:00+00:00")
            .unwrap();

        let buckets = store
            .voice_activity(
                ActivityKind::Daily,
                "2026-06-16T00:00:00+00:00",
                "2026-06-19T00:00:00+00:00",
            )
            .unwrap();

        // 16, 17, 18 => 3 days, empty 17th filled.
        assert_eq!(buckets.len(), 3);
        assert_eq!(buckets[0].ts, "2026-06-16");
        assert_eq!(buckets[1].ts, "2026-06-17");
        assert_eq!(buckets[2].ts, "2026-06-18");

        let mic16 = buckets[0]
            .counts
            .iter()
            .find(|c| c.channel_id == "mic")
            .unwrap();
        assert_eq!(mic16.count, 2);

        // 17th empty
        assert!(buckets[1].counts.iter().all(|c| c.count == 0));

        let rem18 = buckets[2]
            .counts
            .iter()
            .find(|c| c.channel_id == "remote")
            .unwrap();
        assert_eq!(rem18.count, 1);
    }

    #[test]
    fn retention_sweep_deletes_old() {
        let (_dir, store) = temp_store();

        // Old event (well past any reasonable retention window).
        store
            .log_voice_event("mic", "2020-01-01T10:00:00+00:00")
            .unwrap();
        // Recent event (today).
        let now = Utc::now().to_rfc3339();
        store.log_voice_event("mic", &now).unwrap();

        // Keep last 30 days: the 2020 event must go, today's stays.
        store.retention_sweep(30).unwrap();

        let count: i64 = {
            let conn = store.conn.lock();
            conn.query_row("SELECT COUNT(*) FROM voice_events", [], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(count, 1);
    }

    #[test]
    fn retention_sweep_all_deletes_intervals_and_texts() {
        let (_dir, store) = temp_store();

        store
            .write_interval(
                "2020-01-01T10:00:00+00:00",
                "2020-01-01T10:01:00+00:00",
                60.0,
                &[ct("mic", "old", 1, "en")],
            )
            .unwrap();
        store
            .log_voice_event("mic", "2020-01-01T10:00:30+00:00")
            .unwrap();

        let now = Utc::now();
        let fresh_id = store
            .write_interval(
                &now.to_rfc3339(),
                &(now + Duration::seconds(60)).to_rfc3339(),
                60.0,
                &[ct("mic", "new", 1, "en")],
            )
            .unwrap();
        store.log_voice_event("mic", &now.to_rfc3339()).unwrap();

        let deleted = store.retention_sweep_all(30).unwrap();
        // 1 interval + 1 text + 1 voice event.
        assert_eq!(deleted, 3);

        let info = store.info().unwrap();
        assert_eq!(info.intervals, 1);
        assert_eq!(info.interval_texts, 1);
        assert_eq!(info.voice_events, 1);
        assert!(store.interval_by_id(fresh_id).unwrap().is_some());
    }

    #[test]
    fn vacuum_and_optimize_run() {
        let (_dir, store) = temp_store();
        store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[ct("mic", "hi", 1, "en")],
            )
            .unwrap();
        store.optimize().unwrap();
        store.vacuum().unwrap();
        assert_eq!(store.info().unwrap().intervals, 1);
    }

    #[test]
    fn search_finds_words_and_respects_range() {
        let (_dir, store) = temp_store();
        store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[ct("mic", "обсудили релиз Chronica", 3, "ru")],
            )
            .unwrap();
        store
            .write_interval(
                "2026-06-19T10:00:00+00:00",
                "2026-06-19T10:01:00+00:00",
                60.0,
                &[ct("remote", "quarterly planning meeting", 3, "en")],
            )
            .unwrap();

        let hits = store.search("релиз", None, None, 10, 0).unwrap();
        assert_eq!(hits.len(), 1, "нашли только один интервал: {hits:?}");
        assert!(hits[0].channels[0].text.contains("релиз"));

        let hits = store.search("planning", None, None, 10, 0).unwrap();
        assert_eq!(hits.len(), 1);

        // Ограничение по периоду отсекает второй интервал.
        let hits = store
            .search(
                "planning",
                Some("2026-06-18T00:00:00+00:00"),
                Some("2026-06-19T00:00:00+00:00"),
                10,
                0,
            )
            .unwrap();
        assert!(hits.is_empty());

        // Ничего не найдено — пустой список, не ошибка.
        assert!(store
            .search("бетельгейзе", None, None, 10, 0)
            .unwrap()
            .is_empty());
        // Пустой запрос — ошибка ввода.
        assert!(matches!(
            store.search("   ", None, None, 10, 0),
            Err(CoreError::Config(_))
        ));
    }

    /// `search_hits` — то же множество результатов, что у `search`, плюс канал
    /// попадания и фрагмент вокруг совпадения (а не весь текст интервала).
    #[test]
    fn search_hits_carry_channel_and_snippet() {
        let (_dir, store) = temp_store();
        let long = format!(
            "{} обсудили релиз Chronica и подписи {}",
            "начало разговора ".repeat(30),
            "дальше про другое ".repeat(30)
        );
        store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[
                    ct("mic", "совсем про другое", 3, "ru"),
                    ct("remote", &long, 120, "ru"),
                ],
            )
            .unwrap();
        store
            .write_interval(
                "2026-06-19T10:00:00+00:00",
                "2026-06-19T10:01:00+00:00",
                60.0,
                &[ct("mic", "релиз перенесли", 2, "ru")],
            )
            .unwrap();

        let hits = store
            .search_hits("релиз", None, None, 10, 0, SNIPPET_RADIUS)
            .unwrap();
        // Один результат на интервал, новые сверху.
        assert_eq!(hits.len(), 2, "{hits:?}");
        assert!(hits[0].interval.start_at > hits[1].interval.start_at);

        // Канал выбирается тот, в котором реально нашлось слово.
        let long_hit = hits
            .iter()
            .find(|h| h.interval.channels.len() == 2)
            .expect("интервал с двумя каналами");
        assert_eq!(long_hit.channel_id, "remote");
        assert!(long_hit.snippet.contains("«релиз»"), "{}", long_hit.snippet);
        // Фрагмент — а не весь текст интервала.
        assert!(
            long_hit.snippet.chars().count() < long.chars().count() / 2,
            "фрагмент должен быть коротким: {}",
            long_hit.snippet
        );
        // Полный текст по-прежнему доступен в интервале.
        assert!(long_hit
            .interval
            .channels
            .iter()
            .any(|c| c.text.chars().count() == long.chars().count()));

        // Границы и пустой запрос ведут себя как у `search`.
        assert!(store
            .search_hits("бетельгейзе", None, None, 10, 0, SNIPPET_RADIUS)
            .unwrap()
            .is_empty());
        assert!(matches!(
            store.search_hits("  ", None, None, 10, 0, SNIPPET_RADIUS),
            Err(CoreError::Config(_))
        ));
    }

    /// Фрагмент: кириллица, регистр, границы слов, несколько слов запроса.
    #[test]
    fn make_snippet_cuts_around_the_match() {
        let text = "Первое предложение про погоду. \
                    Затем мы обсудили релиз Chronica и подписи для нотаризации. \
                    И ещё длинный хвост, который во фрагмент попасть не должен, \
                    потому что он далеко от совпадения и только мешает читать.";

        let s = make_snippet(text, "Релиз", 30);
        // Регистр запроса не важен, совпадение выделено маркерами.
        assert!(s.contains("«релиз»"), "{s}");
        // Текст обрезан с двух сторон и это видно.
        assert!(s.starts_with('…') && s.ends_with('…'), "{s}");
        // Края не рвут слова: каждое слово фрагмента есть в исходном тексте.
        for word in s.trim_matches('…').split_whitespace() {
            let clean = word.trim_matches(|c: char| c == '«' || c == '»');
            assert!(text.contains(clean), "слово {clean:?} обрезано: {s}");
        }
        // Радиус соблюдён с запасом на дотягивание до границ слов.
        assert!(s.chars().count() < 30 * 2 + 40, "слишком длинно: {s}");

        // Несколько слов запроса — выделяются все вхождения во фрагменте.
        let s = make_snippet(text, "релиз подписи", 60);
        assert!(s.contains("«релиз»") && s.contains("«подписи»"), "{s}");

        // Короткий текст отдаётся целиком, без обрывов.
        let s = make_snippet("привет мир", "мир", 90);
        assert_eq!(s, "привет «мир»");

        // Слова запроса в тексте нет — начало текста, не паника и не пустота.
        let s = make_snippet(text, "бетельгейзе", 20);
        assert!(!s.is_empty() && !s.contains('«'), "{s}");
        assert!(text.starts_with(s.trim_end_matches('…')), "{s}");

        // Пустой текст и пустой запрос безопасны.
        assert_eq!(make_snippet("", "релиз", 90), "");
        assert!(!make_snippet(text, "   ", 20).is_empty());

        // Переводы строк схлопываются: фрагмент печатается одной строкой.
        let s = make_snippet("первая строка\nвторая строка", "вторая", 90);
        assert!(!s.contains('\n'), "{s}");
        assert_eq!(s, "первая строка «вторая» строка");
    }

    /// Фрагмент цепляется за целое слово, а не за первую подстроку внутри
    /// другого слова: иначе поиск «тест» подсвечивает «не «тест»ировали».
    #[test]
    fn make_snippet_prefers_whole_words() {
        let text = "Мы не тестировали киоски, зато потом был тест с дизайном.";
        let s = make_snippet(text, "тест", 90);
        assert!(s.contains("был «тест» с"), "{s}");
        assert!(!s.contains("«тест»ировали"), "{s}");

        // Целого слова нет — подсветка по началу слова, лучше чем ничего.
        let s = make_snippet("Мы не тестировали киоски.", "тест", 90);
        assert!(s.contains("«тест»ировали"), "{s}");
    }

    /// Спецсимволы не должны ломать ни FTS5-синтаксис, ни LIKE-фолбэк.
    #[test]
    fn search_tolerates_special_characters() {
        let (_dir, store) = temp_store();
        store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[ct("mic", "100% готово", 2, "ru")],
            )
            .unwrap();
        for q in ["\"", "AND OR NOT", "100%", "a_b", "(", "*"] {
            let res = store.search(q, None, None, 10, 0);
            assert!(res.is_ok(), "запрос {q:?} не должен падать: {res:?}");
        }
    }

    /// Удаление интервала должно вычищать и полнотекстовый индекс.
    #[test]
    fn search_index_follows_deletes() {
        let (_dir, store) = temp_store();
        store
            .write_interval(
                "2020-01-01T10:00:00+00:00",
                "2020-01-01T10:01:00+00:00",
                60.0,
                &[ct("mic", "устаревшая запись", 2, "ru")],
            )
            .unwrap();
        assert_eq!(
            store.search("устаревшая", None, None, 10, 0).unwrap().len(),
            1
        );
        store.retention_sweep_all(1).unwrap();
        assert!(store
            .search("устаревшая", None, None, 10, 0)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn stats_aggregates_by_channel() {
        let (_dir, store) = temp_store();
        store
            .write_interval(
                "2026-06-18T10:00:00+00:00",
                "2026-06-18T10:01:00+00:00",
                60.0,
                &[ct("mic", "a b c", 3, "en"), ct("remote", "d e", 2, "en")],
            )
            .unwrap();
        store
            .write_interval(
                "2026-06-18T11:00:00+00:00",
                "2026-06-18T11:00:30+00:00",
                30.0,
                &[ct("mic", "f", 1, "en")],
            )
            .unwrap();

        let s = store
            .stats("2026-06-18T00:00:00+00:00", "2026-06-19T00:00:00+00:00")
            .unwrap();
        assert_eq!(s.intervals, 2);
        assert_eq!(s.words, 6);
        assert_eq!(s.duration_seconds, 90.0);
        let mic = s.channels.iter().find(|c| c.channel_id == "mic").unwrap();
        assert_eq!(mic.words, 4);
        assert_eq!(mic.intervals, 2);
        assert_eq!(mic.speech_seconds, 90.0);
        let remote = s
            .channels
            .iter()
            .find(|c| c.channel_id == "remote")
            .unwrap();
        assert_eq!(remote.words, 2);
        assert_eq!(remote.intervals, 1);
    }

    #[test]
    fn fresh_db_is_at_current_schema_version() {
        let (_dir, store) = temp_store();
        assert_eq!(store.schema_version().unwrap(), SCHEMA_VERSION);
        let info = store.info().unwrap();
        assert_eq!(info.schema_version, SCHEMA_VERSION);
        assert!(info.size_bytes > 0);
    }

    /// База, созданная старой версией (v1-схема, без `user_version`), должна
    /// подхватиться и домигрироваться с сохранением данных.
    #[test]
    fn legacy_v1_db_migrates_and_backfills_ms() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("legacy.db");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                r#"
                CREATE TABLE intervals (
                    id INTEGER PRIMARY KEY, start_at TEXT NOT NULL, end_at TEXT NOT NULL,
                    duration_s REAL NOT NULL, total_words INTEGER NOT NULL);
                CREATE TABLE interval_texts (
                    interval_id INTEGER NOT NULL, channel_id TEXT NOT NULL, text TEXT NOT NULL,
                    words INTEGER NOT NULL, language TEXT NOT NULL);
                CREATE TABLE voice_events (
                    id INTEGER PRIMARY KEY, ts TEXT NOT NULL, channel_id TEXT NOT NULL,
                    date TEXT NOT NULL, hour INTEGER NOT NULL);
                INSERT INTO intervals (start_at, end_at, duration_s, total_words)
                    VALUES ('2026-06-18T09:30:00+03:00', '2026-06-18T09:40:00+03:00', 600.0, 2);
                INSERT INTO interval_texts (interval_id, channel_id, text, words, language)
                    VALUES (1, 'mic', 'наследие из прошлой версии', 4, 'ru');
                INSERT INTO voice_events (ts, channel_id, date, hour)
                    VALUES ('2026-06-18T09:31:00+03:00', 'mic', '2026-06-18', 9);
                "#,
            )
            .unwrap();
            // Никакого user_version — как у баз до версионирования.
            let v: i64 = conn
                .query_row("PRAGMA user_version", [], |r| r.get(0))
                .unwrap();
            assert_eq!(v, 0);
        }

        let store = Store::open(path.to_str().unwrap()).unwrap();
        assert_eq!(store.schema_version().unwrap(), SCHEMA_VERSION);

        // Backfill: интервал ищется по мировому времени (06:30 UTC).
        let got = store
            .query_intervals("2026-06-18T06:00:00+00:00", "2026-06-18T07:00:00+00:00")
            .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].channels.len(), 1);

        // voice_events тоже получили ts_ms.
        let buckets = store
            .voice_activity(
                ActivityKind::Hourly,
                "2026-06-18T06:00:00+00:00",
                "2026-06-18T07:00:00+00:00",
            )
            .unwrap();
        assert_eq!(buckets.len(), 1);
        assert_eq!(buckets[0].counts.iter().map(|c| c.count).sum::<u32>(), 1);

        // И полнотекстовый индекс построен по уже существовавшим текстам.
        if store.fts_enabled() {
            assert_eq!(
                store.search("наследие", None, None, 10, 0).unwrap().len(),
                1
            );
        }
    }

    /// База на схеме v2 (её создавал предыдущий релиз) должна домигрироваться
    /// до v3 без потери данных: интервалы, тексты и события речи остаются на
    /// месте, а таблица сессий появляется рабочей.
    #[test]
    fn v2_db_migrates_to_v3_without_losing_data() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v2.db");
        {
            // Схема ровно такая, какой её оставлял v2-код.
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                r#"
                CREATE TABLE intervals (
                    id INTEGER PRIMARY KEY, start_at TEXT NOT NULL, end_at TEXT NOT NULL,
                    duration_s REAL NOT NULL, total_words INTEGER NOT NULL,
                    start_ms INTEGER, end_ms INTEGER);
                CREATE INDEX idx_intervals_start_at ON intervals(start_at);
                CREATE INDEX idx_intervals_start_ms ON intervals(start_ms);
                CREATE INDEX idx_intervals_end_ms   ON intervals(end_ms);
                CREATE TABLE interval_texts (
                    interval_id INTEGER NOT NULL, channel_id TEXT NOT NULL, text TEXT NOT NULL,
                    words INTEGER NOT NULL, language TEXT NOT NULL);
                CREATE INDEX idx_interval_texts_interval_id ON interval_texts(interval_id);
                CREATE TABLE voice_events (
                    id INTEGER PRIMARY KEY, ts TEXT NOT NULL, channel_id TEXT NOT NULL,
                    date TEXT NOT NULL, hour INTEGER NOT NULL, ts_ms INTEGER);
                CREATE INDEX idx_voice_events_ts           ON voice_events(ts);
                CREATE INDEX idx_voice_events_channel_date ON voice_events(channel_id, date);
                CREATE INDEX idx_voice_events_ts_ms        ON voice_events(ts_ms);
                INSERT INTO intervals
                    (start_at, end_at, duration_s, total_words, start_ms, end_ms)
                    VALUES ('2026-06-18T09:30:00+03:00', '2026-06-18T09:40:00+03:00',
                            600.0, 3, 1781764200000, 1781764800000);
                INSERT INTO interval_texts (interval_id, channel_id, text, words, language)
                    VALUES (1, 'mic', 'данные из версии два', 3, 'ru');
                INSERT INTO voice_events (ts, channel_id, date, hour, ts_ms)
                    VALUES ('2026-06-18T09:31:00+03:00', 'mic', '2026-06-18', 9, 1781764260000);
                PRAGMA user_version = 2;
                "#,
            )
            .unwrap();
        }

        let store = Store::open(path.to_str().unwrap()).unwrap();
        assert_eq!(store.schema_version().unwrap(), SCHEMA_VERSION);

        // Данные v2 никуда не делись.
        let info = store.info().unwrap();
        assert_eq!(info.intervals, 1);
        assert_eq!(info.interval_texts, 1);
        assert_eq!(info.voice_events, 1);
        assert_eq!(
            info.sessions, 0,
            "у обновлённой базы истории сессий ещё нет"
        );
        let got = store.recent_intervals(10).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].channels[0].text, "данные из версии два");

        // И новая таблица работоспособна.
        let id = store.open_session("2026-06-18T10:00:00+03:00").unwrap();
        assert!(store
            .close_session(id, "2026-06-18T10:05:00+03:00", SESSION_STOP_USER)
            .unwrap());
        assert_eq!(store.last_sessions(10).unwrap().len(), 1);
    }

    /// Штатная сессия: открыли — закрыли, причина сохранилась, длительность
    /// читается из ISO-строк.
    #[test]
    fn session_open_close_round_trip() {
        let (_dir, store) = temp_store();
        let id = store.open_session("2026-09-03T10:00:00+03:00").unwrap();
        assert!(store
            .close_session(id, "2026-09-03T10:30:00+03:00", SESSION_STOP_USER)
            .unwrap());

        let got = store.last_sessions(10).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].id, id);
        assert_eq!(got[0].started_at, "2026-09-03T10:00:00+03:00");
        assert_eq!(got[0].ended_at, "2026-09-03T10:30:00+03:00");
        assert_eq!(got[0].stop_reason, SESSION_STOP_USER);
    }

    /// Незакрытая сессия — это «приложение закрылось»: читается с пустым
    /// `ended_at` и пустой причиной, а не пропадает из выборки.
    #[test]
    fn unclosed_session_reads_with_empty_end() {
        let (_dir, store) = temp_store();
        store.open_session("2026-09-03T12:00:00+03:00").unwrap();

        let got = store.last_sessions(10).unwrap();
        assert_eq!(got.len(), 1);
        assert!(got[0].ended_at.is_empty(), "конца нет: {:?}", got[0]);
        assert!(got[0].stop_reason.is_empty());
    }

    /// Причину закрытия пишет ПЕРВЫЙ, кто пришёл: авария не должна
    /// маскироваться последующим штатным `stop()`.
    #[test]
    fn first_close_reason_wins() {
        let (_dir, store) = temp_store();
        let id = store.open_session("2026-09-03T10:00:00+03:00").unwrap();
        assert!(store
            .close_session(id, "2026-09-03T10:10:00+03:00", SESSION_STOP_ERROR)
            .unwrap());
        assert!(
            !store
                .close_session(id, "2026-09-03T10:20:00+03:00", SESSION_STOP_USER)
                .unwrap(),
            "второе закрытие не должно менять запись"
        );

        let got = store.last_sessions(10).unwrap();
        assert_eq!(got[0].stop_reason, SESSION_STOP_ERROR);
        assert_eq!(got[0].ended_at, "2026-09-03T10:10:00+03:00");
    }

    /// Период отбирает сессии по ФАКТИЧЕСКИМ границам и считает их в мировом
    /// времени: сессия, записанная в +03:00, находится по UTC-границам.
    #[test]
    fn sessions_filter_by_range_in_local_zone() {
        let (_dir, store) = temp_store();
        // Внутри периода целиком.
        let inside = store.open_session("2026-09-03T10:00:00+03:00").unwrap();
        store
            .close_session(inside, "2026-09-03T10:30:00+03:00", SESSION_STOP_USER)
            .unwrap();
        // Закончилась внутри периода, началась до него.
        let tail = store.open_session("2026-09-03T06:00:00+03:00").unwrap();
        store
            .close_session(tail, "2026-09-03T09:30:00+03:00", SESSION_STOP_USER)
            .unwrap();
        // Целиком до периода.
        let before = store.open_session("2026-09-01T10:00:00+03:00").unwrap();
        store
            .close_session(before, "2026-09-01T10:30:00+03:00", SESSION_STOP_USER)
            .unwrap();

        // Период 09:00–11:00 в +03:00 = 06:00–08:00 UTC.
        let got = store
            .sessions("2026-09-03T06:00:00+00:00", "2026-09-03T08:00:00+00:00")
            .unwrap();
        let ids: Vec<i64> = got.iter().map(|s| s.id).collect();
        assert_eq!(ids, vec![tail, inside], "по возрастанию времени: {got:?}");

        // Та же выборка по локальным границам даёт тот же результат.
        let local = store
            .sessions("2026-09-03T09:00:00+03:00", "2026-09-03T11:00:00+03:00")
            .unwrap();
        assert_eq!(local, got);

        // Незакрытая сессия видна только по своему началу — одно старое
        // падение не должно лезть во все будущие периоды.
        let stale = store.open_session("2026-09-01T09:00:00+03:00").unwrap();
        assert!(store.sessions_ms(0, i64::MAX).unwrap().len() == 4);
        assert!(
            !store
                .sessions("2026-09-03T06:00:00+00:00", "2026-09-03T08:00:00+00:00")
                .unwrap()
                .iter()
                .any(|s| s.id == stale),
            "незакрытая сессия прошлых суток в сегодняшнем периоде не нужна"
        );
    }

    /// `last_sessions(limit)` отдаёт последние по времени, новые первыми.
    #[test]
    fn last_sessions_returns_newest_first() {
        let (_dir, store) = temp_store();
        let mut ids = Vec::new();
        for day in 1..=5 {
            ids.push(
                store
                    .open_session(&format!("2026-09-0{day}T10:00:00+03:00"))
                    .unwrap(),
            );
        }
        let got = store.last_sessions(2).unwrap();
        assert_eq!(
            got.iter().map(|s| s.id).collect::<Vec<_>>(),
            vec![ids[4], ids[3]]
        );
        // Потолок страницы не даёт запросить всю таблицу мимо ограничений.
        assert_eq!(store.last_sessions(u32::MAX).unwrap().len(), 5);
    }

    /// `recent_intervals(limit)` — последние N по времени, новые первыми,
    /// с текстами и без падения на пустой базе.
    #[test]
    fn recent_intervals_returns_newest_first() {
        let (_dir, store) = temp_store();
        assert!(store.recent_intervals(10).unwrap().is_empty());

        for hour in 10..15 {
            store
                .write_interval(
                    &format!("2026-09-03T{hour}:00:00+03:00"),
                    &format!("2026-09-03T{hour}:01:00+03:00"),
                    60.0,
                    &[ct("mic", &format!("реплика {hour}"), 2, "ru")],
                )
                .unwrap();
        }

        let got = store.recent_intervals(2).unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].start_at, "2026-09-03T14:00:00+03:00");
        assert_eq!(got[1].start_at, "2026-09-03T13:00:00+03:00");
        assert_eq!(got[0].channels.len(), 1, "тексты подтянуты тем же JOIN");
        assert_eq!(got[0].channels[0].text, "реплика 14");
        assert_eq!(store.recent_intervals(100).unwrap().len(), 5);
    }

    /// Многоканальный интервал не должен «обрезаться» на границе страницы:
    /// LIMIT применяется к интервалам, а не к строкам JOIN.
    #[test]
    fn recent_intervals_keeps_all_channels_of_the_last_interval() {
        let (_dir, store) = temp_store();
        store
            .write_interval(
                "2026-09-03T10:00:00+03:00",
                "2026-09-03T10:01:00+03:00",
                60.0,
                &[ct("mic", "я", 1, "ru"), ct("remote", "они", 1, "ru")],
            )
            .unwrap();
        store
            .write_interval(
                "2026-09-03T11:00:00+03:00",
                "2026-09-03T11:01:00+03:00",
                60.0,
                &[ct("mic", "позже", 1, "ru"), ct("remote", "ответ", 1, "ru")],
            )
            .unwrap();

        let got = store.recent_intervals(1).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].channels.len(), 2, "оба канала: {:?}", got[0]);
    }

    /// База из будущего не открывается молча.
    #[test]
    fn newer_schema_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("future.db");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(&format!("PRAGMA user_version = {};", SCHEMA_VERSION + 5))
                .unwrap();
        }
        match Store::open(path.to_str().unwrap()) {
            Err(CoreError::Store(msg)) => assert!(msg.contains("новее"), "{msg}"),
            Err(other) => panic!("ожидали CoreError::Store, получили {other:?}"),
            Ok(_) => panic!("база из будущего не должна открываться"),
        }
    }

    /// Повторное открытие уже мигрированной базы ничего не ломает.
    #[test]
    fn reopen_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reopen.db");
        {
            let store = Store::open(path.to_str().unwrap()).unwrap();
            store
                .write_interval(
                    "2026-06-18T10:00:00+00:00",
                    "2026-06-18T10:01:00+00:00",
                    60.0,
                    &[ct("mic", "hello", 1, "en")],
                )
                .unwrap();
        }
        let store = Store::open(path.to_str().unwrap()).unwrap();
        assert_eq!(store.schema_version().unwrap(), SCHEMA_VERSION);
        assert_eq!(store.overview().unwrap().len(), 1);
    }

    #[test]
    fn cursor_parsing_rejects_garbage() {
        assert_eq!(parse_cursor("100:7").unwrap(), (100, 7));
        assert!(parse_cursor("100").is_err());
        assert!(parse_cursor("abc:7").is_err());
    }

    #[test]
    fn like_escape_neutralizes_wildcards() {
        assert_eq!(like_escape("100%"), "100\\%");
        assert_eq!(like_escape("a_b"), "a\\_b");
        assert_eq!(like_escape("c\\d"), "c\\\\d");
        assert_eq!(like_escape("plain"), "plain");
    }

    fn sample_records() -> Vec<IntervalRecord> {
        vec![IntervalRecord {
            id: 7,
            start_at: "2026-01-01T10:00:00+00:00".into(),
            end_at: "2026-01-01T10:01:00+00:00".into(),
            duration_s: 60.0,
            channels: vec![
                ct("mic", "привет", 1, "ru"),
                // Пустая реплика не должна попадать в вывод.
                ct("remote", "  ", 0, "en"),
            ],
        }]
    }

    #[test]
    fn export_hhmm_extracts_time() {
        assert_eq!(export::hhmm("2026-01-01T10:05:00+03:00"), "10:05");
        assert_eq!(export::hhmm("нет времени"), "нет времени");
    }

    /// Документ экспорта должен совпадать по форме с `JournalExport.swift`.
    #[test]
    fn export_document_matches_app_shape() {
        let items = sample_records();
        let doc = export::journal_document(&items, "F", "T", "E");
        assert_eq!(doc["product"], "Chronica");
        assert_eq!(doc["exportedAt"], "E");
        assert_eq!(doc["from"], "F");
        assert_eq!(doc["to"], "T");
        assert!(doc["activities"].as_array().unwrap().is_empty());
        assert_eq!(doc["transcription"]["count"], 1);
        let iv = &doc["transcription"]["intervals"][0];
        assert_eq!(iv["id"], 7);
        assert_eq!(iv["startAt"], "2026-01-01T10:00:00+00:00");
        assert_eq!(iv["durationS"], 60.0);
        assert_eq!(iv["channels"][0]["channelId"], "mic");
        assert_eq!(iv["channels"][0]["words"], 1);
        assert_eq!(iv["channels"][0]["language"], "ru");
    }

    #[test]
    fn export_markdown_and_text() {
        let items = sample_records();
        let md = export::journal_markdown(&items, "F", "T", "E");
        assert!(md.starts_with("# Журнал Chronica"), "{md}");
        assert!(md.contains("## Транскрипция (1 интервалов)"), "{md}");
        assert!(md.contains("**mic** (`ru`): привет"), "{md}");
        assert!(!md.contains("remote"), "пустая реплика не выводится: {md}");

        let text = export::transcript_text(&items);
        assert_eq!(text, "[10:00] mic: привет\n");

        let tmd = export::transcript_markdown(&items, "F", "T", Some("mic"));
        assert!(tmd.starts_with("# Транскрипция Chronica"), "{tmd}");
        assert!(tmd.contains("- Канал: mic"), "{tmd}");

        // Пустая выборка не падает и остаётся валидным документом.
        assert!(export::journal_markdown(&[], "F", "T", "E").contains("Нет записанной речи"));
        assert_eq!(export::transcript_text(&[]), "");
    }

    #[test]
    fn fts_match_expr_quotes_terms() {
        assert_eq!(fts_match_expr("релиз"), "\"релиз\"");
        assert_eq!(fts_match_expr("a b"), "\"a\" \"b\"");
        assert_eq!(fts_match_expr("say \"hi\""), "\"say\" \"\"\"hi\"\"\"");
    }
}
