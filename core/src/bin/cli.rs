//! Бинарь `chronica` — консольный доступ к локальным данным Chronica
//! («быстро получить что надо» без запущенного приложения), плюс старый
//! харнесс для проверки ASR.
//!
//! Команды работы с базой (`today`, `transcript`, `search`, `stats`, `export`,
//! `db`) читают тот же SQLite-файл, что и приложение; путь по умолчанию —
//! `~/Library/Application Support/Chronica/store/transcriber.sqlite`. Если по
//! новому пути базы нет, а по унаследованному
//! (`~/Library/Application Support/Transcriber/...`) есть — берётся старая
//! база с предупреждением в stderr. Переопределяется `--store PATH`.
//! У каждой команды есть `--json` для скриптования. Ошибки печатаются в
//! stderr, код возврата ≠ 0.
//!
//! Вывод рассчитан на конвейеры: если читатель закрывает stdout
//! (`chronica today | head -3`), CLI молча завершается с кодом 0, как `cat`,
//! `grep` или `git log`. Поэтому весь вывод идёт не через `println!`
//! (он паникует на EPIPE, потому что Rust глушит SIGPIPE), а через обёртку
//! `out!`/`outln!` — см. `CliError`.
//!
//! Штатная сборка — БЕЗ ML-рантаймов:
//! `cargo build --release --bin chronica --no-default-features --features store`.
//! Работа с базой — чистое чтение SQLite, поэтому такой бинарь не тянет за собой
//! ни ONNX Runtime, ни whisper.cpp и запускается без dylib рядом (именно этот
//! вариант обещает документация: «CLI читает ту же базу и не требует
//! запущенного приложения»).
//!
//! `transcribe <file.wav>` загружает ASR-бэкенд и транскрибирует 16-битный PCM
//! WAV (любой rate/каналы — ядро ресемплит в 16кГц моно), печатая текст, язык и
//! тайминги. Команда есть только в сборке с ASR-бэкендом (`sherpa`,
//! `whispercpp`, `coreml` или `mock-asr`); в штатной сборке она скрыта из
//! справки и печатает подсказку, как собрать вариант с ML.

use std::fmt;
use std::io::{self, ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;
use transcriber_core::asr::{create_backend, BackendInit};
use transcriber_core::audio::resample::{to_mono_16k_i16, TARGET_SAMPLE_RATE};
use transcriber_core::types::{Acceleration, ModelSpec};

#[cfg(feature = "store")]
use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
#[cfg(feature = "store")]
use std::io::IsTerminal;
#[cfg(feature = "store")]
use transcriber_core::store::{
    export, RangeStats, SearchHit, Store, MAX_PAGE_LIMIT, SESSION_STOP_ERROR, SESSION_STOP_USER,
    SNIPPET_CLOSE, SNIPPET_OPEN, SNIPPET_RADIUS,
};
#[cfg(feature = "store")]
use transcriber_core::types::{IntervalRecord, SessionRecord};

const CHUNK_SAMPLES: usize = 30 * TARGET_SAMPLE_RATE as usize;

/// Имя бинаря — берём из Cargo, чтобы help не расходился с реальностью.
const BIN: &str = env!("CARGO_BIN_NAME");

/// Скомпилирован ли в этот бинарь хоть один ASR-бэкенд.
///
/// Штатная сборка CLI (`--no-default-features --features store`) собирается без
/// ML-рантаймов, чтобы бинарь не получал динамических зависимостей на
/// ONNX Runtime / sherpa. `transcribe` в такой сборке невозможна: команда
/// скрыта из справки и печатает подсказку вместо непонятной ошибки загрузки
/// бэкенда.
const HAS_ASR_RUNTIME: bool = cfg!(any(
    feature = "sherpa",
    feature = "whispercpp",
    feature = "coreml",
    feature = "mock-asr"
));

// ---------------------------------------------------------------------------
// Вывод в stdout: unix-семантика конвейера
// ---------------------------------------------------------------------------

/// Причина преждевременного завершения команды.
///
/// Разделение принципиально для утилиты, которую зовут в конвейере: обрыв
/// stdout — штатный финал (читатель ушёл, писать больше некому), а любая
/// другая ошибка записи (нет места на диске при `> file`, отвалившийся том)
/// обязана дойти до пользователя.
#[derive(Debug)]
enum CliError {
    /// Читатель закрыл stdout (EPIPE): выходим молча с кодом 0 — так ведут
    /// себя `cat`, `grep`, `git log`.
    BrokenPipe,
    /// Настоящая ошибка: сообщение в stderr и ненулевой код возврата.
    Failed(String),
}

impl From<String> for CliError {
    fn from(msg: String) -> Self {
        CliError::Failed(msg)
    }
}

impl From<&str> for CliError {
    fn from(msg: &str) -> Self {
        CliError::Failed(msg.to_string())
    }
}

/// Разбор ошибки записи: EPIPE — «читатель ушёл», остальное — сбой.
fn classify_io(e: io::Error) -> CliError {
    if e.kind() == ErrorKind::BrokenPipe {
        CliError::BrokenPipe
    } else {
        CliError::Failed(format!("запись в stdout: {e}"))
    }
}

/// Запись текста в произвольный поток с тем же разбором ошибок, что у stdout.
///
/// Отделено от самого stdout, чтобы поведение (EPIPE — тихий выход, прочее —
/// ошибка) проверялось тестом на подставном потоке.
fn write_text<W: Write>(w: &mut W, text: &str) -> Result<(), CliError> {
    w.write_all(text.as_bytes()).map_err(classify_io)
}

/// Печать в stdout без перевода строки (замена `print!`).
fn print_fmt(args: fmt::Arguments) -> Result<(), CliError> {
    io::stdout().lock().write_fmt(args).map_err(classify_io)
}

/// Печать строки в stdout (замена `println!`); один захват блокировки на строку.
fn print_line(args: fmt::Arguments) -> Result<(), CliError> {
    let mut out = io::stdout().lock();
    out.write_fmt(args).map_err(classify_io)?;
    write_text(&mut out, "\n")
}

/// Сброс буфера stdout. Нужен явно: неявный сброс на выходе из процесса
/// проглатывает ошибку, а недописанный «хвост» (например, ENOSPC при
/// `> file`) пользователь обязан увидеть.
fn flush_out() -> Result<(), CliError> {
    io::stdout().lock().flush().map_err(classify_io)
}

/// `print!` для CLI: возвращает `Result` вместо паники на EPIPE.
macro_rules! out {
    ($($arg:tt)*) => { print_fmt(format_args!($($arg)*)) };
}

/// `println!` для CLI: возвращает `Result` вместо паники на EPIPE.
macro_rules! outln {
    () => { print_line(format_args!("")) };
    ($($arg:tt)*) => { print_line(format_args!($($arg)*)) };
}

/// Код возврата по результату команды: обрыв конвейера — тихий 0, прочие
/// ошибки — сообщение в stderr и 1.
fn exit_code(result: Result<(), CliError>) -> i32 {
    match result {
        Ok(()) | Err(CliError::BrokenPipe) => 0,
        Err(CliError::Failed(msg)) => {
            eprintln!("ошибка: {msg}");
            1
        }
    }
}

// ---------------------------------------------------------------------------
// Точка входа
// ---------------------------------------------------------------------------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let code = run(&args);
    // Буфер stdout сбрасываем сами: только здесь видно ошибку записи хвоста.
    let code = match flush_out() {
        Ok(()) | Err(CliError::BrokenPipe) => code,
        Err(CliError::Failed(msg)) => {
            eprintln!("ошибка: {msg}");
            if code == 0 {
                1
            } else {
                code
            }
        }
    };
    std::process::exit(code);
}

