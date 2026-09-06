//! HTTP API v1 — стабильная поверхность для разработчиков.
//!
//! Подключается из `api.rs` (`#[path = "api_v1.rs"] mod v1;`), чтобы не трогать
//! `lib.rs`: наружу модуль не торчит, вся работа идёт через [`route`].
//!
//! Конверт ответа фиксирован:
//! ```json
//! { "ok": true,  "data": … }
//! { "ok": false, "error": { "code": "bad_request", "message": "…" } }
//! ```
//! Исключение — «файловые» ответы (`/transcript?format=text|md`, `/export`):
//! они отдают сам документ, чтобы его можно было сохранить как есть. Ошибки
//! всегда в конверте.
//!
//! Гарантия совместимости: v1 расширяется ТОЛЬКО аддитивно — новые поля и
//! эндпоинты появляются, существующие не переименовываются и не исчезают.

use chrono::{DateTime, Local, NaiveDate, TimeZone, Utc};
use serde_json::json;

use super::{get_param, HttpReply};
use crate::errors::CoreError;
use crate::metrics::Metrics;
use crate::store::export::{
    journal_document, journal_markdown, transcript_markdown, transcript_text,
};
use crate::store::{self, Store};
use crate::types::{ActivityKind, IntervalRecord};

/// Дефолтный размер страницы.
const DEFAULT_LIMIT: u32 = 100;

/// Потолок на число интервалов, которое собирают «сшивающие» эндпоинты
/// (`/transcript`, `/export`) — страховка от запроса «за всё время».
const RANGE_CAP: usize = 20_000;

/// Статическая OpenAPI-спецификация (единственный источник правды — файл).
const OPENAPI_JSON: &str = include_str!("../../docs/openapi.json");

// ---------------------------------------------------------------------------
// Конверт
// ---------------------------------------------------------------------------

fn ok_reply(data: serde_json::Value) -> HttpReply {
    HttpReply::json(200, json!({ "ok": true, "data": data }).to_string())
}

/// Ответ-ошибка в стабильном конверте. `code` — машинный, `message` — для человека.
pub(super) fn error_reply(status: u16, code: &str, message: &str) -> HttpReply {
    HttpReply::json(
        status,
        json!({ "ok": false, "error": { "code": code, "message": message } }).to_string(),
    )
}

fn bad_request(message: &str) -> HttpReply {
    error_reply(400, "bad_request", message)
}

/// Ошибка хранилища: невалидный ввод — 400, всё остальное — 500.
fn store_error(e: CoreError) -> HttpReply {
    match e {
        CoreError::Config(m) => bad_request(&m),
        other => error_reply(500, "store_error", &format!("{other}")),
    }
}

// ---------------------------------------------------------------------------
// Маршрутизация
// ---------------------------------------------------------------------------

pub(super) fn route(
    path: &str,
    query: &[(String, String)],
    store: &Store,
    metrics: &Metrics,
) -> HttpReply {
    match path {
        "/api/v1/health" => health(store),
        "/api/v1/openapi.json" => HttpReply::json(200, OPENAPI_JSON.to_string()),
        "/api/v1/state" => state(query, metrics),
        "/api/v1/intervals" => intervals(query, store),
        "/api/v1/transcript" => transcript(query, store),
        "/api/v1/search" => search(query, store),
        "/api/v1/activity" => activity(query, store),
        "/api/v1/sessions" => sessions(query, store),
        "/api/v1/export" => export(query, store),
        _ => match path.strip_prefix("/api/v1/intervals/") {
            Some(id) => interval_by_id(id, store),
            None => error_reply(404, "not_found", &format!("неизвестный путь {path}")),
        },
    }
}

// ---------------------------------------------------------------------------
// Эндпоинты
// ---------------------------------------------------------------------------

/// `GET /api/v1/health` — без токена, без приватных данных.
fn health(store: &Store) -> HttpReply {
    let db_ok = store.health_ok();
    let schema_version = store.schema_version().unwrap_or(0);
    ok_reply(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "api_version": super::API_VERSION,
        "db_ok": db_ok,
        "schema_version": schema_version,
        "fts5": store.fts_enabled(),
    }))
}

