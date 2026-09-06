//! Optional local HTTP API for retrieving records by time. OWNER: module agent.
//! Off unless the user enables it. Uses `tiny_http` on background threads
//! (no async runtime — low overhead). `api` implies `store`.
//!
//! Две поверхности:
//!
//! 1. **Исторические пути** (вечные алиасы, форма ответа не меняется):
//!    ```text
//!    GET /api/intervals?from=ISO&to=ISO        -> { ok, count, intervals: [IntervalRecord] }
//!    GET /api/transcriptions?from=ISO&to=ISO   -> алиас /api/intervals
//!    GET /api/voice-activity?type=hourly|daily&from=&to= -> { ok, buckets: [ActivityBucket] }
//!    GET /api/state                            -> { ok, state: MetricsSnapshot }
//!    ```
//! 2. **`/api/v1/*`** — стабильный конверт `{ok:true,data}` / `{ok:false,error:{code,message}}`
//!    (см. [`v1`] и `docs/API.md`, машинное описание — `docs/openapi.json`).
//!
//! Безопасность: bind по умолчанию только на loopback; попытка слушать внешний
//! адрес без токена — отказ запуска. Токен сверяется за постоянное время;
//! `Authorization: Bearer` требуется на всех путях, кроме `/api/v1/health` и
//! `/api/v1/openapi.json`.
//! CORS разрешён только для Origin вида `http://localhost:*` / `http://127.0.0.1:*`.

use crate::errors::CoreError;
use crate::metrics::Metrics;
use crate::store::Store;
use crate::types::{ActivityKind, ApiConfig};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use tiny_http::{Header, Method, Request, Response, Server};

#[path = "api_v1.rs"]
mod v1;

/// Значение заголовка `X-Chronica-Api-Version` на каждом ответе.
pub const API_VERSION: &str = "1";

/// Небольшой пул обработчиков: параллельные запросы UI/скриптов не выстраиваются
/// в очередь за одним медленным. Потоки простаивают в `recv_timeout`.
const API_THREADS: usize = 3;

/// Готовый ответ (тело + Content-Type). Общий для v1 и исторических путей.
pub(crate) struct HttpReply {
    pub status: u16,
    pub content_type: &'static str,
    pub body: String,
}

impl HttpReply {
    pub(crate) fn json(status: u16, body: String) -> Self {
        Self {
            status,
            content_type: "application/json; charset=utf-8",
            body,
        }
    }
    pub(crate) fn text(status: u16, body: String) -> Self {
        Self {
            status,
            content_type: "text/plain; charset=utf-8",
            body,
        }
    }
    pub(crate) fn markdown(status: u16, body: String) -> Self {
        Self {
            status,
            content_type: "text/markdown; charset=utf-8",
            body,
        }
    }
}

pub struct ApiServer {
    stop_flag: Arc<AtomicBool>,
    server: Arc<Server>,
    handles: Vec<JoinHandle<()>>,
}

impl ApiServer {
    /// Start the server threads. Returns immediately; keep the handle to stop.
    ///
    /// Отказывает в запуске, если сервер слушает НЕ петлевой адрес и токен пуст:
    /// иначе вся история разговоров была бы доступна любому в сети.
    pub fn start(
        cfg: ApiConfig,
        store: Arc<Store>,
        metrics: Arc<Metrics>,
    ) -> Result<ApiServer, CoreError> {
        if !is_loopback_host(&cfg.host) && cfg.token.trim().is_empty() {
            return Err(CoreError::Api(format!(
                "отказ запуска API: host {:?} не петлевой, а токен пуст — \
                 задайте токен или слушайте 127.0.0.1",
                cfg.host
            )));
        }

        let addr = format!("{}:{}", cfg.host, cfg.port);
        let server =
            Server::http(addr.as_str()).map_err(|e| CoreError::Api(format!("bind {addr}: {e}")))?;
        let server = Arc::new(server);

        let stop_flag = Arc::new(AtomicBool::new(false));
        let token = cfg.token.clone();

        let mut handles = Vec::with_capacity(API_THREADS);
        for i in 0..API_THREADS {
            let thread_server = Arc::clone(&server);
            let thread_stop = Arc::clone(&stop_flag);
            let thread_token = token.clone();
            let thread_store = Arc::clone(&store);
            let thread_metrics = Arc::clone(&metrics);
            let handle = std::thread::Builder::new()
                .name(format!("transcriber-api-{i}"))
                .spawn(move || {
                    serve_loop(
                        thread_server,
                        thread_stop,
                        thread_token,
                        thread_store,
                        thread_metrics,
                    );
                })
                .map_err(|e| CoreError::Api(format!("spawn api thread: {e}")))?;
            handles.push(handle);
        }

        Ok(ApiServer {
            stop_flag,
            server,
            handles,
        })
    }