fn run(argv: &[String]) -> i32 {
    let cmd = argv.get(1).map(String::as_str).unwrap_or("help");
    match cmd {
        "transcribe" if !HAS_ASR_RUNTIME => {
            eprintln!(
                "ошибка: команда `transcribe` доступна только в сборке с ML-рантаймом.\n\
                 Соберите бинарь с реальным ASR:\n\
                 \x20 cd core && cargo build --release --bin {BIN} --features sherpa"
            );
            2
        }
        "transcribe" => exit_code(transcribe(&argv[2..])),
        "help" | "--help" | "-h" => exit_code(out!("{}", help_text())),
        "today" | "transcript" | "search" | "stats" | "export" | "sessions" | "db" => {
            store_command(cmd, &argv[2..])
        }
        other => {
            eprintln!("неизвестная команда {other:?}\n");
            eprint!("{}", help_text());
            2
        }
    }
}

fn help_text() -> String {
    // `transcribe` показываем только там, где она работает: в штатной сборке
    // без ML-рантайма её нет смысла предлагать.
    let asr_section: &str = if HAS_ASR_RUNTIME {
        "\nПроверка ASR:\n  \
         transcribe <file.wav> [--models-path DIR] [--model ID] [--family parakeet|whisper]\n\
         \x20                       [--lang auto|ru|en] [--accel auto|cpu|coreml|gpu]\n"
    } else {
        ""
    };
    format!(
        "\
{BIN} — быстрый доступ к локальным данным Chronica.

Использование:
  {BIN} <команда> [опции]

Данные:
  today [--channel mic|remote] [--format text|md|json]
        Транскрипция за сегодняшние локальные сутки.
  transcript --from <ISO|YYYY-MM-DD> --to <...> [--channel C] [--format text|md|json]
        Транскрипция за период.
  search \"<запрос>\" [--from ...] [--to ...] [--limit N]
        Полнотекстовый поиск по расшифровкам: время, канал и фрагмент вокруг
        совпадения (по умолчанию --limit 20; полный текст — в --json).
  stats [--from ...] [--to ...]
        Слова, интервалы и минуты речи по каналам.
  sessions [--from ...] [--to ...] [--limit N]
        Сессии записи: когда включали и выключали запись (по умолчанию —
        последние 50, новые сверху). Незакрытая сессия — приложение закрылось,
        не остановив запись.
  export --from ... --to ... [--format md|json] [-o FILE]
        Документ журнала (та же форма, что у /api/v1/export и экспорта в приложении).

Обслуживание базы:
  db info                  версия схемы, размер, число записей
  db vacuum                сжать файл базы
  db retention --days N    удалить всё старше N суток
{asr_section}
Общие опции:
  --store PATH   путь к transcriber.sqlite
                 (по умолчанию ~/Library/Application Support/Chronica/store/transcriber.sqlite;
                  если там базы нет, а по старому пути
                  ~/Library/Application Support/Transcriber/store/transcriber.sqlite она есть —
                  берётся старая, с предупреждением в stderr)
  --json         то же, что --format json
  -h, --help     эта справка

Даты вида YYYY-MM-DD трактуются как ЛОКАЛЬНЫЕ сутки: --from берёт начало дня,
--to — его конец, поэтому `--from 2026-09-01 --to 2026-09-01` это ровно эти сутки.
Также принимаются ISO-8601 с таймзоной и epoch-миллисекунды.
"
    )
}

// ---------------------------------------------------------------------------
// Разбор аргументов (вручную, без внешних зависимостей)
// ---------------------------------------------------------------------------

/// Флаги без значения. Нужны, чтобы `search --json \"запрос\"` не съел запрос
/// как значение `--json`.
#[cfg(feature = "store")]
const BOOL_FLAGS: &[&str] = &["json", "help"];

#[cfg(feature = "store")]
#[derive(Debug, Default, PartialEq)]
struct Args {
    flags: Vec<(String, String)>,
    positional: Vec<String>,
}

#[cfg(feature = "store")]
impl Args {
    fn parse(argv: &[String]) -> Args {
        let mut out = Args::default();
        let mut i = 0;
        while i < argv.len() {
            let arg = &argv[i];
            let long = arg.strip_prefix("--");
            let short = if long.is_none() && arg.len() > 1 {
                arg.strip_prefix('-')
            } else {
                None
            };
            let name = match (long, short) {
                (Some(l), _) => l.to_string(),
                (None, Some("o")) => "output".to_string(),
                (None, Some("h")) => "help".to_string(),
                (None, Some(other)) => other.to_string(),
                (None, None) => {
                    out.positional.push(arg.clone());
                    i += 1;
                    continue;
                }
            };
            if let Some((k, v)) = name.split_once('=') {
                out.flags.push((k.to_string(), v.to_string()));
                i += 1;
                continue;
            }
            if BOOL_FLAGS.contains(&name.as_str()) {
                out.flags.push((name, "true".into()));
                i += 1;
                continue;
            }
            match argv.get(i + 1) {
                Some(v) if !v.starts_with('-') => {
                    out.flags.push((name, v.clone()));
                    i += 2;
                }
                _ => {
                    out.flags.push((name, "true".into()));
                    i += 1;
                }
            }
        }
        out
    }

    fn get(&self, key: &str) -> Option<&str> {
        self.flags
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
            .filter(|v| !v.is_empty())
    }

    fn flag(&self, key: &str) -> bool {
        matches!(self.get(key), Some("true"))
    }

    /// `--json` — синоним `--format json`.
    fn format(&self, default: &str) -> String {
        if self.flag("json") {
            return "json".into();
        }
        self.get("format").unwrap_or(default).to_string()
    }
}

// ---------------------------------------------------------------------------
// Команды по базе
// ---------------------------------------------------------------------------

#[cfg(not(feature = "store"))]
fn store_command(_cmd: &str, _argv: &[String]) -> i32 {
    eprintln!("ошибка: бинарь собран без фичи `store`, работа с базой недоступна");
    2
}

#[cfg(feature = "store")]
fn store_command(cmd: &str, argv: &[String]) -> i32 {
    let args = Args::parse(argv);
    if args.flag("help") {
        return exit_code(out!("{}", help_text()));
    }
    let result = match cmd {
        "today" => cmd_today(&args),
        "transcript" => cmd_transcript(&args),
        "search" => cmd_search(&args),
        "stats" => cmd_stats(&args),
        "export" => cmd_export(&args),
        "sessions" => cmd_sessions(&args),
        "db" => cmd_db(&args),
        other => Err(format!("неизвестная команда {other:?}").into()),
    };
    exit_code(result)
}

#[cfg(feature = "store")]
fn cmd_today(args: &Args) -> Result<(), CliError> {
    let (from, to) = today_bounds(Local::now());
    let store = open_store(args)?;
    let channel = args.get("channel");
    let items = collect_range(
        &store,
        from.timestamp_millis(),
        to.timestamp_millis(),
        channel,
    )?;
    print_transcript(
        &items,
        &from.to_rfc3339(),
        &to.to_rfc3339(),
        channel,
        args,
        Some(&today_title(from)),
    )
}

/// Заголовок текстовой выдачи `today`: сами реплики печатаются как `[ЧЧ:ММ]`,
/// поэтому дату видно только из него.
#[cfg(feature = "store")]
fn today_title(day: DateTime<Local>) -> String {
    format!("Сегодня, {}", day.format("%Y-%m-%d"))
}

#[cfg(feature = "store")]
fn cmd_transcript(args: &Args) -> Result<(), CliError> {
    let (from, to) = required_range(args)?;
    let store = open_store(args)?;
    let channel = args.get("channel");
    let items = collect_range(&store, from.ms, to.ms, channel)?;
    print_transcript(&items, &from.iso, &to.iso, channel, args, None)
}

