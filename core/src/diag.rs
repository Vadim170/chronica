//! Crash diagnostics: panic hook + stderr capture to a log file. OWNER: core.
//!
//! The background ASR worker (`tc-asr`) can die from a C++ exception thrown deep
//! inside ONNX Runtime / sherpa: it unwinds into Rust and `abort()`s the whole
//! process. The macOS crash report then has NO source frames (the stack already
//! unwound) and the process stderr is normally discarded by launchd — so the
//! real error message (which the C++ runtime prints to stderr before throwing)
//! is lost. This module captures it:
//!   1. a panic hook appends Rust panics (thread, location, message) — fires
//!      even under `panic = "abort"`;
//!   2. the process stderr (fd 2) is redirected into the same log file, so the
//!      C++ runtime's own output survives the abort.
//!
//! Both run exactly once. stderr is only redirected for the packaged app
//! (`feature = "ffi"`) and only when stderr is NOT a terminal, so dev runs
//! (Xcode / CLI) keep their console output untouched.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Once, OnceLock};

static INIT: Once = Once::new();
/// Путь активного лога — чтобы модули ядра могли дописать строку без знания
/// конфигурации. Пока `init` не вызван, [`log`] молча ничего не делает.
static LOG_PATH: OnceLock<PathBuf> = OnceLock::new();

/// Порог ротации `core.log`. Лог пишется вечно (в него же уходит stderr
/// нативного рантайма), поэтому без ротации он неограниченно растёт.
const ROTATE_MAX_BYTES: u64 = 2 * 1024 * 1024;

/// Install diagnostics, writing to `<log_dir>/core.log`. Idempotent.
pub fn init(log_dir: &Path) {
    INIT.call_once(|| {
        let _ = std::fs::create_dir_all(log_dir);
        let log_path = log_dir.join("core.log");

        // Ротация ДО открытия/редиректа: иначе fd 2 останется привязанным к
        // переименованному архиву и новый файл будет пустым.
        rotate_if_oversized(&log_path, ROTATE_MAX_BYTES);
        let _ = LOG_PATH.set(log_path.clone());

        install_panic_hook(log_path.clone());
        #[cfg(feature = "ffi")]
        redirect_stderr(&log_path);

        // Session marker so each launch is easy to find in the log.
        append(
            &log_path,
            &format!(
                "--- core session start {} ---",
                chrono::Local::now().to_rfc3339()
            ),
        );
    });
}

fn append(path: &Path, line: &str) {
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{line}");
    }
}

/// Дописать диагностическую строку в `core.log` (с меткой времени).
///
/// Best-effort: до `init` (например, в юнит-тестах) — no-op. Предназначено для
/// редких сообщений уровня «предупреждение», которым не нужен UI-эвент.
pub fn log(line: &str) {
    if let Some(path) = LOG_PATH.get() {
        append(
            path,
            &format!("[{}] {line}", chrono::Local::now().to_rfc3339()),
        );
    }
}

/// Ротация по размеру: `core.log` → `core.log.1` (архив ровно один).
///
/// Вынесено отдельной функцией, чтобы поведение проверялось тестом без
/// одноразового `init`.
fn rotate_if_oversized(path: &Path, max_bytes: u64) {
    let Ok(meta) = std::fs::metadata(path) else {
        return; // файла ещё нет — ротировать нечего
    };
    if meta.len() <= max_bytes {
        return;
    }
    let archive = path.with_extension(match path.extension().and_then(|e| e.to_str()) {
        Some(ext) => format!("{ext}.1"),
        None => "1".to_string(),
    });
    // rename перезаписывает предыдущий архив — храним ровно одно поколение.
    let _ = std::fs::rename(path, archive);
}

fn install_panic_hook(log_path: PathBuf) {
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current();
        let name = thread.name().unwrap_or("<unnamed>");
        append(
            &log_path,
            &format!(
                "[{}] PANIC on thread '{}': {}",
                chrono::Local::now().to_rfc3339(),
                name,
                info
            ),
        );
        default(info);
    }));
}

/// Redirect fd 2 (stderr) into the log file for the lifetime of the process, so
/// C++ runtime errors printed before an abort are captured. No-op when stderr is
/// a terminal (keep dev console output).
#[cfg(all(feature = "ffi", unix))]
fn redirect_stderr(log_path: &Path) {
    use std::os::unix::io::AsRawFd;
    // Attached to a terminal → dev run; leave the console alone.
    if unsafe { libc::isatty(libc::STDERR_FILENO) } == 1 {
        return;
    }
    if let Ok(file) = OpenOptions::new().create(true).append(true).open(log_path) {
        unsafe {
            libc::dup2(file.as_raw_fd(), libc::STDERR_FILENO);
        }
        // Keep the fd open for the whole process — do not close on drop.
        std::mem::forget(file);
    }
}

#[cfg(all(feature = "ffi", not(unix)))]
fn redirect_stderr(_log_path: &Path) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oversized_log_is_archived_and_new_log_starts_empty() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("core.log");
        std::fs::write(&log, vec![b'x'; 1_000]).unwrap();

        rotate_if_oversized(&log, 100);

        assert!(!log.exists(), "переполненный лог освобождает своё имя");
        let archive = dir.path().join("core.log.1");
        assert_eq!(std::fs::metadata(&archive).unwrap().len(), 1_000);

        // Новые строки идут в свежий core.log, архив не трогается.
        append(&log, "after rotate");
        assert_eq!(std::fs::read_to_string(&log).unwrap(), "after rotate\n");
        assert_eq!(std::fs::metadata(&archive).unwrap().len(), 1_000);
    }

    #[test]
    fn small_log_is_kept_and_only_one_archive_survives() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("core.log");
        std::fs::write(&log, b"small").unwrap();
        std::fs::write(dir.path().join("core.log.1"), b"older archive").unwrap();

        rotate_if_oversized(&log, 100);
        assert_eq!(std::fs::read_to_string(&log).unwrap(), "small");

        // Вторая ротация вытесняет прошлый архив, а не копит поколения.
        std::fs::write(&log, vec![b'y'; 1_000]).unwrap();
        rotate_if_oversized(&log, 100);
        assert_eq!(
            std::fs::metadata(dir.path().join("core.log.1"))
                .unwrap()
                .len(),
            1_000
        );
        assert!(!dir.path().join("core.log.2").exists());
    }

    #[test]
    fn log_before_init_is_a_noop() {
        // Не должно паниковать и не должно ничего создавать.
        log("no destination configured yet");
    }
}