    /// Signal the server threads to shut down and join them.
    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        self.stop_flag.store(true, Ordering::SeqCst);
        // Unblock any in-flight `recv_timeout` so the loops notice the flag.
        self.server.unblock();
        for handle in self.handles.drain(..) {
            let _ = handle.join();
        }
    }
}

impl Drop for ApiServer {
    fn drop(&mut self) {
        // If `stop` was not called explicitly, still shut down cleanly.
        self.shutdown();
    }
}

fn serve_loop(
    server: Arc<Server>,
    stop_flag: Arc<AtomicBool>,
    token: String,
    store: Arc<Store>,
    metrics: Arc<Metrics>,
) {
    while !stop_flag.load(Ordering::SeqCst) {
        match server.recv_timeout(Duration::from_millis(200)) {
            Ok(Some(request)) => {
                if stop_flag.load(Ordering::SeqCst) {
                    break;
                }
                handle_request(request, &token, &store, &metrics);
            }
            Ok(None) => {
                // Timed out with no request — loop and re-check the stop flag.
            }
            Err(_) => break,
        }
    }
}

fn handle_request(request: Request, token: &str, store: &Store, metrics: &Metrics) {
    let cors = request
        .headers()
        .iter()
        .find(|h| h.field.equiv("Origin"))
        .map(|h| h.value.as_str().to_string())
        .filter(|o| cors_origin_allowed(o));

    let url = request.url().to_string();
    let (path, query) = split_path_query(&url);
    let is_v1 = path == "/api/v1" || path.starts_with("/api/v1/");

    // Браузерный preflight: отвечаем до авторизации (заголовок Authorization в
    // OPTIONS не отправляется по спецификации CORS).
    if *request.method() == Method::Options {
        respond_preflight(request, cors.as_deref());
        return;
    }
    if *request.method() != Method::Get {
        let reply = if is_v1 {
            v1::error_reply(405, "bad_request", "поддерживается только GET")
        } else {
            HttpReply::json(404, error_body("not found"))
        };
        respond(request, reply, cors.as_deref());
        return;
    }

    // Authorization (only enforced when a token is configured). `/api/v1/health`
    // и `/api/v1/openapi.json` намеренно открыты: первый нужен, чтобы понять,
    // жив ли сервер, второй — статичная спецификация; приватного не отдают.
    let public = is_v1 && matches!(path, "/api/v1/health" | "/api/v1/openapi.json");
    if !token.is_empty() && !public && !is_authorized(&request, token) {
        let reply = if is_v1 {
            v1::error_reply(401, "unauthorized", "нужен заголовок Authorization: Bearer")
        } else {
            HttpReply::json(401, error_body("unauthorized"))
        };
        respond(request, reply, cors.as_deref());
        return;
    }

    let reply = if is_v1 {
        v1::route(path, &query, store, metrics)
    } else {
        let (status, body) = match path {
            "/api/intervals" | "/api/transcriptions" => handle_intervals(&query, store),
            "/api/voice-activity" => handle_voice_activity(&query, store),
            "/api/state" => handle_state(metrics),
            _ => (404, error_body("not found")),
        };
        HttpReply::json(status, body)
    };

    respond(request, reply, cors.as_deref());
}

fn handle_intervals(query: &[(String, String)], store: &Store) -> (u16, String) {
    let from = get_param(query, "from");
    let to = get_param(query, "to");
    let (from, to) = match require_from_to(from, to) {
        Ok(v) => v,
        Err(body) => return (400, body),
    };

    match store.query_intervals(&from, &to) {
        Ok(intervals) => {
            let body = serde_json::json!({
                "ok": true,
                "count": intervals.len(),
                "intervals": intervals,
            });
            (200, body.to_string())
        }
        // Плохой ISO — ошибка ввода, а не сервера.
        Err(CoreError::Config(e)) => (400, error_body(&e)),
        Err(e) => (500, error_body(&format!("store: {e}"))),
    }
}