#[cfg(feature = "store")]
fn cmd_search(args: &Args) -> Result<(), CliError> {
    let query = args
        .positional
        .first()
        .ok_or("нужен поисковый запрос: {BIN} search \"слова\"".replace("{BIN}", BIN))?;
    let (from, to) = optional_range(args)?;
    let limit: u32 = match args.get("limit") {
        Some(s) => s
            .parse()
            .map_err(|_| format!("невалидный --limit {s:?}: целое число"))?,
        None => SEARCH_DEFAULT_LIMIT,
    };

    let store = open_store(args)?;
    let hits = store
        .search_hits_ms(query, from.ms, to.ms, limit, 0, SNIPPET_RADIUS)
        .map_err(|e| format!("{e}"))?;

    if args.format("text") == "json" {
        let value = serde_json::json!({
            "query": query,
            "engine": if store.fts_enabled() { "fts5" } else { "like" },
            "count": hits.len(),
            "items": hits.iter().map(search_hit_json).collect::<Vec<_>>(),
        });
        return outln!("{value}");
    }

    if hits.is_empty() {
        return outln!("ничего не найдено по запросу {query:?}");
    }
    let tty = io::stdout().is_terminal();
    for hit in &hits {
        outln!("{}  {}", hit.interval.start_at, hit.channel_id)?;
        outln!("  {}", highlight(&hit.snippet, tty))?;
    }
    Ok(())
}

/// Дефолтный `--limit` у `search`: столько попаданий с фрагментами ещё читаемо
/// в терминале (полный текст интервалов лежит в `--json`).
#[cfg(feature = "store")]
const SEARCH_DEFAULT_LIMIT: u32 = 20;

/// Выделение совпадения во фрагменте: в терминале — ANSI-жирный, иначе
/// маркеры-ёлочки остаются как есть (годится для пайпа и файла).
#[cfg(feature = "store")]
fn highlight(snippet: &str, tty: bool) -> String {
    if !tty {
        return snippet.to_string();
    }
    snippet
        .replace(SNIPPET_OPEN, "\u{1b}[1m")
        .replace(SNIPPET_CLOSE, "\u{1b}[0m")
}

/// Один результат поиска в JSON: поля интервала как раньше плюс аддитивные
/// `channel_id` и `snippet` (та же форма, что у `/api/v1/search`).
#[cfg(feature = "store")]
fn search_hit_json(hit: &SearchHit) -> serde_json::Value {
    serde_json::json!({
        "id": hit.interval.id,
        "start_at": hit.interval.start_at,
        "end_at": hit.interval.end_at,
        "duration_s": hit.interval.duration_s,
        "channels": hit.interval.channels,
        "channel_id": hit.channel_id,
        "snippet": hit.snippet,
    })
}

#[cfg(feature = "store")]
fn cmd_stats(args: &Args) -> Result<(), CliError> {
    let (from, to) = optional_range(args)?;
    let store = open_store(args)?;
    let mut stats = store.stats_ms(from.ms, to.ms).map_err(|e| format!("{e}"))?;
    if !from.iso.is_empty() {
        stats.from = from.iso.clone();
    }
    if !to.iso.is_empty() {
        stats.to = to.iso.clone();
    }

    if args.format("text") == "json" {
        outln!("{}", stats_json(&stats))?;
    } else {
        // Границы не заданы — подпись периода берём из фактических границ
        // данных, иначе получается бессмысленное «Период: — — —».
        let bounds = if from.iso.is_empty() || to.iso.is_empty() {
            store.info().ok()
        } else {
            None
        };
        let (first, last) = match &bounds {
            Some(i) => (i.first_start_at.as_deref(), i.last_end_at.as_deref()),
            None => (None, None),
        };
        out!(
            "{}",
            stats_text(&stats, &period_label(&from.iso, &to.iso, first, last))
        )?;
    }
    Ok(())
}

#[cfg(feature = "store")]
fn cmd_export(args: &Args) -> Result<(), CliError> {
    let (from, to) = required_range(args)?;
    let store = open_store(args)?;
    let items = collect_range(&store, from.ms, to.ms, None)?;
    let exported_at = Local::now().to_rfc3339();

    let format = args.format("json");
    let body = match format.as_str() {
        "json" => {
            let doc = export::journal_document(&items, &from.iso, &to.iso, &exported_at);
            serde_json::to_string_pretty(&doc).map_err(|e| format!("сериализация: {e}"))?
        }
        "md" | "markdown" => export::journal_markdown(&items, &from.iso, &to.iso, &exported_at),
        other => return Err(format!("неизвестный --format {other:?}: ожидается md|json").into()),
    };

    match args.get("output") {
        Some(path) => {
            std::fs::write(path, &body).map_err(|e| format!("запись в {path}: {e}"))?;
            eprintln!("записано: {path} ({} интервалов)", items.len());
        }
        None => outln!("{body}")?,
    }
    Ok(())
}

/// Дефолтный `--limit` у `sessions`: столько строк ещё читаемо в терминале.
#[cfg(feature = "store")]
const SESSIONS_DEFAULT_LIMIT: u32 = 50;

/// `sessions` — когда запись включали и выключали.
///
/// Без периода — последние `--limit` сессий (новые сверху). С периодом —
/// сессии, у которых в него попадает начало или конец, по возрастанию времени.
#[cfg(feature = "store")]
fn cmd_sessions(args: &Args) -> Result<(), CliError> {
    let (from, to) = optional_range(args)?;
    let limit: u32 = match args.get("limit") {
        Some(s) => s
            .parse()
            .map_err(|_| format!("невалидный --limit {s:?}: целое число"))?,
        None => SESSIONS_DEFAULT_LIMIT,
    };
    if limit == 0 {
        return Err("--limit должен быть больше нуля".into());
    }

    let store = open_store(args)?;
    let ranged = from.ms != i64::MIN || to.ms != i64::MAX;
    let items = if ranged {
        let mut v = store
            .sessions_ms(from.ms, to.ms)
            .map_err(|e| format!("{e}"))?;
        v.truncate(limit as usize);
        v
    } else {
        store.last_sessions(limit).map_err(|e| format!("{e}"))?
    };

    if args.format("text") == "json" {
        return outln!("{}", sessions_json(&items));
    }
    out!("{}", sessions_text(&items))
}

/// Длительность сессии в секундах; `None` — сессия не закрыта либо времена
/// в базе нечитаемы.
#[cfg(feature = "store")]
fn session_duration_s(s: &SessionRecord) -> Option<f64> {
    let start = DateTime::parse_from_rfc3339(&s.started_at).ok()?;
    let end = DateTime::parse_from_rfc3339(&s.ended_at).ok()?;
    let secs = (end - start).num_milliseconds() as f64 / 1000.0;
    (secs >= 0.0).then_some(secs)
}

/// Человекочитаемая длительность: секунды → минуты → часы.
#[cfg(feature = "store")]
fn human_duration(seconds: f64) -> String {
    if seconds < 60.0 {
        format!("{seconds:.0} с")
    } else if seconds < 3600.0 {
        format!("{:.1} мин", seconds / 60.0)
    } else {
        format!("{:.1} ч", seconds / 3600.0)
    }
}

/// Причина остановки для человека. Пустая строка = сессию никто не закрыл:
/// приложение завершилось, не остановив запись.
#[cfg(feature = "store")]
fn session_reason_label(reason: &str) -> &'static str {
    match reason {
        SESSION_STOP_USER => "пользователь",
        SESSION_STOP_ERROR => "авария",
        "" => "— (не закрыта)",
        _ => "другое",
    }
}

/// Метка времени для таблицы: `YYYY-MM-DD HH:MM:SS` в той зоне, в которой
/// время записано.
///
/// Ядро пишет `to_rfc3339()` с микросекундами (`…T18:27:30.333255+03:00`) —
/// в таблице это 32 символа шума, из-за которых колонки разъезжаются.
/// Неразбираемая строка печатается как есть: лучше некрасиво, чем молча пусто.
#[cfg(feature = "store")]
fn session_stamp(iso: &str) -> String {
    match DateTime::parse_from_rfc3339(iso) {
        Ok(dt) => dt.format("%Y-%m-%d %H:%M:%S").to_string(),
        Err(_) => iso.to_string(),
    }
}