/// `GET /api/v1/state[?include=last_text]`.
fn state(query: &[(String, String)], metrics: &Metrics) -> HttpReply {
    let include_last_text = get_param(query, "include")
        .map(|v| v.split(',').any(|p| p.trim() == "last_text"))
        .unwrap_or(false);

    let snapshot = metrics.snapshot();
    let mut value = match serde_json::to_value(&snapshot) {
        Ok(v) => v,
        Err(e) => return error_reply(500, "internal", &format!("serialize state: {e}")),
    };
    if !include_last_text {
        // Последняя реплика — самое приватное поле снимка; по умолчанию не
        // отдаём его даже на loopback.
        if let Some(sources) = value.get_mut("sources").and_then(|s| s.as_array_mut()) {
            for src in sources {
                if let Some(obj) = src.as_object_mut() {
                    obj.insert("last_text".into(), json!(""));
                }
            }
        }
    }
    ok_reply(value)
}

/// `GET /api/v1/intervals?from&to&channel&limit&cursor`.
fn intervals(query: &[(String, String)], store: &Store) -> HttpReply {
    let (from, to) = match optional_range(query) {
        Ok(v) => v,
        Err(reply) => return reply,
    };
    let limit = match limit_param(query) {
        Ok(v) => v,
        Err(reply) => return reply,
    };
    let channel = non_empty(get_param(query, "channel"));
    let cursor = non_empty(get_param(query, "cursor"));

    match store.query_intervals_page(from.ms, to.ms, channel.as_deref(), limit, cursor.as_deref()) {
        Ok(page) => ok_reply(json!({
            "count": page.items.len(),
            "items": page.items,
            "next_cursor": page.next_cursor,
        })),
        Err(e) => store_error(e),
    }
}

/// `GET /api/v1/intervals/{id}`.
fn interval_by_id(id: &str, store: &Store) -> HttpReply {
    let Ok(id) = id.parse::<i64>() else {
        return bad_request(&format!("невалидный id {id:?}: ожидается целое число"));
    };
    match store.interval_by_id(id) {
        Ok(Some(iv)) => ok_reply(json!(iv)),
        Ok(None) => error_reply(404, "not_found", &format!("интервал {id} не найден")),
        Err(e) => store_error(e),
    }
}

/// `GET /api/v1/transcript?from&to&channel&format=text|json|md`.
fn transcript(query: &[(String, String)], store: &Store) -> HttpReply {
    let (from, to) = match optional_range(query) {
        Ok(v) => v,
        Err(reply) => return reply,
    };
    let channel = non_empty(get_param(query, "channel"));
    let format = get_param(query, "format").unwrap_or_else(|| "text".into());

    let items = match collect_range(store, from.ms, to.ms, channel.as_deref()) {
        Ok(v) => v,
        Err(e) => return store_error(e),
    };

    match format.as_str() {
        "text" | "" => HttpReply::text(200, transcript_text(&items)),
        "md" | "markdown" => HttpReply::markdown(
            200,
            transcript_markdown(&items, &from.iso, &to.iso, channel.as_deref()),
        ),
        "json" => ok_reply(json!({
            "from": from.iso,
            "to": to.iso,
            "channel": channel,
            "count": items.len(),
            "text": transcript_text(&items),
        })),
        other => bad_request(&format!(
            "неизвестный format {other:?}: ожидается text|json|md"
        )),
    }
}