fn handle_voice_activity(query: &[(String, String)], store: &Store) -> (u16, String) {
    let from = get_param(query, "from");
    let to = get_param(query, "to");
    let (from, to) = match require_from_to(from, to) {
        Ok(v) => v,
        Err(body) => return (400, body),
    };

    let kind = match get_param(query, "type").as_deref() {
        Some("daily") => ActivityKind::Daily,
        // Default to hourly when `type` is absent or "hourly".
        _ => ActivityKind::Hourly,
    };

    match store.voice_activity(kind, &from, &to) {
        Ok(buckets) => {
            let body = serde_json::json!({
                "ok": true,
                "buckets": buckets,
            });
            (200, body.to_string())
        }
        Err(CoreError::Config(e)) => (400, error_body(&e)),
        Err(e) => (500, error_body(&format!("store: {e}"))),
    }
}

fn handle_state(metrics: &Metrics) -> (u16, String) {
    let snapshot = metrics.snapshot();
    let body = serde_json::json!({
        "ok": true,
        "state": snapshot,
    });
    (200, body.to_string())
}

/// Both `from` and `to` must be present and non-empty.
fn require_from_to(from: Option<String>, to: Option<String>) -> Result<(String, String), String> {
    match (from, to) {
        (Some(f), Some(t)) if !f.is_empty() && !t.is_empty() => Ok((f, t)),
        _ => Err(error_body("from and to required")),
    }
}

fn is_authorized(request: &Request, token: &str) -> bool {
    let expected = format!("Bearer {token}");
    request
        .headers()
        .iter()
        .any(|h| h.field.equiv("Authorization") && constant_time_eq(h.value.as_str(), &expected))
}

/// Сравнение за постоянное время: длина не секрет, а вот посимвольный
/// ранний выход по содержимому давал бы таймингову утечку токена.
fn constant_time_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Петлевой ли адрес прослушивания.
fn is_loopback_host(host: &str) -> bool {
    matches!(
        host.trim(),
        "127.0.0.1" | "localhost" | "::1" | "[::1]" | "0:0:0:0:0:0:0:1"
    ) || host.trim().starts_with("127.")
}

/// Разрешённый Origin: только локальная страница (`http://localhost[:порт]`
/// или `http://127.0.0.1[:порт]`). Всё остальное — без CORS-заголовков.
fn cors_origin_allowed(origin: &str) -> bool {
    let Some(rest) = origin.strip_prefix("http://") else {
        return false;
    };
    let (host, port) = match rest.split_once(':') {
        Some((h, p)) => (h, Some(p)),
        None => (rest, None),
    };
    if !matches!(host, "localhost" | "127.0.0.1") {
        return false;
    }
    match port {
        None => true,
        Some(p) => !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()),
    }
}

fn error_body(msg: &str) -> String {
    serde_json::json!({ "ok": false, "error": msg }).to_string()
}

fn header(name: &str, value: &str) -> Option<Header> {
    Header::from_bytes(name.as_bytes(), value.as_bytes()).ok()
}

/// Заголовки, общие для всех ответов (версия API + CORS, если Origin разрешён).
fn common_headers(cors: Option<&str>) -> Vec<Header> {
    let mut out = Vec::new();
    if let Some(h) = header("X-Chronica-Api-Version", API_VERSION) {
        out.push(h);
    }
    // Ответ зависит от Origin — кеши не должны его смешивать.
    if let Some(h) = header("Vary", "Origin") {
        out.push(h);
    }
    if let Some(origin) = cors {
        if let Some(h) = header("Access-Control-Allow-Origin", origin) {
            out.push(h);
        }
        if let Some(h) = header(
            "Access-Control-Allow-Headers",
            "Authorization, Content-Type",
        ) {
            out.push(h);
        }
        if let Some(h) = header("Access-Control-Allow-Methods", "GET, OPTIONS") {
            out.push(h);
        }
        if let Some(h) = header("Access-Control-Max-Age", "600") {
            out.push(h);
        }
    }
    out
}

fn respond(request: Request, reply: HttpReply, cors: Option<&str>) {
    let mut response = Response::from_string(reply.body).with_status_code(reply.status);
    if let Some(h) = header("Content-Type", reply.content_type) {
        response = response.with_header(h);
    }
    for h in common_headers(cors) {
        response = response.with_header(h);
    }
    let _ = request.respond(response);
}

fn respond_preflight(request: Request, cors: Option<&str>) {
    let mut response = Response::empty(204);
    for h in common_headers(cors) {
        response = response.with_header(h);
    }
    let _ = request.respond(response);
}