/// Таблица «начало · конец · причина · длительность».
///
/// Чистая функция: формат проверяется тестом без базы и терминала.
#[cfg(feature = "store")]
fn sessions_text(items: &[SessionRecord]) -> String {
    if items.is_empty() {
        return "сессий записи не найдено\n".to_string();
    }
    let mut out = format!(
        "{:<21}{:<21}{:<16}{:>13}\n",
        "Начало", "Конец", "Причина", "Длительность"
    );
    for s in items {
        let ended = if s.ended_at.is_empty() {
            "—".to_string()
        } else {
            session_stamp(&s.ended_at)
        };
        let duration = match session_duration_s(s) {
            Some(secs) => human_duration(secs),
            None => "—".to_string(),
        };
        out.push_str(&format!(
            "{:<21}{:<21}{:<16}{:>13}\n",
            session_stamp(&s.started_at),
            ended,
            session_reason_label(&s.stop_reason),
            duration
        ));
    }
    out
}

/// Те же сессии для скриптов: форма `/api/v1/sessions` плюс `duration_s`.
#[cfg(feature = "store")]
fn sessions_json(items: &[SessionRecord]) -> String {
    serde_json::json!({
        "count": items.len(),
        "items": items.iter().map(|s| serde_json::json!({
            "id": s.id,
            "started_at": s.started_at,
            "ended_at": s.ended_at,
            "stop_reason": s.stop_reason,
            "duration_s": session_duration_s(s),
        })).collect::<Vec<_>>(),
    })
    .to_string()
}

#[cfg(feature = "store")]
fn cmd_db(args: &Args) -> Result<(), CliError> {
    let sub = args
        .positional
        .first()
        .map(String::as_str)
        .ok_or("нужна подкоманда: db info | db vacuum | db retention --days N")?;
    let store = open_store(args)?;

    match sub {
        "info" => {
            let info = store.info().map_err(|e| format!("{e}"))?;
            if args.format("text") == "json" {
                outln!(
                    "{}",
                    serde_json::json!({
                        "path": info.path,
                        "schema_version": info.schema_version,
                        "fts5": info.fts5,
                        "size_bytes": info.size_bytes,
                        "wal_bytes": info.wal_bytes,
                        "intervals": info.intervals,
                        "interval_texts": info.interval_texts,
                        "voice_events": info.voice_events,
                        "sessions": info.sessions,
                        "first_start_at": info.first_start_at,
                        "last_end_at": info.last_end_at,
                    })
                )?;
            } else {
                outln!("файл:            {}", info.path)?;
                outln!("версия схемы:    {}", info.schema_version)?;
                outln!(
                    "поиск:           {}",
                    if info.fts5 {
                        "FTS5"
                    } else {
                        "LIKE (без FTS5)"
                    }
                )?;
                outln!(
                    "размер:          {} (+WAL {})",
                    human_bytes(info.size_bytes),
                    human_bytes(info.wal_bytes)
                )?;
                outln!("интервалов:      {}", info.intervals)?;
                outln!("текстов:         {}", info.interval_texts)?;
                outln!("событий речи:    {}", info.voice_events)?;
                outln!("сессий:          {}", info.sessions)?;
                outln!(
                    "период:          {} — {}",
                    info.first_start_at.as_deref().unwrap_or("—"),
                    info.last_end_at.as_deref().unwrap_or("—")
                )?;
            }
            Ok(())
        }
        "vacuum" => {
            let before = store.info().map_err(|e| format!("{e}"))?.size_bytes;
            store.optimize().map_err(|e| format!("{e}"))?;
            store.vacuum().map_err(|e| format!("{e}"))?;
            let after = store.info().map_err(|e| format!("{e}"))?.size_bytes;
            outln!("vacuum: {} -> {}", human_bytes(before), human_bytes(after))
        }
        "retention" => {
            let days: i64 = args
                .get("days")
                .ok_or("нужен --days N")?
                .parse()
                .map_err(|_| "невалидный --days: целое число суток".to_string())?;
            if days < 0 {
                return Err("--days не может быть отрицательным".into());
            }
            let deleted = store
                .retention_sweep_all(days)
                .map_err(|e| format!("{e}"))?;
            outln!("удалено строк: {deleted} (хранение: {days} сут.)")
        }
        other => {
            Err(format!("неизвестная подкоманда db {other:?}: info | vacuum | retention").into())
        }
    }
}

// ---------------------------------------------------------------------------
// Вспомогательное для команд по базе
// ---------------------------------------------------------------------------

/// Момент времени, разобранный из аргумента (мс + ISO для отображения).
#[cfg(feature = "store")]
#[derive(Debug, Clone, PartialEq)]
struct TimeArg {
    ms: i64,
    iso: String,
}

/// Разбор границы периода.
///
/// - `YYYY-MM-DD` — локальные сутки: `end=false` даёт начало дня, `end=true` —
///   его конец (начало следующего), поэтому `--from D --to D` = ровно эти сутки;
/// - ISO-8601 с таймзоной — как есть;
/// - целое число — epoch-миллисекунды UTC.
#[cfg(feature = "store")]
fn parse_bound(raw: &str, end: bool) -> Result<TimeArg, String> {
    let s = raw.trim();
    if s.is_empty() {
        return Err("пустое значение времени".into());
    }

    let digits = s.strip_prefix('-').unwrap_or(s);
    if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
        let ms: i64 = s
            .parse()
            .map_err(|_| format!("невалидные epoch-миллисекунды {raw:?}"))?;
        let iso = Utc
            .timestamp_millis_opt(ms)
            .single()
            .ok_or_else(|| format!("epoch-миллисекунды вне диапазона: {raw:?}"))?
            .with_timezone(&Local)
            .to_rfc3339();
        return Ok(TimeArg { ms, iso });
    }

    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Ok(TimeArg {
            ms: dt.timestamp_millis(),
            iso: s.to_string(),
        });
    }

    if let Ok(date) = NaiveDate::parse_from_str(s, "%Y-%m-%d") {
        let day = date
            .and_hms_opt(0, 0, 0)
            .ok_or_else(|| format!("невалидная дата {raw:?}"))?;
        let start = Local
            .from_local_datetime(&day)
            .earliest()
            .ok_or_else(|| format!("дата {raw:?} не существует в локальной зоне"))?;
        let at = if end {
            start + Duration::days(1)
        } else {
            start
        };
        return Ok(TimeArg {
            ms: at.timestamp_millis(),
            iso: at.to_rfc3339(),
        });
    }

    Err(format!(
        "невалидное время {raw:?}: ожидается ISO-8601 с таймзоной, YYYY-MM-DD или epoch-мс"
    ))
}

/// Границы сегодняшних локальных суток.
#[cfg(feature = "store")]
fn today_bounds(now: DateTime<Local>) -> (DateTime<Local>, DateTime<Local>) {
    let start = now
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|d| Local.from_local_datetime(&d).earliest())
        .unwrap_or(now);
    (start, start + Duration::days(1))
}

#[cfg(feature = "store")]
fn required_range(args: &Args) -> Result<(TimeArg, TimeArg), String> {
    let from = args.get("from").ok_or("нужен --from")?;
    let to = args.get("to").ok_or("нужен --to")?;
    Ok((parse_bound(from, false)?, parse_bound(to, true)?))
}

#[cfg(feature = "store")]
fn optional_range(args: &Args) -> Result<(TimeArg, TimeArg), String> {
    let from = match args.get("from") {
        Some(s) => parse_bound(s, false)?,
        None => TimeArg {
            ms: i64::MIN,
            iso: String::new(),
        },
    };
    let to = match args.get("to") {
        Some(s) => parse_bound(s, true)?,
        None => TimeArg {
            ms: i64::MAX,
            iso: String::new(),
        },
    };
    Ok((from, to))
}

/// Папка данных приложения в `~/Library/Application Support`.
const APP_SUPPORT_DIR: &str = "Chronica";

/// Прежнее имя папки данных (до переименования продукта). Читаем её, если
/// новой ещё нет: обновлённый CLI не должен «терять» уже накопленную базу.
const LEGACY_APP_SUPPORT_DIR: &str = "Transcriber";

/// Путь к базе относительно папки данных приложения.
#[cfg(feature = "store")]
const STORE_REL_PATH: &str = "store/transcriber.sqlite";

/// Каталог моделей относительно папки данных приложения.
const MODELS_REL_PATH: &str = "Models";