/// `GET /api/v1/search?q&from&to&limit&cursor`.
fn search(query: &[(String, String)], store: &Store) -> HttpReply {
    let Some(q) = non_empty(get_param(query, "q")) else {
        return bad_request("нужен непустой параметр q");
    };
    let (from, to) = match optional_range(query) {
        Ok(v) => v,
        Err(reply) => return reply,
    };
    let limit = match limit_param(query) {
        Ok(v) => v,
        Err(reply) => return reply,
    };
    // Курсор поиска — смещение (`off:N`): ранжирование не даёт стабильного
    // keyset-ключа, зато смещение понятно и предсказуемо.
    let offset = match get_param(query, "cursor") {
        Some(c) if !c.is_empty() => match parse_offset_cursor(&c) {
            Some(v) => v,
            None => return bad_request(&format!("невалидный cursor {c:?}: ожидается off:N")),
        },
        _ => 0,
    };

    match store.search_hits_ms(&q, from.ms, to.ms, limit, offset, store::SNIPPET_RADIUS) {
        Ok(hits) => {
            let next = if hits.len() as u32 == limit {
                Some(format!("off:{}", offset + limit))
            } else {
                None
            };
            // Элемент — поля интервала как раньше плюс АДДИТИВНЫЕ `channel_id`
            // (канал совпадения) и `snippet` (фрагмент вокруг него).
            let items: Vec<serde_json::Value> = hits
                .iter()
                .map(|h| {
                    json!({
                        "id": h.interval.id,
                        "start_at": h.interval.start_at,
                        "end_at": h.interval.end_at,
                        "duration_s": h.interval.duration_s,
                        "channels": h.interval.channels,
                        "channel_id": h.channel_id,
                        "snippet": h.snippet,
                    })
                })
                .collect();
            ok_reply(json!({
                "engine": if store.fts_enabled() { "fts5" } else { "like" },
                "count": items.len(),
                "items": items,
                "next_cursor": next,
            }))
        }
        Err(e) => store_error(e),
    }
}

/// `GET /api/v1/activity?bucket=hour|day&from&to`.
fn activity(query: &[(String, String)], store: &Store) -> HttpReply {
    let bucket = get_param(query, "bucket").unwrap_or_else(|| "hour".into());
    let kind = match bucket.as_str() {
        "hour" | "hourly" | "" => ActivityKind::Hourly,
        "day" | "daily" => ActivityKind::Daily,
        other => return bad_request(&format!("неизвестный bucket {other:?}: ожидается hour|day")),
    };
    let (from, to) = match required_range(query) {
        Ok(v) => v,
        Err(reply) => return reply,
    };

    match store.voice_activity(kind, &from.iso, &to.iso) {
        Ok(buckets) => ok_reply(json!({
            "bucket": if matches!(kind, ActivityKind::Daily) { "day" } else { "hour" },
            "from": from.iso,
            "to": to.iso,
            "buckets": buckets,
        })),
        Err(e) => store_error(e),
    }
}

/// `GET /api/v1/sessions?from&to&limit` — сессии записи.
///
/// Это факты «здесь запись включили / выключили», по которым единая лента
/// журнала рисует разделители (а не эвристика «пауза больше N секунд»).
/// `ended_at` и `stop_reason` пустые — сессия не закрыта штатно: процесс
/// убили, то есть «здесь приложение закрылось».
///
/// Без `from`/`to` отдаются последние `limit` сессий (новые сверху) — дешёвый
/// хвост истории. С границами — сессии, у которых в период попадает НАЧАЛО ИЛИ
/// КОНЕЦ, по возрастанию времени, не больше `limit`.
fn sessions(query: &[(String, String)], store: &Store) -> HttpReply {
    let (from, to) = match optional_range(query) {
        Ok(v) => v,
        Err(reply) => return reply,
    };
    let limit = match limit_param(query) {
        Ok(v) => v,
        Err(reply) => return reply,
    };
    let ranged = from.ms != i64::MIN || to.ms != i64::MAX;

    let items = if ranged {
        store.sessions_ms(from.ms, to.ms).map(|mut v| {
            v.truncate(limit as usize);
            v
        })
    } else {
        store.last_sessions(limit)
    };

    match items {
        Ok(items) => ok_reply(json!({
            "count": items.len(),
            "items": items,
        })),
        Err(e) => store_error(e),
    }
}

/// `GET /api/v1/export?from&to&format=json|md` — документ журнала, совместимый
/// с экспортом macOS-приложения.
fn export(query: &[(String, String)], store: &Store) -> HttpReply {
    let (from, to) = match required_range(query) {
        Ok(v) => v,
        Err(reply) => return reply,
    };
    let format = get_param(query, "format").unwrap_or_else(|| "json".into());

    let items = match collect_range(store, from.ms, to.ms, None) {
        Ok(v) => v,
        Err(e) => return store_error(e),
    };
    let exported_at = Local::now().to_rfc3339();

    match format.as_str() {
        "json" | "" => {
            let doc = journal_document(&items, &from.iso, &to.iso, &exported_at);
            // Сам документ, без конверта: файл сохраняется как есть.
            HttpReply::json(200, doc.to_string())
        }
        "md" | "markdown" => HttpReply::markdown(
            200,
            journal_markdown(&items, &from.iso, &to.iso, &exported_at),
        ),
        other => bad_request(&format!("неизвестный format {other:?}: ожидается json|md")),
    }
}