/// Split a request URL into its path and decoded query pairs.
fn split_path_query(url: &str) -> (&str, Vec<(String, String)>) {
    match url.split_once('?') {
        Some((path, qs)) => (path, parse_query(qs)),
        None => (url, Vec::new()),
    }
}

fn parse_query(qs: &str) -> Vec<(String, String)> {
    qs.split('&')
        .filter(|p| !p.is_empty())
        .map(|pair| match pair.split_once('=') {
            Some((k, v)) => (url_decode(k), url_decode(v)),
            None => (url_decode(pair), String::new()),
        })
        .collect()
}

fn get_param(query: &[(String, String)], key: &str) -> Option<String> {
    query.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
}

/// Minimal application/x-www-form-urlencoded decoder (`+` -> space, `%XX`).
fn url_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hi = hex_val(bytes[i + 1]);
                let lo = hex_val(bytes[i + 2]);
                match (hi, lo) {
                    (Some(h), Some(l)) => {
                        out.push((h << 4) | l);
                        i += 3;
                    }
                    _ => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A fixed high port for integration tests. tiny_http needs a concrete
    // port; pick distinct ones per test to avoid collisions when run in
    // parallel.
    pub(super) fn cfg(port: u16, token: &str) -> ApiConfig {
        ApiConfig {
            enabled: true,
            host: "127.0.0.1".into(),
            port,
            token: token.into(),
        }
    }

    /// Build a Store backed by a temp SQLite file, seeded with intervals and
    /// voice events.
    pub(super) fn seeded_store() -> (Arc<Store>, tempfile::TempDir) {
        use crate::types::ChannelText;
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("test.db");
        let store = Store::open(db.to_str().unwrap()).expect("open store");

        store
            .write_interval(
                "2026-01-01T10:00:00+00:00",
                "2026-01-01T10:00:30+00:00",
                30.0,
                &[ChannelText {
                    channel_id: "mic".into(),
                    text: "hello world".into(),
                    words: 2,
                    language: "en".into(),
                }],
            )
            .expect("write interval 1");
        store
            .write_interval(
                "2026-01-01T11:00:00+00:00",
                "2026-01-01T11:01:00+00:00",
                60.0,
                &[ChannelText {
                    channel_id: "remote".into(),
                    text: "second interval".into(),
                    words: 2,
                    language: "en".into(),
                }],
            )
            .expect("write interval 2");

        store
            .log_voice_event("mic", "2026-01-01T10:00:05+00:00")
            .expect("voice event 1");
        store
            .log_voice_event("remote", "2026-01-01T11:00:10+00:00")
            .expect("voice event 2");

        // Две сессии записи: закрытая пользователем и незакрытая (процесс
        // убили) — по ним лента журнала рисует разделители.
        let closed = store
            .open_session("2026-01-01T09:59:00+00:00")
            .expect("session 1");
        store
            .close_session(
                closed,
                "2026-01-01T10:05:00+00:00",
                crate::store::SESSION_STOP_USER,
            )
            .expect("close session 1");
        store
            .open_session("2026-01-01T11:00:00+00:00")
            .expect("session 2");

        (Arc::new(store), dir)
    }

    pub(super) fn get(url: &str, token: Option<&str>) -> (u16, String) {
        let req = ureq::get(url);
        let req = match token {
            Some(t) => req.set("Authorization", &format!("Bearer {t}")),
            None => req,
        };
        match req.call() {
            Ok(resp) => {
                let status = resp.status();
                let body = resp.into_string().unwrap_or_default();
                (status, body)
            }
            // ureq surfaces non-2xx as Err(Status).
            Err(ureq::Error::Status(code, resp)) => {
                let body = resp.into_string().unwrap_or_default();
                (code, body)
            }
            Err(e) => panic!("request failed: {e}"),
        }
    }

    // --- Исторические пути: форма ответа зафиксирована навсегда -------------

    #[test]
    fn intervals_state_and_voice_activity_ok() {
        let (store, _dir) = seeded_store();
        let metrics = Arc::new(Metrics::new());
        let port = 38731;
        let server = ApiServer::start(cfg(port, ""), store, metrics).expect("start");

        let base = format!("http://127.0.0.1:{port}");
        // NB: `+` is a reserved form-encoding char (decodes to space), so the
        // tz offset must be percent-encoded as %2B by a correct client.
        let from = "2026-01-01T00:00:00%2B00:00";
        let to = "2026-01-02T00:00:00%2B00:00";

        let (status, body) = get(&format!("{base}/api/intervals?from={from}&to={to}"), None);
        assert_eq!(status, 200, "intervals body: {body}");
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["count"], 2);
        assert!(v["intervals"].is_array());

        // Alias route.
        let (status, _) = get(
            &format!("{base}/api/transcriptions?from={from}&to={to}"),
            None,
        );
        assert_eq!(status, 200);

        let (status, body) = get(
            &format!("{base}/api/voice-activity?type=hourly&from={from}&to={to}"),
            None,
        );
        assert_eq!(status, 200, "voice body: {body}");
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["buckets"].is_array());

        let (status, body) = get(&format!("{base}/api/state"), None);
        assert_eq!(status, 200, "state body: {body}");
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["state"].is_object());

        server.stop();
    }

    #[test]
    fn missing_from_to_is_400() {
        let (store, _dir) = seeded_store();
        let metrics = Arc::new(Metrics::new());
        let port = 38732;
        let server = ApiServer::start(cfg(port, ""), store, metrics).expect("start");

        let (status, body) = get(&format!("http://127.0.0.1:{port}/api/intervals"), None);
        assert_eq!(status, 400, "body: {body}");
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "from and to required");

        server.stop();
    }

    /// Мусор во времени — 400, а не 500.
    #[test]
    fn malformed_time_is_400_on_legacy_route() {
        let (store, _dir) = seeded_store();
        let metrics = Arc::new(Metrics::new());
        let port = 38739;
        let server = ApiServer::start(cfg(port, ""), store, metrics).expect("start");

        let (status, body) = get(
            &format!("http://127.0.0.1:{port}/api/intervals?from=nope&to=nope"),
            None,
        );
        assert_eq!(status, 400, "body: {body}");

        server.stop();
    }

    #[test]
    fn bad_token_is_401() {
        let (store, _dir) = seeded_store();
        let metrics = Arc::new(Metrics::new());
        let port = 38733;
        let server = ApiServer::start(cfg(port, "secret"), store, metrics).expect("start");

        // Wrong token.
        let (status, body) = get(&format!("http://127.0.0.1:{port}/api/state"), Some("wrong"));
        assert_eq!(status, 401, "body: {body}");
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "unauthorized");

        // No token at all.
        let (status, _) = get(&format!("http://127.0.0.1:{port}/api/state"), None);
        assert_eq!(status, 401);

        // Correct token works.
        let (status, _) = get(
            &format!("http://127.0.0.1:{port}/api/state"),
            Some("secret"),
        );
        assert_eq!(status, 200);

        server.stop();
    }

    /// Публичные пути при заданном токене: `/api/v1/health` и
    /// `/api/v1/openapi.json` отвечают 200 без заголовка `Authorization`.
    #[test]
    fn public_paths_need_no_token() {
        let (store, _dir) = seeded_store();
        let metrics = Arc::new(Metrics::new());
        let port = 38743;
        let server = ApiServer::start(cfg(port, "secret"), store, metrics).expect("start");
        let base = format!("http://127.0.0.1:{port}");

        let (status, body) = get(&format!("{base}/api/v1/health"), None);
        assert_eq!(status, 200, "health body: {body}");

        let (status, body) = get(&format!("{base}/api/v1/openapi.json"), None);
        assert_eq!(status, 200, "openapi body: {body}");
        let v: serde_json::Value = serde_json::from_str(&body).expect("openapi json");
        assert!(v["openapi"].as_str().unwrap_or_default().starts_with("3."));

        // Остальные пути v1 при заданном токене по-прежнему закрыты.
        let (status, _) = get(&format!("{base}/api/v1/state"), None);
        assert_eq!(status, 401);

        server.stop();
    }

    /// Внешний адрес без токена — отказ ещё до открытия сокета.
    #[test]
    fn non_loopback_without_token_refuses_to_start() {
        let (store, _dir) = seeded_store();
        let metrics = Arc::new(Metrics::new());
        let mut c = cfg(38740, "");
        c.host = "0.0.0.0".into();
        match ApiServer::start(c, store, metrics) {
            Err(CoreError::Api(msg)) => assert!(msg.contains("токен"), "{msg}"),
            Err(other) => panic!("ожидали CoreError::Api, получили {other:?}"),
            Ok(_) => panic!("сервер не должен был подняться"),
        }
    }

    /// CORS: Origin эхом только для локальных страниц; OPTIONS отвечает 204.
    #[test]
    fn cors_echoes_local_origin_and_answers_preflight() {
        let (store, _dir) = seeded_store();
        let metrics = Arc::new(Metrics::new());
        let port = 38741;
        let server = ApiServer::start(cfg(port, ""), store, metrics).expect("start");
        let url = format!("http://127.0.0.1:{port}/api/v1/health");

        let resp = ureq::get(&url)
            .set("Origin", "http://localhost:5173")
            .call()
            .expect("health");
        assert_eq!(
            resp.header("Access-Control-Allow-Origin"),
            Some("http://localhost:5173")
        );
        assert_eq!(resp.header("X-Chronica-Api-Version"), Some("1"));

        let resp = ureq::get(&url)
            .set("Origin", "http://evil.example.com")
            .call()
            .expect("health");
        assert!(resp.header("Access-Control-Allow-Origin").is_none());

        let resp = ureq::request("OPTIONS", &url)
            .set("Origin", "http://127.0.0.1:3000")
            .call()
            .expect("preflight");
        assert_eq!(resp.status(), 204);
        assert_eq!(
            resp.header("Access-Control-Allow-Origin"),
            Some("http://127.0.0.1:3000")
        );
        assert!(resp.header("Access-Control-Allow-Methods").is_some());

        server.stop();
    }

    /// Пул обработчиков: параллельные запросы обслуживаются все.
    #[test]
    fn concurrent_requests_all_succeed() {
        let (store, _dir) = seeded_store();
        let metrics = Arc::new(Metrics::new());
        let port = 38742;
        let server = ApiServer::start(cfg(port, ""), store, metrics).expect("start");
        let base = format!("http://127.0.0.1:{port}");

        let handles: Vec<_> = (0..8)
            .map(|_| {
                let url = format!("{base}/api/v1/health");
                std::thread::spawn(move || get(&url, None).0)
            })
            .collect();
        for h in handles {
            assert_eq!(h.join().expect("thread"), 200);
        }

        server.stop();
    }

    // --- Unit tests that do NOT require a working Store/Metrics -------------

    #[test]
    fn query_parsing_decodes_pairs() {
        let (path, q) =
            split_path_query("/api/intervals?from=2026-01-01T00%3A00%3A00%2B00%3A00&to=x");
        assert_eq!(path, "/api/intervals");
        assert_eq!(
            get_param(&q, "from").as_deref(),
            Some("2026-01-01T00:00:00+00:00")
        );
        assert_eq!(get_param(&q, "to").as_deref(), Some("x"));
        assert!(get_param(&q, "missing").is_none());
    }

    #[test]
    fn require_from_to_validation() {
        assert!(require_from_to(Some("a".into()), Some("b".into())).is_ok());
        assert!(require_from_to(Some("".into()), Some("b".into())).is_err());
        assert!(require_from_to(None, Some("b".into())).is_err());
        assert!(require_from_to(Some("a".into()), None).is_err());
    }

    #[test]
    fn error_body_shape() {
        let body = error_body("not found");
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "not found");
    }

    #[test]
    fn url_decode_basic() {
        assert_eq!(url_decode("a+b"), "a b");
        assert_eq!(url_decode("%2B"), "+");
        assert_eq!(url_decode("plain"), "plain");
        // Malformed escape is left as-is.
        assert_eq!(url_decode("%zz"), "%zz");
    }

    #[test]
    fn constant_time_eq_matches_semantics() {
        assert!(constant_time_eq("abc", "abc"));
        assert!(!constant_time_eq("abc", "abd"));
        assert!(!constant_time_eq("abc", "ab"));
        assert!(constant_time_eq("", ""));
    }

    #[test]
    fn loopback_detection() {
        assert!(is_loopback_host("127.0.0.1"));
        assert!(is_loopback_host("localhost"));
        assert!(is_loopback_host("::1"));
        assert!(is_loopback_host("127.0.0.53"));
        assert!(!is_loopback_host("0.0.0.0"));
        assert!(!is_loopback_host("192.168.1.10"));
    }

    #[test]
    fn cors_origin_allowlist() {
        assert!(cors_origin_allowed("http://localhost"));
        assert!(cors_origin_allowed("http://localhost:5173"));
        assert!(cors_origin_allowed("http://127.0.0.1:3000"));
        assert!(!cors_origin_allowed("https://localhost:5173"));
        assert!(!cors_origin_allowed("http://evil.example.com"));
        assert!(!cors_origin_allowed("http://localhost.evil.com"));
        assert!(!cors_origin_allowed("http://localhost:abc"));
    }
}