/// Выбор пути внутри папки данных: новый (`Chronica`), а если его на диске нет,
/// но унаследованный (`Transcriber`) есть — унаследованный.
///
/// Чистая функция: `home` и предикат существования приходят снаружи, поэтому
/// поведение проверяется тестом без реальной файловой системы. Второй элемент
/// результата — признак «взят унаследованный путь» (повод предупредить).
fn pick_app_support_path(
    home: &Path,
    rel: &str,
    exists: &dyn Fn(&Path) -> bool,
) -> (PathBuf, bool) {
    let support = home.join("Library/Application Support");
    let current = support.join(APP_SUPPORT_DIR).join(rel);
    if exists(&current) {
        return (current, false);
    }
    let legacy = support.join(LEGACY_APP_SUPPORT_DIR).join(rel);
    if exists(&legacy) {
        return (legacy, true);
    }
    (current, false)
}

/// Домашний каталог пользователя (или `.`, если `HOME` не задан).
fn home_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
}

/// Путь к базе по умолчанию + признак унаследованного расположения.
#[cfg(feature = "store")]
fn default_store_path() -> (String, bool) {
    let (path, legacy) = pick_app_support_path(&home_dir(), STORE_REL_PATH, &|p| p.exists());
    (path.to_string_lossy().into_owned(), legacy)
}

#[cfg(feature = "store")]
fn open_store(args: &Args) -> Result<Store, String> {
    let path = match args.get("store") {
        Some(explicit) => explicit.to_string(),
        None => {
            let (path, legacy) = default_store_path();
            if legacy {
                eprintln!(
                    "внимание: используется база по старому пути {path}\n\
                     новая папка данных — ~/Library/Application Support/{APP_SUPPORT_DIR}"
                );
            }
            path
        }
    };
    if !std::path::Path::new(&path).exists() {
        return Err(format!(
            "база не найдена: {path}\nукажите путь через --store PATH"
        ));
    }
    Store::open(&path).map_err(|e| format!("не удалось открыть базу {path}: {e}"))
}

/// Постраничный сбор интервалов за период (не один гигантский SELECT).
#[cfg(feature = "store")]
fn collect_range(
    store: &Store,
    from_ms: i64,
    to_ms: i64,
    channel: Option<&str>,
) -> Result<Vec<IntervalRecord>, String> {
    let mut out: Vec<IntervalRecord> = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let page = store
            .query_intervals_page(from_ms, to_ms, channel, MAX_PAGE_LIMIT, cursor.as_deref())
            .map_err(|e| format!("{e}"))?;
        let empty = page.items.is_empty();
        out.extend(page.items);
        match page.next_cursor {
            Some(c) if !empty => cursor = Some(c),
            _ => break,
        }
    }
    Ok(out)
}

#[cfg(feature = "store")]
fn print_transcript(
    items: &[IntervalRecord],
    from_iso: &str,
    to_iso: &str,
    channel: Option<&str>,
    args: &Args,
    title: Option<&str>,
) -> Result<(), CliError> {
    match args.format("text").as_str() {
        "text" => {
            let body = export::transcript_text(items);
            if let Some(t) = title {
                outln!("{t}")?;
            }
            if body.is_empty() {
                eprintln!("за период записей нет");
            }
            out!("{body}")?;
        }
        "md" | "markdown" => out!(
            "{}",
            export::transcript_markdown(items, from_iso, to_iso, channel)
        )?,
        "json" => {
            let value = serde_json::json!({
                "from": from_iso,
                "to": to_iso,
                "channel": channel,
                "count": items.len(),
                "text": export::transcript_text(items),
                "intervals": items,
            });
            outln!("{value}")?;
        }
        other => {
            return Err(format!("неизвестный --format {other:?}: ожидается text|md|json").into())
        }
    }
    Ok(())
}

/// Подпись периода для `stats`.
///
/// - обе границы заданы — печатаем их как есть;
/// - границ нет — «всё время» с фактическими датами данных в скобках;
/// - задана одна — вторую подставляем из данных;
/// - данных в базе нет — честное «данных нет».
#[cfg(feature = "store")]
fn period_label(from: &str, to: &str, first: Option<&str>, last: Option<&str>) -> String {
    if !from.is_empty() && !to.is_empty() {
        return format!("{from} — {to}");
    }
    let ymd = |iso: &str| iso.split('T').next().unwrap_or(iso).to_string();
    let a = if from.is_empty() {
        first.map(ymd)
    } else {
        Some(from.to_string())
    };
    let b = if to.is_empty() {
        last.map(ymd)
    } else {
        Some(to.to_string())
    };
    match (a, b) {
        (Some(a), Some(b)) if from.is_empty() && to.is_empty() => {
            format!("всё время (с {a} по {b})")
        }
        (Some(a), Some(b)) => format!("{a} — {b}"),
        _ => "всё время (данных нет)".to_string(),
    }
}

#[cfg(feature = "store")]
fn stats_text(s: &RangeStats, period: &str) -> String {
    let mut out = String::new();
    out.push_str(&format!("Период: {period}\n"));
    out.push_str(&format!(
        "Интервалов: {}   слов: {}   длительность: {:.1} мин\n\n",
        s.intervals,
        s.words,
        s.duration_seconds / 60.0
    ));
    out.push_str(&format!(
        "{:<12}{:>11}{:>9}{:>14}\n",
        "Канал", "Интервалы", "Слова", "Минуты речи"
    ));
    for c in &s.channels {
        out.push_str(&format!(
            "{:<12}{:>11}{:>9}{:>14.1}\n",
            c.channel_id,
            c.intervals,
            c.words,
            c.speech_seconds / 60.0
        ));
    }
    if s.channels.is_empty() {
        out.push_str("(за период речи не записано)\n");
    }
    out
}

#[cfg(feature = "store")]
fn stats_json(s: &RangeStats) -> String {
    serde_json::json!({
        "from": s.from,
        "to": s.to,
        "intervals": s.intervals,
        "words": s.words,
        "duration_seconds": s.duration_seconds,
        "channels": s.channels.iter().map(|c| serde_json::json!({
            "channel_id": c.channel_id,
            "intervals": c.intervals,
            "words": c.words,
            "speech_seconds": c.speech_seconds,
        })).collect::<Vec<_>>(),
    })
    .to_string()
}

#[cfg(feature = "store")]
fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["Б", "КБ", "МБ", "ГБ"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} {}", UNITS[0])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

// ---------------------------------------------------------------------------
// ASR-харнесс (без изменений)
// ---------------------------------------------------------------------------