// ---------------------------------------------------------------------------
// Разбор параметров
// ---------------------------------------------------------------------------

/// Момент времени, разобранный из параметра запроса.
struct TimeArg {
    /// epoch-миллисекунды UTC — для диапазонных запросов.
    ms: i64,
    /// ISO-8601 представление (исходная строка либо локальное время) — для
    /// эндпоинтов, которым важна зона (бакеты активности, документ экспорта).
    iso: String,
}

impl TimeArg {
    fn from_ms(ms: i64) -> Self {
        Self {
            iso: local_iso(ms),
            ms,
        }
    }
}

/// ISO-8601 с таймзоной, `YYYY-MM-DD` (локальные сутки) или epoch-миллисекунды.
fn parse_time(raw: &str) -> Result<TimeArg, String> {
    let s = raw.trim();
    if s.is_empty() {
        return Err("пустое значение времени".into());
    }

    // epoch-миллисекунды
    let digits = s.strip_prefix('-').unwrap_or(s);
    if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
        let ms: i64 = s
            .parse()
            .map_err(|_| format!("невалидные epoch-миллисекунды {raw:?}"))?;
        if Utc.timestamp_millis_opt(ms).single().is_none() {
            return Err(format!("epoch-миллисекунды вне диапазона: {raw:?}"));
        }
        return Ok(TimeArg::from_ms(ms));
    }

    // ISO-8601 с таймзоной
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Ok(TimeArg {
            ms: dt.timestamp_millis(),
            iso: s.to_string(),
        });
    }

    // YYYY-MM-DD — начало локальных суток
    if let Ok(date) = NaiveDate::parse_from_str(s, "%Y-%m-%d") {
        let naive = date
            .and_hms_opt(0, 0, 0)
            .ok_or_else(|| format!("невалидная дата {raw:?}"))?;
        let local = Local
            .from_local_datetime(&naive)
            .earliest()
            .ok_or_else(|| format!("дата {raw:?} не существует в локальной зоне"))?;
        return Ok(TimeArg {
            ms: local.timestamp_millis(),
            iso: local.to_rfc3339(),
        });
    }

    Err(format!(
        "невалидное время {raw:?}: ожидается ISO-8601 с таймзоной, YYYY-MM-DD или epoch-мс"
    ))
}

fn local_iso(ms: i64) -> String {
    match Local.timestamp_millis_opt(ms).single() {
        Some(d) => d.to_rfc3339(),
        None => String::new(),
    }
}

/// `from`/`to` необязательны: без них берётся вся история.
fn optional_range(query: &[(String, String)]) -> Result<(TimeArg, TimeArg), HttpReply> {
    let from = match non_empty(get_param(query, "from")) {
        Some(s) => parse_time(&s).map_err(|e| bad_request(&e))?,
        None => TimeArg {
            ms: i64::MIN,
            iso: String::new(),
        },
    };
    let to = match non_empty(get_param(query, "to")) {
        Some(s) => parse_time(&s).map_err(|e| bad_request(&e))?,
        None => TimeArg {
            ms: i64::MAX,
            iso: String::new(),
        },
    };
    Ok((from, to))
}

/// `from`/`to` обязательны (эндпоинты, где период определяет форму ответа).
fn required_range(query: &[(String, String)]) -> Result<(TimeArg, TimeArg), HttpReply> {
    let (Some(f), Some(t)) = (
        non_empty(get_param(query, "from")),
        non_empty(get_param(query, "to")),
    ) else {
        return Err(bad_request("нужны параметры from и to"));
    };
    let from = parse_time(&f).map_err(|e| bad_request(&e))?;
    let to = parse_time(&t).map_err(|e| bad_request(&e))?;
    Ok((from, to))
}