/// Ошибки самого харнесса (аргументы, WAV, загрузка бэкенда) как и раньше
/// печатаются в stderr и не меняют код возврата — здесь `Err` возникает
/// только на ошибке записи в stdout.
fn transcribe(args: &[String]) -> Result<(), CliError> {
    let mut wav: Option<String> = None;
    let mut models_path = default_models_path();
    let mut model_id = "parakeet-tdt-0.6b-v3-int8".to_string();
    let mut family = "parakeet".to_string();
    let mut lang: Option<String> = None;
    let mut accel = Acceleration::Auto;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--models-path" => {
                models_path = take(args, &mut i);
            }
            "--model" => {
                model_id = take(args, &mut i);
            }
            "--family" => {
                family = take(args, &mut i);
            }
            "--lang" => {
                let l = take(args, &mut i);
                lang = if l == "auto" { None } else { Some(l) };
            }
            "--accel" => {
                accel = match take(args, &mut i).as_str() {
                    "cpu" => Acceleration::Cpu,
                    "coreml" => Acceleration::CoreMl,
                    "gpu" => Acceleration::Gpu,
                    _ => Acceleration::Auto,
                };
            }
            other if wav.is_none() => {
                wav = Some(other.to_string());
            }
            other => {
                eprintln!("unexpected arg: {other}");
                return Ok(());
            }
        }
        i += 1;
    }

    let Some(wav) = wav else {
        eprintln!("error: WAV path required");
        return Ok(());
    };

    let model = match family.as_str() {
        "whisper" => ModelSpec::Whisper {
            id: model_id.clone(),
        },
        _ => ModelSpec::Parakeet {
            id: model_id.clone(),
        },
    };

    outln!("model: {family}/{model_id}  models_path: {models_path}")?;
    let (samples_i16, sr, ch) = match read_wav_i16(&wav) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("WAV error: {e}");
            return Ok(());
        }
    };
    outln!("input: {} samples @ {sr}Hz x{ch}ch", samples_i16.len())?;

    let mono16 = to_mono_16k_i16(&samples_i16, sr, ch);
    let audio_secs = mono16.len() as f32 / TARGET_SAMPLE_RATE as f32;
    let audio_f32: Vec<f32> = mono16.iter().map(|&s| s as f32 / 32768.0).collect();
    outln!("resampled: {:.1}s of 16kHz mono", audio_secs)?;

    let init = BackendInit {
        model,
        models_path,
        n_threads: 4,
        acceleration: accel,
    };
    let t_load = Instant::now();
    let mut backend = match create_backend(&init) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("backend load failed: {e}");
            return Ok(());
        }
    };
    outln!(
        "backend loaded in {:.2}s (multi_candidate={})",
        t_load.elapsed().as_secs_f32(),
        backend.supports_multi_candidate()
    )?;

    let t0 = Instant::now();
    let mut parts: Vec<String> = Vec::new();
    let mut detected = String::new();
    for chunk in audio_f32.chunks(CHUNK_SAMPLES) {
        if chunk.iter().all(|&s| s == 0.0) {
            continue;
        }
        match backend.transcribe_once(chunk, lang.as_deref()) {
            Ok(r) => {
                if let Some(l) = r.language {
                    if !l.is_empty() {
                        detected = l;
                    }
                }
                if !r.text.trim().is_empty() {
                    parts.push(r.text.trim().to_string());
                }
            }
            Err(e) => eprintln!("chunk error: {e}"),
        }
    }
    let proc = t0.elapsed().as_secs_f32();
    let text = parts.join(" ");
    outln!("\n──────── result ────────")?;
    outln!("text: {text}")?;
    outln!(
        "detected_language: {}",
        if detected.is_empty() {
            "—"
        } else {
            &detected
        }
    )?;
    outln!(
        "proc: {proc:.2}s  audio: {audio_secs:.2}s  RTF: {:.3}",
        if audio_secs > 0.0 {
            proc / audio_secs
        } else {
            0.0
        }
    )
}

fn take(args: &[String], i: &mut usize) -> String {
    *i += 1;
    args.get(*i).cloned().unwrap_or_default()
}

/// Каталог моделей по умолчанию — та же папка данных, что у базы (с тем же
/// откатом на унаследованное имя).
fn default_models_path() -> String {
    let (path, _legacy) = pick_app_support_path(&home_dir(), MODELS_REL_PATH, &|p| p.exists());
    path.to_string_lossy().into_owned()
}

/// Minimal 16-bit PCM WAV reader. Returns (interleaved i16, sample_rate, channels).
fn read_wav_i16(path: &str) -> Result<(Vec<i16>, u32, u8), String> {
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".into());
    }
    let mut pos = 12;
    let (mut sr, mut ch, mut bits) = (16_000u32, 1u8, 16u16);
    let mut data: Option<(usize, usize)> = None;
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes([
            bytes[pos + 4],
            bytes[pos + 5],
            bytes[pos + 6],
            bytes[pos + 7],
        ]) as usize;
        let body = pos + 8;
        if id == b"fmt " && body + 16 <= bytes.len() {
            ch = u16::from_le_bytes([bytes[body + 2], bytes[body + 3]]) as u8;
            sr = u32::from_le_bytes([
                bytes[body + 4],
                bytes[body + 5],
                bytes[body + 6],
                bytes[body + 7],
            ]);
            bits = u16::from_le_bytes([bytes[body + 14], bytes[body + 15]]);
        } else if id == b"data" {
            data = Some((body, (body + size).min(bytes.len())));
        }
        pos = body + size + (size & 1);
    }
    if bits != 16 {
        return Err(format!("only 16-bit PCM supported (got {bits}-bit)"));
    }
    let (start, end) = data.ok_or("no data chunk")?;
    let samples: Vec<i16> = bytes[start..end]
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect();
    Ok((samples, sr, ch.max(1)))
}

#[cfg(all(test, feature = "store"))]
mod tests {
    use super::*;
    use transcriber_core::store::ChannelStats;

    fn args(items: &[&str]) -> Args {
        Args::parse(&items.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn parses_long_flags_values_and_positionals() {
        let a = args(&["--from", "2026-09-01", "--to=2026-09-02", "запрос"]);
        assert_eq!(a.get("from"), Some("2026-09-01"));
        assert_eq!(a.get("to"), Some("2026-09-02"));
        assert_eq!(a.positional, vec!["запрос".to_string()]);
        assert!(a.get("missing").is_none());
    }

    /// `--json` не должен съедать следующий позиционный аргумент.
    #[test]
    fn boolean_flags_do_not_consume_next_argument() {
        let a = args(&["--json", "релиз"]);
        assert!(a.flag("json"));
        assert_eq!(a.positional, vec!["релиз".to_string()]);
        assert_eq!(a.format("text"), "json");
    }

    #[test]
    fn short_flags_map_to_long_names() {
        let a = args(&["-o", "out.md", "-h"]);
        assert_eq!(a.get("output"), Some("out.md"));
        assert!(a.flag("help"));
    }

    #[test]
    fn format_flag_precedence() {
        assert_eq!(args(&[]).format("text"), "text");
        assert_eq!(args(&["--format", "md"]).format("text"), "md");
        // --json перекрывает --format.
        assert_eq!(args(&["--format", "md", "--json"]).format("text"), "json");
    }

    /// Дата без времени — локальные сутки; `--to` берёт КОНЕЦ дня.
    #[test]
    fn date_only_bounds_cover_the_whole_local_day() {
        let from = parse_bound("2026-09-01", false).unwrap();
        let to = parse_bound("2026-09-01", true).unwrap();
        assert_eq!(to.ms - from.ms, 24 * 60 * 60 * 1000);
        assert!(from.iso.starts_with("2026-09-01T00:00:00"), "{}", from.iso);
        assert!(to.iso.starts_with("2026-09-02T00:00:00"), "{}", to.iso);
    }

    #[test]
    fn bounds_accept_iso_and_epoch_ms() {
        let iso = parse_bound("2026-01-01T00:00:00+00:00", false).unwrap();
        assert_eq!(iso.ms, 1_767_225_600_000);
        // ISO отдаётся как есть — зона пользователя не переписывается.
        assert_eq!(iso.iso, "2026-01-01T00:00:00+00:00");

        let ms = parse_bound("1767225600000", true).unwrap();
        assert_eq!(ms.ms, 1_767_225_600_000);
        assert!(!ms.iso.is_empty());
    }

    #[test]
    fn bounds_reject_garbage() {
        for bad in ["", "вчера", "2026-13-45", "2026/09/01"] {
            assert!(
                parse_bound(bad, false).is_err(),
                "{bad:?} должен отвергаться"
            );
        }
    }

    #[test]
    fn today_is_a_full_local_day() {
        let now = Local::now();
        let (from, to) = today_bounds(now);
        assert!(from <= now && now < to);
        assert_eq!(from.date_naive(), now.date_naive());
        assert_eq!(to.timestamp_millis() - from.timestamp_millis(), 86_400_000);
    }

    #[test]
    fn stats_rendering() {
        let s = RangeStats {
            from: "2026-09-01T00:00:00+03:00".into(),
            to: "2026-09-02T00:00:00+03:00".into(),
            intervals: 3,
            words: 120,
            duration_seconds: 600.0,
            channels: vec![ChannelStats {
                channel_id: "mic".into(),
                intervals: 2,
                words: 100,
                speech_seconds: 300.0,
            }],
        };
        let text = stats_text(&s, &period_label(&s.from, &s.to, None, None));
        assert!(text.contains("Интервалов: 3"), "{text}");
        assert!(text.contains("10.0 мин"), "{text}");
        assert!(text.contains("mic"), "{text}");
        // Обе границы заданы — печатаются как есть.
        assert!(
            text.contains("Период: 2026-09-01T00:00:00+03:00 — 2026-09-02T00:00:00+03:00"),
            "{text}"
        );

        let v: serde_json::Value = serde_json::from_str(&stats_json(&s)).unwrap();
        assert_eq!(v["intervals"], 3);
        assert_eq!(v["channels"][0]["channel_id"], "mic");
        assert_eq!(v["channels"][0]["speech_seconds"], 300.0);
    }

    #[test]
    fn empty_stats_render_without_panic() {
        let s = RangeStats {
            from: String::new(),
            to: String::new(),
            intervals: 0,
            words: 0,
            duration_seconds: 0.0,
            channels: Vec::new(),
        };
        let text = stats_text(&s, &period_label(&s.from, &s.to, None, None));
        assert!(text.contains("Период: всё время (данных нет)"), "{text}");
        assert!(text.contains("речи не записано"), "{text}");
    }

    /// Без `--from/--to` период — «всё время» с фактическими датами из базы.
    #[test]
    fn period_label_without_bounds_uses_data_range() {
        let first = "2026-06-19T09:12:00+03:00";
        let last = "2026-09-03T18:40:00+03:00";

        assert_eq!(
            period_label("", "", Some(first), Some(last)),
            "всё время (с 2026-06-19 по 2026-09-03)"
        );
        // Заданные границы важнее данных и печатаются как есть.
        assert_eq!(
            period_label(
                "2026-09-01T00:00:00+03:00",
                "2026-09-02T00:00:00+03:00",
                Some(first),
                Some(last)
            ),
            "2026-09-01T00:00:00+03:00 — 2026-09-02T00:00:00+03:00"
        );
        // Задана одна граница — вторую подставляем из данных.
        assert_eq!(
            period_label("", "2026-09-02T00:00:00+03:00", Some(first), Some(last)),
            "2026-06-19 — 2026-09-02T00:00:00+03:00"
        );
        assert_eq!(
            period_label("2026-09-01T00:00:00+03:00", "", Some(first), Some(last)),
            "2026-09-01T00:00:00+03:00 — 2026-09-03"
        );
        // Пустая база.
        assert_eq!(period_label("", "", None, None), "всё время (данных нет)");
    }

    /// Заголовок `today` показывает дату: в самих репликах только `[ЧЧ:ММ]`.
    #[test]
    fn today_title_shows_the_date() {
        let day = Local::now();
        let title = today_title(day);
        assert!(
            title.contains(&day.format("%Y-%m-%d").to_string()),
            "{title}"
        );
    }

    /// Выделение совпадения: ANSI — только в терминале, в пайп идут маркеры.
    #[test]
    fn highlight_is_ansi_only_on_a_tty() {
        let snippet = "…обсудили «релиз» Chronica…";
        assert_eq!(highlight(snippet, false), snippet);
        let bold = highlight(snippet, true);
        assert!(bold.contains("\u{1b}[1mрелиз\u{1b}[0m"), "{bold}");
        assert!(!bold.contains('«') && !bold.contains('»'), "{bold}");
    }

    /// JSON-выдача поиска: старые поля интервала + аддитивные `channel_id`/`snippet`.
    #[test]
    fn search_hit_json_keeps_interval_fields_and_adds_snippet() {
        let hit = SearchHit {
            interval: IntervalRecord {
                id: 7,
                start_at: "2026-09-03T10:00:00+03:00".into(),
                end_at: "2026-09-03T10:01:00+03:00".into(),
                duration_s: 60.0,
                channels: vec![transcriber_core::types::ChannelText {
                    channel_id: "mic".into(),
                    text: "обсудили релиз Chronica".into(),
                    words: 3,
                    language: "ru".into(),
                }],
            },
            channel_id: "mic".into(),
            snippet: "обсудили «релиз» Chronica".into(),
        };
        let v = search_hit_json(&hit);
        assert_eq!(v["id"], 7);
        assert_eq!(v["start_at"], "2026-09-03T10:00:00+03:00");
        assert_eq!(v["duration_s"], 60.0);
        // Полный текст остаётся доступен.
        assert_eq!(v["channels"][0]["text"], "обсудили релиз Chronica");
        assert_eq!(v["channel_id"], "mic");
        assert_eq!(v["snippet"], "обсудили «релиз» Chronica");
    }

    /// Таблица сессий: закрытая показывает конец, причину и длительность,
    /// незакрытая помечена понятно и не превращается в «0 с».
    #[test]
    fn sessions_table_marks_unclosed_sessions() {
        let items = vec![
            SessionRecord {
                id: 1,
                started_at: "2026-09-03T10:00:00+03:00".into(),
                ended_at: "2026-09-03T10:42:30+03:00".into(),
                stop_reason: SESSION_STOP_USER.into(),
            },
            SessionRecord {
                id: 2,
                started_at: "2026-09-03T12:00:00+03:00".into(),
                ended_at: String::new(),
                stop_reason: String::new(),
            },
            SessionRecord {
                id: 3,
                started_at: "2026-09-03T13:00:00+03:00".into(),
                ended_at: "2026-09-03T13:00:20+03:00".into(),
                stop_reason: SESSION_STOP_ERROR.into(),
            },
        ];

        let text = sessions_text(&items);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 4, "заголовок + три сессии:\n{text}");
        assert!(lines[0].contains("Начало") && lines[0].contains("Длительность"));

        // Микросекунды ядра в таблицу не попадают, колонки не разъезжаются.
        assert!(lines[1].starts_with("2026-09-03 10:00:00 "), "{}", lines[1]);
        assert!(lines[1].contains("2026-09-03 10:42:30"), "{}", lines[1]);
        assert!(lines[1].contains("пользователь"), "{}", lines[1]);
        assert!(lines[1].trim_end().ends_with("42.5 мин"), "{}", lines[1]);

        assert!(lines[2].contains("не закрыта"), "{}", lines[2]);
        assert!(
            lines[2].trim_end().ends_with('—'),
            "у незакрытой сессии длительности нет: {}",
            lines[2]
        );

        assert!(lines[3].contains("авария"), "{}", lines[3]);
        assert!(lines[3].trim_end().ends_with("20 с"), "{}", lines[3]);

        // Пустая выборка — понятная строка, а не пустой вывод.
        assert!(sessions_text(&[]).contains("не найдено"));
    }

    /// `--json` у `sessions` — форма `/api/v1/sessions` плюс `duration_s`
    /// (null у незакрытой сессии).
    #[test]
    fn sessions_json_shape() {
        let items = vec![
            SessionRecord {
                id: 7,
                started_at: "2026-09-03T10:00:00+03:00".into(),
                ended_at: "2026-09-03T10:01:00+03:00".into(),
                stop_reason: SESSION_STOP_USER.into(),
            },
            SessionRecord {
                id: 8,
                started_at: "2026-09-03T11:00:00+03:00".into(),
                ended_at: String::new(),
                stop_reason: String::new(),
            },
        ];
        let v: serde_json::Value = serde_json::from_str(&sessions_json(&items)).unwrap();
        assert_eq!(v["count"], 2);
        assert_eq!(v["items"][0]["id"], 7);
        assert_eq!(v["items"][0]["stop_reason"], "user");
        assert_eq!(v["items"][0]["duration_s"], 60.0);
        assert_eq!(v["items"][1]["ended_at"], "");
        assert!(v["items"][1]["duration_s"].is_null());
    }

    #[test]
    fn human_bytes_scales() {
        assert_eq!(human_bytes(512), "512 Б");
        assert_eq!(human_bytes(2048), "2.0 КБ");
        assert_eq!(human_bytes(5 * 1024 * 1024), "5.0 МБ");
    }

    #[test]
    fn help_names_the_real_binary_and_lists_commands() {
        // Имя бинаря — часть публичного контракта CLI.
        assert_eq!(BIN, "chronica");
        let h = help_text();
        assert!(h.contains(BIN), "{h}");
        for cmd in [
            "today",
            "transcript",
            "search",
            "stats",
            "export",
            "sessions",
            "db",
        ] {
            assert!(h.contains(cmd), "help должен упоминать {cmd}");
        }
        // Справка обязана называть актуальный путь по умолчанию.
        assert!(
            h.contains("Application Support/Chronica/store/transcriber.sqlite"),
            "{h}"
        );
    }

    /// Папка данных: новая (`Chronica`) в приоритете, унаследованная
    /// (`Transcriber`) — только откат, и он помечается для предупреждения.
    #[test]
    fn app_support_path_prefers_the_new_folder_and_falls_back_to_the_legacy_one() {
        let home = Path::new("/Users/tester");
        let support = home.join("Library/Application Support");
        let current = support.join("Chronica").join(STORE_REL_PATH);
        let legacy = support.join("Transcriber").join(STORE_REL_PATH);

        // Ни одной базы нет — предлагаем новый путь, предупреждать не о чем.
        let (path, is_legacy) = pick_app_support_path(home, STORE_REL_PATH, &|_| false);
        assert_eq!(path, current);
        assert!(!is_legacy);

        // Есть только старая — берём её и сообщаем об этом вызывающему.
        let (path, is_legacy) = pick_app_support_path(home, STORE_REL_PATH, &|p| p == legacy);
        assert_eq!(path, legacy);
        assert!(is_legacy);

        // Есть только новая — она же и выбирается.
        let (path, is_legacy) = pick_app_support_path(home, STORE_REL_PATH, &|p| p == current);
        assert_eq!(path, current);
        assert!(!is_legacy);

        // Есть обе — новая важнее, старую не трогаем.
        let (path, is_legacy) = pick_app_support_path(home, STORE_REL_PATH, &|_| true);
        assert_eq!(path, current);
        assert!(!is_legacy);
    }

    /// Каталог моделей живёт в той же папке данных, что и база.
    #[test]
    fn models_path_shares_the_app_support_folder() {
        let home = Path::new("/Users/tester");
        let (path, _) = pick_app_support_path(home, MODELS_REL_PATH, &|_| false);
        assert_eq!(
            path,
            home.join("Library/Application Support/Chronica/Models")
        );
    }

    /// Вывод в конвейер: обрыв stdout (EPIPE) — штатный тихий выход с кодом 0,
    /// любая другая ошибка записи остаётся ошибкой с ненулевым кодом.
    #[test]
    fn stdout_writer_exits_quietly_only_on_broken_pipe() {
        /// Поток, который всегда падает заданной ошибкой.
        struct Failing(ErrorKind);
        impl Write for Failing {
            fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
                Err(io::Error::new(self.0, "подставная ошибка"))
            }
            fn flush(&mut self) -> io::Result<()> {
                Err(io::Error::new(self.0, "подставная ошибка"))
            }
        }

        // Обычная запись доходит целиком.
        let mut sink: Vec<u8> = Vec::new();
        assert!(write_text(&mut sink, "строка\n").is_ok());
        assert_eq!(sink, "строка\n".as_bytes());
        assert_eq!(exit_code(Ok(())), 0);

        // Читатель закрыл конвейер (`| head`) — молча выходим с кодом 0.
        let mut broken = Failing(ErrorKind::BrokenPipe);
        assert!(matches!(
            write_text(&mut broken, "строка"),
            Err(CliError::BrokenPipe)
        ));
        assert_eq!(exit_code(write_text(&mut broken, "строка")), 0);

        // Прочие сбои записи (нет места, нет прав, отвалившийся том) не
        // должны глотаться: код возврата ненулевой.
        for kind in [
            ErrorKind::PermissionDenied,
            ErrorKind::WriteZero,
            ErrorKind::Other,
        ] {
            let mut failing = Failing(kind);
            assert!(
                matches!(write_text(&mut failing, "строка"), Err(CliError::Failed(_))),
                "{kind:?} должен остаться ошибкой"
            );
            assert_eq!(exit_code(write_text(&mut failing, "строка")), 1, "{kind:?}");
        }
    }