fn limit_param(query: &[(String, String)]) -> Result<u32, HttpReply> {
    match non_empty(get_param(query, "limit")) {
        None => Ok(DEFAULT_LIMIT),
        Some(s) => match s.parse::<u32>() {
            Ok(v) if (1..=store::MAX_PAGE_LIMIT).contains(&v) => Ok(v),
            _ => Err(bad_request(&format!(
                "невалидный limit {s:?}: целое от 1 до {}",
                store::MAX_PAGE_LIMIT
            ))),
        },
    }
}

fn parse_offset_cursor(cursor: &str) -> Option<u32> {
    cursor.strip_prefix("off:")?.parse().ok()
}

fn non_empty(v: Option<String>) -> Option<String> {
    v.filter(|s| !s.trim().is_empty())
}

// ---------------------------------------------------------------------------
// Сборка данных и форматирование
// ---------------------------------------------------------------------------

/// Собирает интервалы за период постранично (не один гигантский SELECT) и
/// останавливается на [`RANGE_CAP`].
fn collect_range(
    store: &Store,
    from_ms: i64,
    to_ms: i64,
    channel: Option<&str>,
) -> Result<Vec<IntervalRecord>, CoreError> {
    let mut out: Vec<IntervalRecord> = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let page = store.query_intervals_page(
            from_ms,
            to_ms,
            channel,
            store::MAX_PAGE_LIMIT,
            cursor.as_deref(),
        )?;
        let empty = page.items.is_empty();
        out.extend(page.items);
        match page.next_cursor {
            Some(c) if !empty && out.len() < RANGE_CAP => cursor = Some(c),
            _ => break,
        }
    }
    out.truncate(RANGE_CAP);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::tests::{cfg, get, seeded_store};
    use crate::api::ApiServer;
    use std::sync::Arc;

    const FROM: &str = "2026-01-01T00:00:00%2B00:00";
    const TO: &str = "2026-01-02T00:00:00%2B00:00";

    struct Harness {
        base: String,
        server: Option<ApiServer>,
        _dir: tempfile::TempDir,
    }

    impl Harness {
        fn start(port: u16, token: &str) -> Self {
            let (store, dir) = seeded_store();
            let metrics = Arc::new(Metrics::new());
            let server = ApiServer::start(cfg(port, token), store, metrics).expect("start");
            Self {
                base: format!("http://127.0.0.1:{port}"),
                server: Some(server),
                _dir: dir,
            }
        }
        fn get(&self, path: &str) -> (u16, String) {
            get(&format!("{}{path}", self.base), None)
        }
        fn get_auth(&self, path: &str, token: &str) -> (u16, String) {
            get(&format!("{}{path}", self.base), Some(token))
        }
    }

    impl Drop for Harness {
        fn drop(&mut self) {
            if let Some(s) = self.server.take() {
                s.stop();
            }
        }
    }

    fn parse(body: &str) -> serde_json::Value {
        serde_json::from_str(body).unwrap_or_else(|e| panic!("не JSON ({e}): {body}"))
    }

    #[test]
    fn health_needs_no_token_and_hides_nothing_private() {
        let h = Harness::start(38801, "secret");
        let (status, body) = h.get("/api/v1/health");
        assert_eq!(status, 200, "{body}");
        let v = parse(&body);
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["db_ok"], true);
        assert!(v["data"]["version"].is_string());
        assert_eq!(v["data"]["schema_version"], crate::store::SCHEMA_VERSION);
        // Остальные v1-пути под токеном.
        let (status, _) = h.get("/api/v1/intervals");
        assert_eq!(status, 401);
    }

    #[test]
    fn envelope_and_pagination() {
        let h = Harness::start(38802, "");
        let (status, body) = h.get(&format!("/api/v1/intervals?from={FROM}&to={TO}&limit=1"));
        assert_eq!(status, 200, "{body}");
        let v = parse(&body);
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["count"], 1);
        let cursor = v["data"]["next_cursor"]
            .as_str()
            .expect("есть next_cursor")
            .to_string();

        let (status, body) = h.get(&format!(
            "/api/v1/intervals?from={FROM}&to={TO}&limit=1&cursor={cursor}"
        ));
        assert_eq!(status, 200, "{body}");
        let v2 = parse(&body);
        assert_eq!(v2["data"]["count"], 1);
        assert_ne!(v2["data"]["items"][0]["id"], v["data"]["items"][0]["id"]);

        // Третья страница пустая и без курсора.
        let cursor2 = v2["data"]["next_cursor"].as_str().unwrap().to_string();
        let (_, body) = h.get(&format!(
            "/api/v1/intervals?from={FROM}&to={TO}&limit=1&cursor={cursor2}"
        ));
        let v3 = parse(&body);
        assert_eq!(v3["data"]["count"], 0);
        assert!(v3["data"]["next_cursor"].is_null());
    }

    #[test]
    fn intervals_channel_filter_and_bad_params() {
        let h = Harness::start(38803, "");
        let (status, body) = h.get(&format!(
            "/api/v1/intervals?from={FROM}&to={TO}&channel=mic"
        ));
        assert_eq!(status, 200, "{body}");
        let v = parse(&body);
        assert_eq!(v["data"]["count"], 1);
        assert_eq!(v["data"]["items"][0]["channels"][0]["channel_id"], "mic");

        for bad in [
            "/api/v1/intervals?from=nonsense",
            "/api/v1/intervals?limit=0",
            "/api/v1/intervals?limit=99999",
            "/api/v1/intervals?cursor=garbage",
        ] {
            let (status, body) = h.get(bad);
            assert_eq!(status, 400, "{bad} -> {body}");
            let v = parse(&body);
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"]["code"], "bad_request");
        }
    }

    #[test]
    fn interval_by_id_and_404() {
        let h = Harness::start(38804, "");
        let (_, body) = h.get(&format!("/api/v1/intervals?from={FROM}&to={TO}"));
        let id = parse(&body)["data"]["items"][0]["id"].as_i64().unwrap();

        let (status, body) = h.get(&format!("/api/v1/intervals/{id}"));
        assert_eq!(status, 200, "{body}");
        assert_eq!(parse(&body)["data"]["id"], id);

        let (status, body) = h.get("/api/v1/intervals/999999");
        assert_eq!(status, 404, "{body}");
        assert_eq!(parse(&body)["error"]["code"], "not_found");

        let (status, _) = h.get("/api/v1/intervals/abc");
        assert_eq!(status, 400);
    }

    #[test]
    fn state_hides_last_text_unless_requested() {
        let h = Harness::start(38805, "");
        let (status, body) = h.get("/api/v1/state");
        assert_eq!(status, 200, "{body}");
        let v = parse(&body);
        assert_eq!(v["ok"], true);
        assert!(v["data"].is_object());
        assert!(v["data"]["sources"].is_array());

        let (status, body) = h.get("/api/v1/state?include=last_text");
        assert_eq!(status, 200, "{body}");
        assert!(parse(&body)["data"].is_object());
    }

    #[test]
    fn transcript_formats() {
        let h = Harness::start(38806, "");
        let (status, body) = h.get(&format!("/api/v1/transcript?from={FROM}&to={TO}"));
        assert_eq!(status, 200, "{body}");
        assert!(body.contains("hello world"), "{body}");

        let (status, body) = h.get(&format!("/api/v1/transcript?from={FROM}&to={TO}&format=md"));
        assert_eq!(status, 200);
        assert!(body.starts_with("# Транскрипция"), "{body}");

        let (status, body) = h.get(&format!(
            "/api/v1/transcript?from={FROM}&to={TO}&format=json"
        ));
        assert_eq!(status, 200);
        let v = parse(&body);
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["count"], 2);
        assert!(v["data"]["text"].as_str().unwrap().contains("hello world"));

        let (status, body) = h.get("/api/v1/transcript?format=csv");
        assert_eq!(status, 400, "{body}");
    }

    #[test]
    fn search_endpoint() {
        let h = Harness::start(38807, "");
        let (status, body) = h.get("/api/v1/search?q=hello");
        assert_eq!(status, 200, "{body}");
        let v = parse(&body);
        assert_eq!(v["data"]["count"], 1);
        assert!(v["data"]["engine"].is_string());
        // Старые поля интервала на месте.
        let item = &v["data"]["items"][0];
        assert!(item["id"].is_i64(), "{body}");
        assert!(item["start_at"].is_string(), "{body}");
        assert!(item["channels"].is_array(), "{body}");
        // Аддитивные поля: канал совпадения и фрагмент с выделением.
        assert_eq!(item["channel_id"], "mic");
        let snippet = item["snippet"].as_str().unwrap();
        assert!(snippet.contains("«hello»"), "{snippet}");

        // q обязателен.
        let (status, body) = h.get("/api/v1/search");
        assert_eq!(status, 400, "{body}");
        assert_eq!(parse(&body)["error"]["code"], "bad_request");

        // Ничего не найдено — 200 и пустой список.
        let (status, body) = h.get("/api/v1/search?q=zzzzz");
        assert_eq!(status, 200);
        assert_eq!(parse(&body)["data"]["count"], 0);
    }

    #[test]
    fn activity_buckets_and_bad_bucket_is_400() {
        let h = Harness::start(38808, "");
        let (status, body) = h.get(&format!("/api/v1/activity?bucket=hour&from={FROM}&to={TO}"));
        assert_eq!(status, 200, "{body}");
        let v = parse(&body);
        assert_eq!(v["data"]["bucket"], "hour");
        assert_eq!(v["data"]["buckets"].as_array().unwrap().len(), 24);

        let (status, body) = h.get(&format!("/api/v1/activity?bucket=day&from={FROM}&to={TO}"));
        assert_eq!(status, 200, "{body}");
        assert_eq!(parse(&body)["data"]["bucket"], "day");

        let (status, body) = h.get(&format!("/api/v1/activity?bucket=week&from={FROM}&to={TO}"));
        assert_eq!(status, 400, "{body}");
        assert_eq!(parse(&body)["error"]["code"], "bad_request");

        // from/to обязательны.
        let (status, _) = h.get("/api/v1/activity?bucket=hour");
        assert_eq!(status, 400);
    }

    /// Сессии: конверт, поля элемента, «незакрытая = пустой ended_at»,
    /// фильтр по периоду, хвост без границ и 400 на мусор.
    #[test]
    fn sessions_endpoint_reports_starts_stops_and_crashes() {
        let h = Harness::start(38814, "");

        let (status, body) = h.get(&format!("/api/v1/sessions?from={FROM}&to={TO}"));
        assert_eq!(status, 200, "{body}");
        let v = parse(&body);
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["count"], 2);
        let items = v["data"]["items"].as_array().unwrap();
        // По возрастанию времени: сперва закрытая, потом незакрытая.
        assert!(items[0]["id"].is_i64());
        assert_eq!(items[0]["started_at"], "2026-01-01T09:59:00+00:00");
        assert_eq!(items[0]["ended_at"], "2026-01-01T10:05:00+00:00");
        assert_eq!(items[0]["stop_reason"], "user");
        // Незакрытая сессия — «здесь приложение закрылось».
        assert_eq!(items[1]["ended_at"], "");
        assert_eq!(items[1]["stop_reason"], "");

        // Без границ — хвост истории, новые сверху.
        let (status, body) = h.get("/api/v1/sessions");
        assert_eq!(status, 200, "{body}");
        let v = parse(&body);
        assert_eq!(v["data"]["count"], 2);
        assert_eq!(
            v["data"]["items"][0]["started_at"],
            "2026-01-01T11:00:00+00:00"
        );

        // limit режет выдачу и в периоде, и без него.
        let (_, body) = h.get(&format!("/api/v1/sessions?from={FROM}&to={TO}&limit=1"));
        assert_eq!(parse(&body)["data"]["count"], 1);
        let (_, body) = h.get("/api/v1/sessions?limit=1");
        assert_eq!(parse(&body)["data"]["count"], 1);

        // Период без сессий — пустой список, не ошибка.
        let (status, body) = h.get("/api/v1/sessions?from=2020-01-01&to=2020-01-02");
        assert_eq!(status, 200, "{body}");
        assert_eq!(parse(&body)["data"]["count"], 0);

        // Мусор во времени и лимите — 400 в конверте.
        for path in [
            "/api/v1/sessions?from=вчера",
            "/api/v1/sessions?limit=0",
            "/api/v1/sessions?limit=99999",
        ] {
            let (status, body) = h.get(path);
            assert_eq!(status, 400, "{path}: {body}");
            assert_eq!(parse(&body)["error"]["code"], "bad_request");
        }
    }

    #[test]
    fn export_matches_app_document_shape() {
        let h = Harness::start(38809, "");
        let (status, body) = h.get(&format!("/api/v1/export?from={FROM}&to={TO}"));
        assert_eq!(status, 200, "{body}");
        let v = parse(&body);
        // Форма документа приложения: без конверта, camelCase-ключи.
        assert_eq!(v["product"], "Chronica");
        assert!(v["exportedAt"].is_string());
        assert!(v["activities"].is_array());
        assert_eq!(v["transcription"]["count"], 2);
        let iv = &v["transcription"]["intervals"][0];
        assert!(iv["startAt"].is_string());
        assert!(iv["endAt"].is_string());
        assert!(iv["durationS"].is_number());
        assert_eq!(iv["channels"][0]["channelId"], "mic");
        assert!(iv["channels"][0]["words"].is_number());

        let (status, body) = h.get(&format!("/api/v1/export?from={FROM}&to={TO}&format=md"));
        assert_eq!(status, 200);
        assert!(body.starts_with("# Журнал Chronica"), "{body}");

        let (status, _) = h.get(&format!("/api/v1/export?from={FROM}&to={TO}&format=pdf"));
        assert_eq!(status, 400);
    }

    #[test]
    fn openapi_is_served_and_valid_json() {
        let h = Harness::start(38810, "");
        let (status, body) = h.get("/api/v1/openapi.json");
        assert_eq!(status, 200);
        let v = parse(&body);
        assert!(v["openapi"].as_str().unwrap().starts_with("3."));
        assert!(v["paths"]["/api/v1/intervals"].is_object());
    }

    #[test]
    fn unknown_v1_path_is_404_in_envelope() {
        let h = Harness::start(38811, "");
        let (status, body) = h.get("/api/v1/nope");
        assert_eq!(status, 404);
        assert_eq!(parse(&body)["error"]["code"], "not_found");
    }

    #[test]
    fn token_is_required_on_v1_and_accepts_correct_one() {
        let h = Harness::start(38812, "s3cret");
        let (status, body) = h.get("/api/v1/state");
        assert_eq!(status, 401, "{body}");
        assert_eq!(parse(&body)["error"]["code"], "unauthorized");

        let (status, _) = h.get_auth("/api/v1/state", "s3cret");
        assert_eq!(status, 200);
        let (status, _) = h.get_auth("/api/v1/state", "wrong");
        assert_eq!(status, 401);
    }

    #[test]
    fn epoch_ms_and_date_only_are_accepted() {
        let h = Harness::start(38813, "");
        // 2026-01-01T00:00:00Z .. 2026-01-02T00:00:00Z в epoch-мс.
        let from = 1_767_225_600_000i64;
        let to = 1_767_312_000_000i64;
        let (status, body) = h.get(&format!("/api/v1/intervals?from={from}&to={to}"));
        assert_eq!(status, 200, "{body}");
        assert_eq!(parse(&body)["data"]["count"], 2);

        let (status, body) = h.get("/api/v1/intervals?from=2026-01-01&to=2026-01-03");
        assert_eq!(status, 200, "{body}");
        assert!(parse(&body)["data"]["count"].as_u64().unwrap() >= 1);
    }

    // --- Чистые функции -----------------------------------------------------

    #[test]
    fn parse_time_accepts_three_forms_and_rejects_junk() {
        assert_eq!(parse_time("0").unwrap().ms, 0);
        assert_eq!(parse_time("1767225600000").unwrap().ms, 1_767_225_600_000);
        assert_eq!(
            parse_time("2026-01-01T00:00:00+00:00").unwrap().ms,
            1_767_225_600_000
        );
        // Дата без времени — начало локальных суток, зона отражена в iso.
        let d = parse_time("2026-01-01").unwrap();
        assert!(d.iso.starts_with("2026-01-01T00:00:00"));
        assert!(parse_time("вчера").is_err());
        assert!(parse_time("2026-13-45").is_err());
        assert!(parse_time("").is_err());
    }

    #[test]
    fn offset_cursor_roundtrip() {
        assert_eq!(parse_offset_cursor("off:40"), Some(40));
        assert_eq!(parse_offset_cursor("off:0"), Some(0));
        assert_eq!(parse_offset_cursor("40"), None);
        assert_eq!(parse_offset_cursor("off:x"), None);
    }
}