    #[test]
    fn unknown_command_exits_nonzero() {
        let argv: Vec<String> = ["cli", "нетакой"].iter().map(|s| s.to_string()).collect();
        assert_ne!(run(&argv), 0);
    }

    /// Отсутствующая база — понятная ошибка и ненулевой код возврата.
    #[test]
    fn missing_store_is_an_error() {
        let argv: Vec<String> = ["cli", "db", "info", "--store", "/nope/absent.sqlite"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(run(&argv), 1);
    }

    /// Сквозной путь по временной базе: today/transcript/search/stats/export/db.
    #[test]
    fn end_to_end_over_a_temp_database() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cli.sqlite");
        let db = path.to_str().unwrap().to_string();
        {
            let store = Store::open(&db).unwrap();
            let now = Local::now();
            store
                .write_interval(
                    &now.to_rfc3339(),
                    &(now + Duration::seconds(60)).to_rfc3339(),
                    60.0,
                    &[transcriber_core::types::ChannelText {
                        channel_id: "mic".into(),
                        text: "обсудили релиз".into(),
                        words: 2,
                        language: "ru".into(),
                    }],
                )
                .unwrap();
            // Сессия записи: закрытая пользователем + незакрытая («приложение
            // закрылось»), чтобы `sessions` печатал оба случая.
            let closed = store.open_session(&now.to_rfc3339()).unwrap();
            store
                .close_session(
                    closed,
                    &(now + Duration::seconds(120)).to_rfc3339(),
                    SESSION_STOP_USER,
                )
                .unwrap();
            store
                .open_session(&(now + Duration::seconds(180)).to_rfc3339())
                .unwrap();
        }
        let cli = |extra: &[&str]| -> i32 {
            let mut argv: Vec<String> = vec!["cli".into()];
            argv.extend(extra.iter().map(|s| s.to_string()));
            argv.push("--store".into());
            argv.push(db.clone());
            run(&argv)
        };

        assert_eq!(cli(&["today"]), 0);
        assert_eq!(cli(&["today", "--format", "md"]), 0);
        assert_eq!(cli(&["today", "--json"]), 0);
        assert_eq!(cli(&["search", "релиз"]), 0);
        assert_eq!(cli(&["search", "--json", "релиз"]), 0);
        assert_eq!(cli(&["stats"]), 0);
        assert_eq!(cli(&["sessions"]), 0);
        assert_eq!(cli(&["sessions", "--json"]), 0);
        assert_eq!(cli(&["sessions", "--limit", "1"]), 0);
        assert_eq!(cli(&["db", "info"]), 0);
        assert_eq!(cli(&["db", "vacuum"]), 0);
        assert_eq!(cli(&["db", "retention", "--days", "3650"]), 0);

        let today = Local::now().format("%Y-%m-%d").to_string();
        assert_eq!(cli(&["transcript", "--from", &today, "--to", &today]), 0);
        assert_eq!(cli(&["sessions", "--from", &today, "--to", &today]), 0);
        let out = dir.path().join("journal.json");
        assert_eq!(
            cli(&[
                "export",
                "--from",
                &today,
                "--to",
                &today,
                "-o",
                out.to_str().unwrap()
            ]),
            0
        );
        let doc: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&out).unwrap()).unwrap();
        assert_eq!(doc["product"], "Chronica");
        assert_eq!(doc["transcription"]["count"], 1);

        // Плохие аргументы — ненулевой код.
        assert_ne!(cli(&["transcript", "--from", "вчера", "--to", &today]), 0);
        assert_ne!(cli(&["transcript", "--to", &today]), 0);
        assert_ne!(cli(&["db", "retention"]), 0);
        assert_ne!(cli(&["db", "нет"]), 0);
        assert_ne!(cli(&["sessions", "--limit", "много"]), 0);
        assert_ne!(cli(&["sessions", "--from", "вчера"]), 0);
        assert_ne!(
            cli(&["export", "--from", &today, "--to", &today, "--format", "pdf"]),
            0
        );
    }
}
