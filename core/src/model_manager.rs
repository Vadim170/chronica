//! Model registry + HuggingFace downloader. OWNER: module agent.
//! Use `ureq` (blocking), `sha2`+`hex` for integrity. Download atomically
//! (tmp file -> rename). Models live under `models_path`.
//!
//! Registry (only whisper + parakeet, per product scope):
//! - Parakeet (sherpa, multilingual incl. ru/en), pulled from k2-fsa / HF as a
//!   set of ONNX files (encoder.int8.onnx, decoder.int8.onnx, joiner.int8.onnx,
//!   tokens.txt). Default id: "parakeet-tdt-0.6b-v3-int8".
//! - Whisper ggml .bin variants from huggingface.co/ggerganov/whisper.cpp
//!   (resolve/main/ggml-<id>.bin), e.g. "large-v3-turbo-q5_0", "small-q5_1",
//!   "base-q5_1", etc. Quantization is part of the id (q5/q8) — no runtime quant.
//!
//! HF URL pattern: https://huggingface.co/<repo>/resolve/main/<file>
//! Provide each entry with: id, label, family, runtime, files[(url, rel_path,
//! sha256, size)], total_bytes.

use std::fs;
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};

use crate::errors::CoreError;
use crate::types::ModelStatus;

/// Attempts per file: first try + retries with exponential backoff.
const DOWNLOAD_ATTEMPTS: u32 = 4;
/// Base retry delay; doubles per attempt (0.5s → 1s → 2s).
const RETRY_BASE_DELAY_MS: u64 = 500;

// ---------------------------------------------------------------------------
// Registry constants
// ---------------------------------------------------------------------------

/// HuggingFace repository hosting the whisper.cpp ggml weights.
const WHISPER_CPP_REPO: &str = "ggerganov/whisper.cpp";

/// HuggingFace repository hosting the sherpa-onnx Parakeet int8 files.
/// Проверено: sha256/размеры файлов ниже сверены с LFS-указателями этого репо
/// и с локально установленной моделью.
const PARAKEET_REPO: &str = "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8";

/// HuggingFace repository с весами Silero VAD (тот же оннх, что бандлит sherpa).
const SILERO_VAD_REPO: &str = "csukuangfj/vad";

/// Идентификатор записи Silero VAD в реестре. Служебная модель: в UI-списке её
/// нет, но она нужна, чтобы VAD был не «энергетическим», а нормальным.
pub const SILERO_VAD_ID: &str = "silero-vad";

/// Семейство служебных (не-ASR) моделей, скрытых из UI-списка.
const VAD_FAMILY: &str = "vad";

/// Таймаут запроса для мелких служебных файлов (VAD ~1.8 МБ). Для весов ASR
/// таймаут не ставим: они качаются минутами и легально.
const SMALL_FILE_TIMEOUT_S: u64 = 120;

/// Реестр whisper-весов: `(id, sha256, размер в байтах)`.
///
/// Квантование — часть id (`-q5_1`, `-q8_0`). Метаданные взяты из дерева
/// репозитория `ggerganov/whisper.cpp` (HF API `/tree/main`: `size` файла и
/// `lfs.oid` = sha256 git-lfs), поэтому у КАЖДОЙ записи известен точный размер
/// (UI показывает его до скачивания) и digest (целостность проверяется после
/// загрузки). Список ровно совпадает с набором файлов `ggml-<id>.bin` в репо:
/// «мёртвых» id в реестре нет.
const WHISPER_CPP_MODELS: &[(&str, &str, u64)] = &[
    (
        "base",
        "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        147_951_465,
    ),
    (
        "base-q5_1",
        "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
        59_707_625,
    ),
    (
        "base-q8_0",
        "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9",
        81_768_585,
    ),
    (
        "base.en",
        "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        147_964_211,
    ),
    (
        "base.en-q5_1",
        "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
        59_721_011,
    ),
    (
        "base.en-q8_0",
        "a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e",
        81_781_811,
    ),
    (
        "large-v1",
        "7d99f41a10525d0206bddadd86760181fa920438b6b33237e3118ff6c83bb53d",
        3_094_623_691,
    ),
    (
        "large-v2",
        "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487",
        3_094_623_691,
    ),
    (
        "large-v2-q5_0",
        "3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2",
        1_080_732_091,
    ),
    (
        "large-v2-q8_0",
        "fef54e6d898246a65c8285bfa83bd1807e27fadf54d5d4e81754c47634737e8c",
        1_656_129_691,
    ),
    (
        "large-v3",
        "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        3_095_033_483,
    ),
    (
        "large-v3-q5_0",
        "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
        1_081_140_203,
    ),
    (
        "large-v3-turbo",
        "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        1_624_555_275,
    ),
    (
        "large-v3-turbo-q5_0",
        "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        574_041_195,
    ),
    (
        "large-v3-turbo-q8_0",
        "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
        874_188_075,
    ),
    (
        "medium",
        "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
        1_533_763_059,
    ),
    (
        "medium-q5_0",
        "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
        539_212_467,
    ),
    (
        "medium-q8_0",
        "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502",
        823_369_779,
    ),
    (
        "medium.en",
        "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356",
        1_533_774_781,
    ),
    (
        "medium.en-q5_0",
        "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0",
        539_225_533,
    ),
    (
        "medium.en-q8_0",
        "43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c",
        823_382_461,
    ),
    (
        "small",
        "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        487_601_967,
    ),
    (
        "small-q5_1",
        "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
        190_085_487,
    ),
    (
        "small-q8_0",
        "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f",
        264_464_607,
    ),
    (
        "small.en",
        "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        487_614_201,
    ),
    (
        "small.en-q5_1",
        "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
        190_098_681,
    ),
    (
        "small.en-q8_0",
        "67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067",
        264_477_561,
    ),
    (
        "tiny",
        "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
        77_691_713,
    ),
    (
        "tiny-q5_1",
        "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
        32_152_673,
    ),
    (
        "tiny-q8_0",
        "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca",
        43_537_433,
    ),
    (
        "tiny.en",
        "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
        77_704_715,
    ),
    (
        "tiny.en-q5_1",
        "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b",
        32_166_155,
    ),
    (
        "tiny.en-q8_0",
        "5bc2b3860aa151a4c6e7bb095e1fcce7cf12c7b020ca08dcec0c6d018bb7dd94",
        43_550_795,
    ),
];

/// Parakeet (sherpa) default model id.
const PARAKEET_ID: &str = "parakeet-tdt-0.6b-v3-int8";

/// One downloadable file of a model.
#[derive(Clone, Debug)]
struct FileEntry {
    /// Absolute source URL on HuggingFace.
    url: String,
    /// Path relative to the model directory (`<models_path>/<id>/<rel_path>`).
    rel_path: String,
    /// Expected sha256 (lowercase hex). Empty = unknown, integrity not checked.
    sha256: String,
    /// Known size in bytes, or 0 if unknown ahead of time (taken from the
    /// Content-Length header during download instead).
    size: u64,
    /// Таймаут HTTP-запроса в секундах; 0 — без таймаута (большие веса).
    timeout_s: u64,
}

/// A registry entry describing a complete model.
#[derive(Clone, Debug)]
struct ModelEntry {
    id: String,
    label: String,
    family: String,  // "whisper" | "parakeet"
    runtime: String, // "whisper.cpp" | "sherpa"
    files: Vec<FileEntry>,
}

impl ModelEntry {
    /// Sum of known sizes; 0 contributions for files with unknown size.
    fn known_total_bytes(&self) -> u64 {
        self.files.iter().map(|f| f.size).sum()
    }
}

// ---------------------------------------------------------------------------
// Resolved local files for the ASR backend
// ---------------------------------------------------------------------------

/// Resolved local files handed to the ASR backend at load time.
#[derive(Clone, Debug)]
pub struct ModelFiles {
    /// Absolute paths to the model files (semantics per family).
    pub paths: Vec<String>,
    pub tokens: Option<String>,
}

pub struct ModelManager {
    models_path: PathBuf,
    registry: Vec<ModelEntry>,
    /// Base retry delay in ms (overridable in tests to avoid real sleeps).
    retry_base_delay_ms: u64,
}

impl ModelManager {
    pub fn new(models_path: &str) -> Self {
        Self {
            models_path: PathBuf::from(models_path),
            registry: build_registry(),
            retry_base_delay_ms: RETRY_BASE_DELAY_MS,
        }
    }

    #[cfg(test)]
    fn with_registry(models_path: &str, registry: Vec<ModelEntry>) -> Self {
        Self {
            models_path: PathBuf::from(models_path),
            registry,
            retry_base_delay_ms: 1,
        }
    }

    /// All known models with current on-disk status.
    ///
    /// Служебные записи (семейство `vad`) НЕ показываются: пользователь выбирает
    /// движок распознавания, а VAD ставится автоматически вместе с ним.
    /// `status(id)` для них по-прежнему работает.
    pub fn list(&self) -> Vec<ModelStatus> {
        self.registry
            .iter()
            .filter(|e| e.family != VAD_FAMILY)
            .map(|e| self.status_of(e))
            .collect()
    }

    pub fn status(&self, id: &str) -> Result<ModelStatus, CoreError> {
        let entry = self.find(id)?;
        Ok(self.status_of(entry))
    }

    pub fn is_installed(&self, id: &str) -> bool {
        match self.find(id) {
            Ok(entry) => self.all_present(entry),
            Err(_) => false,
        }
    }

    /// Download all files for `id` from HF, verifying sha256 where known.
    /// `progress` is invoked with updated status (downloaded_bytes/progress_pct/
    /// downloading). Resilient: files already on disk are skipped, an
    /// interrupted `.part` is resumed via HTTP `Range`, and transient network
    /// failures are retried with exponential backoff.
    pub fn download(&self, id: &str, progress: &dyn Fn(ModelStatus)) -> Result<(), CoreError> {
        self.download_entry(id, progress)?;
        // Вместе с любой ASR-моделью подтягиваем служебный Silero VAD (1.8 МБ):
        // без него движок молча деградирует до энергетического детектора.
        // Сбой не отменяет успешно скачанную ASR-модель.
        if id != SILERO_VAD_ID && !self.is_installed(SILERO_VAD_ID) {
            if let Err(e) = self.download_entry(SILERO_VAD_ID, &|_s| {}) {
                crate::diag::log(&format!("silero vad download skipped: {e}"));
            }
        }
        Ok(())
    }

    /// Догрузить только модель Silero VAD, если её ещё нет.
    ///
    /// Небольшая (1.8 МБ) служебная загрузка: используется при `load_model()`
    /// на уже установленных ASR-моделях, скачанных до появления записи в
    /// реестре. Возвращает Ok, если файл уже на месте.
    pub fn ensure_vad(&self) -> Result<(), CoreError> {
        if self.is_installed(SILERO_VAD_ID) {
            return Ok(());
        }
        self.download_entry(SILERO_VAD_ID, &|_s| {})
    }

    /// Скачать ровно одну запись реестра (без сопутствующих).
    fn download_entry(&self, id: &str, progress: &dyn Fn(ModelStatus)) -> Result<(), CoreError> {
        let entry = self.find(id)?;
        warn_once_on_missing_digests(entry);
        let dir = self.model_dir(id);
        fs::create_dir_all(&dir)
            .map_err(|e| CoreError::ModelDownload(format!("create dir {}: {e}", dir.display())))?;

        // Determine the total size up-front where known; for files of unknown
        // size we patch the total once Content-Length is observed.
        let mut total_bytes = entry.known_total_bytes();
        // Bytes of files already fully published (multi-file models resume
        // file-by-file after an interruption).
        let mut done_bytes: u64 = 0;

        for file in &entry.files {
            let dest = dir.join(&file.rel_path);
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent).map_err(|e| {
                    CoreError::ModelDownload(format!("create dir {}: {e}", parent.display()))
                })?;
            }
            // Already published (e.g. an earlier interrupted run) — skip.
            if dest.is_file() {
                let len = fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);
                if file.size == 0 {
                    total_bytes = total_bytes.saturating_add(len);
                }
                done_bytes = done_bytes.saturating_add(len);
                continue;
            }
            let part = part_path(&dest);

            // Fetch with resume + bounded retries. Transport errors and
            // 429/5xx are transient; other HTTP errors are permanent.
            let mut length_counted = file.size > 0;
            let mut attempt: u32 = 1;
            let file_len = loop {
                match self.fetch_to_part(
                    entry,
                    file,
                    &part,
                    done_bytes,
                    &mut total_bytes,
                    &mut length_counted,
                    progress,
                ) {
                    Ok(len) => break len,
                    Err(FetchError::Permanent(e)) => return Err(e),
                    Err(FetchError::Transient(e)) => {
                        if attempt >= DOWNLOAD_ATTEMPTS {
                            return Err(e);
                        }
                        let delay = self.retry_base_delay_ms << (attempt - 1);
                        std::thread::sleep(std::time::Duration::from_millis(delay));
                        attempt += 1;
                    }
                }
            };

            // Verify integrity when the expected digest is known. Hashing the
            // finished file on disk keeps fresh and resumed downloads uniform.
            if !file.sha256.is_empty() {
                let actual = sha256_of_file(&part)?;
                if actual != file.sha256 {
                    let _ = fs::remove_file(&part);
                    return Err(CoreError::ModelDownload(format!(
                        "sha256 mismatch for {}: expected {}, got {}",
                        file.rel_path, file.sha256, actual
                    )));
                }
            }

            // Atomic publish.
            fs::rename(&part, &dest).map_err(|e| {
                let _ = fs::remove_file(&part);
                CoreError::ModelDownload(format!(
                    "rename {} -> {}: {e}",
                    part.display(),
                    dest.display()
                ))
            })?;
            done_bytes = done_bytes.saturating_add(file_len);
        }

        // Final installed status.
        progress(self.status_of(entry));
        Ok(())
    }

    /// One attempt at fetching `file` into `part`. Resumes from the existing
    /// `.part` bytes via HTTP `Range`; a server that ignores the range (plain
    /// 200) restarts the file from scratch. Returns the final byte length of
    /// the complete `part` file.
    #[allow(clippy::too_many_arguments)]
    fn fetch_to_part(
        &self,
        entry: &ModelEntry,
        file: &FileEntry,
        part: &Path,
        base_done: u64,
        total_bytes: &mut u64,
        length_counted: &mut bool,
        progress: &dyn Fn(ModelStatus),
    ) -> Result<u64, FetchError> {
        let existing = fs::metadata(part).map(|m| m.len()).unwrap_or(0);
        let mut req = ureq::get(&file.url);
        // Таймаут только там, где он осмыслен (мелкие служебные файлы): на
        // многогигабайтных весах общий таймаут запроса рвал бы живую закачку.
        if file.timeout_s > 0 {
            req = req.timeout(std::time::Duration::from_secs(file.timeout_s));
        }
        if existing > 0 {
            req = req.set("Range", &format!("bytes={existing}-"));
        }
        let resp = match req.call() {
            Ok(r) => r,
            // 416 with a non-empty .part: the range starts at EOF, i.e. the
            // part file is already complete — publish it as-is.
            Err(ureq::Error::Status(416, _)) if existing > 0 => return Ok(existing),
            Err(e) => return Err(classify(e, &file.url)),
        };

        let resumed = existing > 0 && resp.status() == 206;
        let content_len: u64 = resp
            .header("Content-Length")
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0);
        // Reconcile total with the server-reported length when ours was 0
        // (exactly once per file; on resume Content-Length is the remainder).
        if !*length_counted && content_len > 0 {
            let full = if resumed {
                existing.saturating_add(content_len)
            } else {
                content_len
            };
            *total_bytes = total_bytes.saturating_add(full);
            *length_counted = true;
        }

        let mut reader = resp.into_reader();
        let (mut out, mut written) = if resumed {
            let f = fs::OpenOptions::new()
                .append(true)
                .open(part)
                .map_err(|e| {
                    FetchError::Permanent(CoreError::ModelDownload(format!(
                        "open {}: {e}",
                        part.display()
                    )))
                })?;
            (f, existing)
        } else {
            let f = fs::File::create(part).map_err(|e| {
                FetchError::Permanent(CoreError::ModelDownload(format!(
                    "create {}: {e}",
                    part.display()
                )))
            })?;
            (f, 0u64)
        };

        let mut buf = [0u8; 64 * 1024];
        let mut last_report = std::time::Instant::now();
        loop {
            // Mid-stream read failures are transient: the bytes written so far
            // stay in `.part` and the next attempt resumes from them.
            let n = reader.read(&mut buf).map_err(|e| {
                FetchError::Transient(CoreError::ModelDownload(format!("read {}: {e}", file.url)))
            })?;
            if n == 0 {
                break;
            }
            out.write_all(&buf[..n]).map_err(|e| {
                FetchError::Permanent(CoreError::ModelDownload(format!(
                    "write {}: {e}",
                    part.display()
                )))
            })?;
            written = written.saturating_add(n as u64);

            // Throttle progress callbacks (~5/s).
            if last_report.elapsed() >= std::time::Duration::from_millis(200) {
                progress(self.progress_status(
                    entry,
                    base_done.saturating_add(written),
                    *total_bytes,
                    true,
                ));
                last_report = std::time::Instant::now();
            }
        }
        out.flush().ok();
        Ok(written)
    }

    pub fn delete(&self, id: &str) -> Result<(), CoreError> {
        // Validate the id is known before touching the filesystem.
        let _ = self.find(id)?;
        let dir = self.model_dir(id);
        if dir.exists() {
            fs::remove_dir_all(&dir)
                .map_err(|e| CoreError::ModelDownload(format!("delete {}: {e}", dir.display())))?;
        }
        Ok(())
    }

    /// Resolve installed files for the ASR backend; errors if not installed.
    pub fn local_files(&self, id: &str) -> Result<ModelFiles, CoreError> {
        let entry = self
            .registry
            .iter()
            .find(|e| e.id == id)
            .ok_or_else(|| CoreError::ModelLoad(format!("unknown model id: {id}")))?;
        if !self.all_present(entry) {
            return Err(CoreError::ModelLoad(format!("model not installed: {id}")));
        }
        let dir = self.model_dir(id);
        let abs = |rel: &str| dir.join(rel).to_string_lossy().into_owned();

        match entry.family.as_str() {
            "whisper" => {
                // Single .bin file -> paths[0], no tokens.
                let rel = &entry.files[0].rel_path;
                Ok(ModelFiles {
                    paths: vec![abs(rel)],
                    tokens: None,
                })
            }
            "parakeet" => {
                // encoder/decoder/joiner in paths (in that order), tokens separate.
                let pick = |needle: &str| -> Option<String> {
                    entry
                        .files
                        .iter()
                        .find(|f| f.rel_path.contains(needle))
                        .map(|f| abs(&f.rel_path))
                };
                let mut paths = Vec::new();
                for needle in ["encoder", "decoder", "joiner"] {
                    let p = pick(needle).ok_or_else(|| {
                        CoreError::ModelLoad(format!("{id}: missing {needle} file"))
                    })?;
                    paths.push(p);
                }
                let tokens = pick("tokens");
                Ok(ModelFiles { paths, tokens })
            }
            other => Err(CoreError::ModelLoad(format!("unknown family: {other}"))),
        }
    }

    // -- internal helpers ----------------------------------------------------

    fn find(&self, id: &str) -> Result<&ModelEntry, CoreError> {
        self.registry
            .iter()
            .find(|e| e.id == id)
            .ok_or_else(|| CoreError::ModelDownload(format!("unknown model id: {id}")))
    }

    fn model_dir(&self, id: &str) -> PathBuf {
        self.models_path.join(id)
    }

    /// True when every file of the model exists on disk.
    fn all_present(&self, entry: &ModelEntry) -> bool {
        let dir = self.model_dir(&entry.id);
        entry.files.iter().all(|f| dir.join(&f.rel_path).is_file())
    }

    /// Sum of on-disk file sizes for the model.
    fn on_disk_bytes(&self, entry: &ModelEntry) -> u64 {
        let dir = self.model_dir(&entry.id);
        entry
            .files
            .iter()
            .filter_map(|f| fs::metadata(dir.join(&f.rel_path)).ok())
            .map(|m| m.len())
            .sum()
    }

    fn status_of(&self, entry: &ModelEntry) -> ModelStatus {
        let installed = self.all_present(entry);
        let downloaded_bytes = self.on_disk_bytes(entry);
        // Prefer the registry total; fall back to on-disk bytes once installed
        // so progress reads 100% for models whose sizes weren't hardcoded.
        let mut total_bytes = entry.known_total_bytes();
        if total_bytes == 0 && installed {
            total_bytes = downloaded_bytes;
        }
        let progress_pct = pct(downloaded_bytes, total_bytes);
        ModelStatus {
            id: entry.id.clone(),
            label: entry.label.clone(),
            family: entry.family.clone(),
            runtime: entry.runtime.clone(),
            installed,
            downloaded_bytes,
            total_bytes,
            progress_pct,
            downloading: false,
            last_error: String::new(),
        }
    }

    fn progress_status(
        &self,
        entry: &ModelEntry,
        downloaded_bytes: u64,
        total_bytes: u64,
        downloading: bool,
    ) -> ModelStatus {
        ModelStatus {
            id: entry.id.clone(),
            label: entry.label.clone(),
            family: entry.family.clone(),
            runtime: entry.runtime.clone(),
            installed: false,
            downloaded_bytes,
            total_bytes,
            progress_pct: pct(downloaded_bytes, total_bytes),
            downloading,
            last_error: String::new(),
        }
    }
}

/// Однократное предупреждение о записях без sha256.
///
/// Пустой digest = проверка целостности файла отключена: битая или обрезанная
/// закачка станет «успешной» и упадёт уже в рантайме ASR. Пишем в core.log один
/// раз за процесс, чтобы это не терялось, но и не спамило.
fn warn_once_on_missing_digests(entry: &ModelEntry) {
    static WARNED: std::sync::Once = std::sync::Once::new();
    let missing: Vec<&str> = entry
        .files
        .iter()
        .filter(|f| f.sha256.is_empty())
        .map(|f| f.rel_path.as_str())
        .collect();
    if missing.is_empty() {
        return;
    }
    WARNED.call_once(|| {
        crate::diag::log(&format!(
            "model {}: sha256 не задан для {} — целостность после загрузки не проверяется",
            entry.id,
            missing.join(", ")
        ));
    });
}

/// Compute a clamped percentage; 0 when total is unknown.
fn pct(done: u64, total: u64) -> f32 {
    if total == 0 {
        0.0
    } else {
        ((done as f64 / total as f64) * 100.0).clamp(0.0, 100.0) as f32
    }
}

/// `<dest>.part` next to the destination, preserving the original extension
/// (`encoder.onnx` → `encoder.onnx.part`).
fn part_path(dest: &Path) -> PathBuf {
    dest.with_extension(format!(
        "{}part",
        dest.extension()
            .and_then(|e| e.to_str())
            .map(|e| format!("{e}."))
            .unwrap_or_default()
    ))
}

/// Download failure classified by whether a retry can help.
enum FetchError {
    /// Network hiccup / server overload — worth retrying (resumes `.part`).
    Transient(CoreError),
    /// Client-side or definitive server answer — retrying is pointless.
    Permanent(CoreError),
}

fn classify(e: ureq::Error, url: &str) -> FetchError {
    let msg = CoreError::ModelDownload(format!("GET {url}: {e}"));
    match &e {
        ureq::Error::Status(code, _) if *code == 429 || *code >= 500 => FetchError::Transient(msg),
        ureq::Error::Status(..) => FetchError::Permanent(msg),
        ureq::Error::Transport(_) => FetchError::Transient(msg),
    }
}

/// Lowercase hex sha256 of a file, streamed (model files are hundreds of MB).
fn sha256_of_file(path: &Path) -> Result<String, CoreError> {
    use sha2::Digest as _;
    let mut f = fs::File::open(path)
        .map_err(|e| CoreError::ModelDownload(format!("open {}: {e}", path.display())))?;
    let mut hasher = sha2::Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = f
            .read(&mut buf)
            .map_err(|e| CoreError::ModelDownload(format!("read {}: {e}", path.display())))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

// ---------------------------------------------------------------------------
// Registry construction
// ---------------------------------------------------------------------------

fn hf_url(repo: &str, file: &str) -> String {
    format!("https://huggingface.co/{repo}/resolve/main/{file}")
}

/// Файлы Parakeet: `(имя, sha256, размер)`. sha256 взяты из LFS-указателей
/// репозитория и сверены с установленной локально моделью; `tokens.txt` —
/// обычный (не LFS) файл, хэш посчитан по содержимому из репозитория.
const PARAKEET_FILES: &[(&str, &str, u64)] = &[
    (
        "encoder.int8.onnx",
        "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247",
        652_184_281,
    ),
    (
        "decoder.int8.onnx",
        "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e",
        11_845_275,
    ),
    (
        "joiner.int8.onnx",
        "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3",
        6_355_277,
    ),
    (
        "tokens.txt",
        "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
        93_939,
    ),
];

/// Веса Silero VAD: sha256/размер из LFS-указателя `csukuangfj/vad`. MIT.
const SILERO_VAD_SHA256: &str = "a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28";
const SILERO_VAD_SIZE: u64 = 1_807_522;

fn build_registry() -> Vec<ModelEntry> {
    let mut models = Vec::with_capacity(WHISPER_CPP_MODELS.len() + 2);

    // Whisper ggml .bin entries — one file each, с известным размером и sha256:
    // размер показывается в UI до скачивания, digest проверяется после.
    for (id, sha256, size) in WHISPER_CPP_MODELS {
        let file = format!("ggml-{id}.bin");
        models.push(ModelEntry {
            id: (*id).to_string(),
            label: format!("Whisper {id}"),
            family: "whisper".to_string(),
            runtime: "whisper.cpp".to_string(),
            files: vec![FileEntry {
                url: hf_url(WHISPER_CPP_REPO, &file),
                rel_path: file,
                sha256: (*sha256).to_string(),
                size: *size,
                timeout_s: 0,
            }],
        });
    }

    // Parakeet (sherpa-onnx int8) — four files from the HF mirror.
    models.push(ModelEntry {
        id: PARAKEET_ID.to_string(),
        label: "Parakeet TDT 0.6b v3 (int8)".to_string(),
        family: "parakeet".to_string(),
        runtime: "sherpa".to_string(),
        files: PARAKEET_FILES
            .iter()
            .map(|(name, sha, size)| FileEntry {
                url: hf_url(PARAKEET_REPO, name),
                rel_path: (*name).to_string(),
                sha256: (*sha).to_string(),
                size: *size,
                timeout_s: 0,
            })
            .collect(),
    });

    // Служебный Silero VAD. Скрыт из `list()`, ставится вместе с любой
    // ASR-моделью; путь — `<models_path>/silero-vad/silero_vad.onnx`.
    models.push(ModelEntry {
        id: SILERO_VAD_ID.to_string(),
        label: "Silero VAD".to_string(),
        family: VAD_FAMILY.to_string(),
        runtime: "sherpa".to_string(),
        files: vec![FileEntry {
            url: hf_url(SILERO_VAD_REPO, crate::vad::SILERO_VAD_FILE),
            rel_path: crate::vad::SILERO_VAD_FILE.to_string(),
            sha256: SILERO_VAD_SHA256.to_string(),
            size: SILERO_VAD_SIZE,
            timeout_s: SMALL_FILE_TIMEOUT_S,
        }],
    });

    models
}

// ---------------------------------------------------------------------------
// Tests (NO network access)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn mgr() -> ModelManager {
        ModelManager::new("/nonexistent/models")
    }

    #[test]
    fn registry_is_non_empty_and_has_defaults() {
        let m = mgr();
        let list = m.list();
        assert!(!list.is_empty(), "registry must not be empty");

        let ids: Vec<&str> = list.iter().map(|s| s.id.as_str()).collect();
        // Mandatory whisper ids.
        for id in [
            "large-v3-turbo-q5_0",
            "small-q5_1",
            "base-q5_1",
            "medium-q5_0",
        ] {
            assert!(ids.contains(&id), "missing whisper id {id}");
        }
        // Parakeet default id.
        assert!(ids.contains(&PARAKEET_ID), "missing parakeet id");

        // Families/runtimes are well-formed.
        let parakeet = list.iter().find(|s| s.id == PARAKEET_ID).unwrap();
        assert_eq!(parakeet.family, "parakeet");
        assert_eq!(parakeet.runtime, "sherpa");
        let whisper = list.iter().find(|s| s.id == "small-q5_1").unwrap();
        assert_eq!(whisper.family, "whisper");
        assert_eq!(whisper.runtime, "whisper.cpp");

        // Список для UI — ровно выбираемые движки распознавания.
        assert_eq!(list.len(), WHISPER_CPP_MODELS.len() + 1);
        // Реестр whisper зеркалит файлы `ggml-<id>.bin` репозитория
        // ggerganov/whisper.cpp (33 штуки на момент сверки) + Parakeet.
        // Число меняется только вместе с осознанной правкой реестра.
        assert_eq!(WHISPER_CPP_MODELS.len(), 33);
        assert_eq!(list.len(), 34);
    }

    /// Служебный VAD не должен появляться в менеджере моделей (пользователю
    /// нечего с ним делать), но адресоваться по id обязан.
    #[test]
    fn vad_entry_is_hidden_from_the_ui_list_but_addressable() {
        let m = mgr();
        let list = m.list();
        assert!(
            list.iter().all(|s| s.family != VAD_FAMILY),
            "служебные записи не показываем в списке моделей"
        );
        assert!(!list.iter().any(|s| s.id == SILERO_VAD_ID));

        let status = m.status(SILERO_VAD_ID).expect("status по id работает");
        assert_eq!(status.family, VAD_FAMILY);
        assert!(!status.installed);
    }

    /// Путь VAD в реестре и путь, по которому его ищет `vad::make_vad`, обязаны
    /// совпадать — иначе скачанная модель «не находится».
    #[test]
    fn vad_registry_path_matches_the_pipeline_lookup() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_str().unwrap();
        let m = ModelManager::new(root);

        let expected = crate::vad::silero_model_path(root);
        fs::create_dir_all(expected.parent().unwrap()).unwrap();
        fs::write(&expected, b"weights").unwrap();

        assert!(
            m.is_installed(SILERO_VAD_ID),
            "менеджер должен видеть файл ровно там, где его ищет пайплайн"
        );
    }

    /// Каждая запись реестра обязана знать размер и sha256 всех своих файлов.
    ///
    /// Размер — то, что UI показывает ДО скачивания (нулевой размер приводил к
    /// липовым «≈1 ГБ» у base/small); пустой sha256 отключает проверку
    /// целостности, и битая закачка становится «успешной», падая уже в ASR.
    /// Исключений быть не должно — ни одного, включая служебный VAD.
    #[test]
    fn every_registry_entry_carries_size_and_integrity_digest() {
        let reg = build_registry();
        assert!(!reg.is_empty());
        for entry in &reg {
            assert!(!entry.files.is_empty(), "{}: нет файлов", entry.id);
            for f in &entry.files {
                assert_eq!(
                    f.sha256.len(),
                    64,
                    "{}/{}: ожидается sha256 (64 hex)",
                    entry.id,
                    f.rel_path
                );
                assert!(
                    f.sha256
                        .bytes()
                        .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()),
                    "{}/{}: sha256 должен быть строчным hex, а не {:?}",
                    entry.id,
                    f.rel_path,
                    f.sha256
                );
                assert!(f.size > 0, "{}/{}: ожидается размер", entry.id, f.rel_path);
            }
            // Итог модели считается из размеров её файлов.
            let expected: u64 = entry.files.iter().map(|f| f.size).sum();
            assert_eq!(entry.known_total_bytes(), expected, "{}", entry.id);
        }
        // Дефолты продукта обязаны быть в реестре.
        for id in [
            PARAKEET_ID,
            crate::config::DEFAULT_WHISPER_ID,
            SILERO_VAD_ID,
        ] {
            assert!(reg.iter().any(|e| e.id == id), "нет записи {id}");
        }
    }

    /// Размер модели виден в UI ДО скачивания (не «0» и не догадка по
    /// Content-Length): `total_bytes` берётся из реестра.
    #[test]
    fn total_bytes_is_known_before_any_download() {
        let m = mgr();
        for s in m.list() {
            assert!(s.total_bytes > 0, "{}: total_bytes == 0", s.id);
            assert_eq!(s.downloaded_bytes, 0);
            assert_eq!(s.progress_pct, 0.0);
        }
        // Мелкая модель не должна «весить как большая»: реестр знает разницу.
        let by = |id: &str| m.status(id).unwrap().total_bytes;
        assert!(by("base-q5_1") < by("small-q5_1"));
        assert!(by("small-q5_1") < by("large-v3-turbo"));
    }

    #[test]
    fn status_for_uninstalled_is_empty() {
        let m = mgr();
        let s = m.status("base-q5_1").unwrap();
        assert!(!s.installed);
        assert!(!s.downloading);
        assert_eq!(s.downloaded_bytes, 0);
        assert_eq!(s.progress_pct, 0.0);
        assert!(!m.is_installed("base-q5_1"));
    }

    #[test]
    fn unknown_id_errors() {
        let m = mgr();
        assert!(m.status("does-not-exist").is_err());
        assert!(!m.is_installed("does-not-exist"));
        assert!(m.local_files("does-not-exist").is_err());
        assert!(m.delete("does-not-exist").is_err());
    }

    #[test]
    fn whisper_local_files_resolve_when_present() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_str().unwrap();
        let m = ModelManager::new(root);

        let id = "base-q5_1";
        // Not installed yet.
        assert!(!m.is_installed(id));
        assert!(m.local_files(id).is_err());

        // Create the fake .bin file.
        let model_dir = dir.path().join(id);
        fs::create_dir_all(&model_dir).unwrap();
        let bin = model_dir.join("ggml-base-q5_1.bin");
        fs::write(&bin, b"0123456789").unwrap();

        assert!(m.is_installed(id));
        let s = m.status(id).unwrap();
        assert!(s.installed);
        assert_eq!(s.downloaded_bytes, 10);
        // Итог — из реестра (точный размер веса), а не из обрезанного файла на
        // диске, поэтому прогресс честно НЕ 100 %.
        assert_eq!(s.total_bytes, 59_707_625);
        assert!(s.progress_pct < 1.0, "{}", s.progress_pct);

        let files = m.local_files(id).unwrap();
        assert_eq!(files.paths.len(), 1);
        assert_eq!(files.paths[0], bin.to_string_lossy());
        assert!(files.tokens.is_none());
    }

    #[test]
    fn parakeet_local_files_resolve_when_present() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_str().unwrap();
        let m = ModelManager::new(root);

        let id = PARAKEET_ID;
        assert!(!m.is_installed(id));

        let model_dir = dir.path().join(id);
        fs::create_dir_all(&model_dir).unwrap();
        for f in [
            "encoder.int8.onnx",
            "decoder.int8.onnx",
            "joiner.int8.onnx",
            "tokens.txt",
        ] {
            fs::write(model_dir.join(f), b"x").unwrap();
        }

        assert!(m.is_installed(id));
        let files = m.local_files(id).unwrap();
        assert_eq!(files.paths.len(), 3, "encoder/decoder/joiner in paths");
        assert!(files.paths[0].ends_with("encoder.int8.onnx"));
        assert!(files.paths[1].ends_with("decoder.int8.onnx"));
        assert!(files.paths[2].ends_with("joiner.int8.onnx"));
        assert_eq!(
            files.tokens.as_deref().map(|t| t.ends_with("tokens.txt")),
            Some(true)
        );
    }

    #[test]
    fn delete_removes_model_dir() {
        let dir = tempfile::tempdir().unwrap();
        let m = ModelManager::new(dir.path().to_str().unwrap());
        let id = "base-q5_1";
        let model_dir = dir.path().join(id);
        fs::create_dir_all(&model_dir).unwrap();
        fs::write(model_dir.join("ggml-base-q5_1.bin"), b"data").unwrap();
        assert!(m.is_installed(id));

        m.delete(id).unwrap();
        assert!(!m.is_installed(id));
        assert!(!model_dir.exists());
        // Deleting again (already gone) is a no-op success.
        assert!(m.delete(id).is_ok());
    }

    // -- downloader behavior against a local HTTP server ---------------------

    /// Minimal one-model registry pointing at a local server.
    fn local_entry(base_url: &str, sha256: &str) -> Vec<ModelEntry> {
        vec![ModelEntry {
            id: "test-model".into(),
            label: "Test model".into(),
            family: "whisper".into(),
            runtime: "whisper.cpp".into(),
            files: vec![FileEntry {
                url: format!("{base_url}/ggml-test.bin"),
                rel_path: "ggml-test.bin".into(),
                sha256: sha256.into(),
                size: 0,
                timeout_s: 0,
            }],
        }]
    }

    /// Реестр из ASR-модели и служебной VAD-записи — обе с локального сервера.
    fn local_entry_with_vad(base_url: &str) -> Vec<ModelEntry> {
        let mut reg = local_entry(base_url, "");
        reg.push(ModelEntry {
            id: SILERO_VAD_ID.into(),
            label: "Silero VAD".into(),
            family: VAD_FAMILY.into(),
            runtime: "sherpa".into(),
            files: vec![FileEntry {
                url: format!("{base_url}/silero_vad.onnx"),
                rel_path: crate::vad::SILERO_VAD_FILE.into(),
                sha256: String::new(),
                size: 0,
                timeout_s: SMALL_FILE_TIMEOUT_S,
            }],
        });
        reg
    }

    /// Local HTTP server: serves `body` with Range support; the first
    /// `fail_first` requests get a 500. Records received Range headers.
    /// Returns (base_url, range_headers_log, served_requests_counter).
    fn spawn_server(
        body: Vec<u8>,
        fail_first: usize,
    ) -> (
        String,
        std::sync::Arc<std::sync::Mutex<Vec<Option<String>>>>,
    ) {
        use std::sync::{Arc, Mutex};
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let base = format!("http://{}", server.server_addr());
        let ranges: Arc<Mutex<Vec<Option<String>>>> = Arc::new(Mutex::new(Vec::new()));
        let ranges_srv = ranges.clone();
        std::thread::spawn(move || {
            let mut served = 0usize;
            for req in server.incoming_requests() {
                let range = req
                    .headers()
                    .iter()
                    .find(|h| h.field.as_str().as_str().eq_ignore_ascii_case("range"))
                    .map(|h| h.value.as_str().to_string());
                ranges_srv.lock().unwrap().push(range.clone());
                served += 1;
                if served <= fail_first {
                    let _ = req.respond(tiny_http::Response::empty(500));
                    continue;
                }
                match range.as_deref().and_then(|r| {
                    r.strip_prefix("bytes=")?
                        .strip_suffix('-')?
                        .parse::<u64>()
                        .ok()
                }) {
                    Some(from) if (from as usize) < body.len() => {
                        let slice = body[from as usize..].to_vec();
                        let resp = tiny_http::Response::from_data(slice).with_status_code(206);
                        let _ = req.respond(resp);
                    }
                    Some(_) => {
                        let _ = req.respond(tiny_http::Response::empty(416));
                    }
                    None => {
                        let _ = req.respond(tiny_http::Response::from_data(body.clone()));
                    }
                }
            }
        });
        (base, ranges)
    }

    fn sha256_hex(data: &[u8]) -> String {
        use sha2::Digest as _;
        hex::encode(sha2::Sha256::digest(data))
    }

    #[test]
    fn download_fetches_verifies_and_publishes() {
        let body = b"model-weights-0123456789".to_vec();
        let (base, _ranges) = spawn_server(body.clone(), 0);
        let dir = tempfile::tempdir().unwrap();
        let m = ModelManager::with_registry(
            dir.path().to_str().unwrap(),
            local_entry(&base, &sha256_hex(&body)),
        );

        m.download("test-model", &|_s| {}).unwrap();
        let published = dir.path().join("test-model/ggml-test.bin");
        assert_eq!(fs::read(&published).unwrap(), body);
        assert!(m.is_installed("test-model"));
    }

    /// Загрузка ASR-модели обязана дотягивать служебный VAD: иначе движок
    /// молча работает на энергетическом детекторе.
    #[test]
    fn downloading_an_asr_model_also_installs_the_vad() {
        let body = b"weights".to_vec();
        let (base, _ranges) = spawn_server(body.clone(), 0);
        let dir = tempfile::tempdir().unwrap();
        let m =
            ModelManager::with_registry(dir.path().to_str().unwrap(), local_entry_with_vad(&base));

        m.download("test-model", &|_s| {}).unwrap();

        assert!(m.is_installed("test-model"));
        assert!(m.is_installed(SILERO_VAD_ID), "VAD ставится вместе с ASR");
        assert!(crate::vad::silero_model_path(dir.path().to_str().unwrap()).is_file());
    }

    #[test]
    fn ensure_vad_is_idempotent_and_needs_no_network_when_present() {
        let body = b"weights".to_vec();
        let (base, ranges) = spawn_server(body, 0);
        let dir = tempfile::tempdir().unwrap();
        let m =
            ModelManager::with_registry(dir.path().to_str().unwrap(), local_entry_with_vad(&base));

        m.ensure_vad().unwrap();
        assert!(m.is_installed(SILERO_VAD_ID));
        let after_first = ranges.lock().unwrap().len();

        m.ensure_vad().unwrap();
        assert_eq!(
            ranges.lock().unwrap().len(),
            after_first,
            "повторный вызов не должен ходить в сеть"
        );
    }

    /// Скачивание самого VAD не должно рекурсивно тянуть само себя.
    #[test]
    fn downloading_the_vad_alone_does_not_recurse() {
        let body = b"weights".to_vec();
        let (base, ranges) = spawn_server(body, 0);
        let dir = tempfile::tempdir().unwrap();
        let m =
            ModelManager::with_registry(dir.path().to_str().unwrap(), local_entry_with_vad(&base));

        m.download(SILERO_VAD_ID, &|_s| {}).unwrap();
        assert_eq!(ranges.lock().unwrap().len(), 1);
    }

    #[test]
    fn download_retries_transient_500_then_succeeds() {
        let body = b"retry-me".to_vec();
        let (base, ranges) = spawn_server(body.clone(), 2); // two 500s, then OK
        let dir = tempfile::tempdir().unwrap();
        let m = ModelManager::with_registry(dir.path().to_str().unwrap(), local_entry(&base, ""));

        m.download("test-model", &|_s| {}).unwrap();
        assert_eq!(
            fs::read(dir.path().join("test-model/ggml-test.bin")).unwrap(),
            body
        );
        assert_eq!(
            ranges.lock().unwrap().len(),
            3,
            "two failed attempts + one success"
        );
    }

    #[test]
    fn download_gives_up_after_persistent_500s() {
        let body = b"never".to_vec();
        let (base, ranges) = spawn_server(body, usize::MAX);
        let dir = tempfile::tempdir().unwrap();
        let m = ModelManager::with_registry(dir.path().to_str().unwrap(), local_entry(&base, ""));

        assert!(m.download("test-model", &|_s| {}).is_err());
        assert_eq!(
            ranges.lock().unwrap().len(),
            DOWNLOAD_ATTEMPTS as usize,
            "bounded attempts, no infinite retry"
        );
    }

    #[test]
    fn error_classification_404_permanent_503_transient() {
        let e = classify(
            ureq::Error::Status(404, ureq::Response::new(404, "Not Found", "").unwrap()),
            "http://x/f",
        );
        assert!(matches!(e, FetchError::Permanent(_)));
        let e = classify(
            ureq::Error::Status(503, ureq::Response::new(503, "Unavailable", "").unwrap()),
            "http://x/f",
        );
        assert!(matches!(e, FetchError::Transient(_)));
    }

    #[test]
    fn download_resumes_existing_part_via_range() {
        let body = b"0123456789ABCDEF-full-file-content".to_vec();
        let (base, ranges) = spawn_server(body.clone(), 0);
        let dir = tempfile::tempdir().unwrap();
        let m = ModelManager::with_registry(
            dir.path().to_str().unwrap(),
            local_entry(&base, &sha256_hex(&body)),
        );

        // Simulate an interrupted earlier download: half the file in `.part`.
        let model_dir = dir.path().join("test-model");
        fs::create_dir_all(&model_dir).unwrap();
        fs::write(model_dir.join("ggml-test.bin.part"), &body[..10]).unwrap();

        m.download("test-model", &|_s| {}).unwrap();
        assert_eq!(fs::read(model_dir.join("ggml-test.bin")).unwrap(), body);
        let log = ranges.lock().unwrap();
        assert_eq!(
            log.as_slice(),
            &[Some("bytes=10-".to_string())],
            "resumed, not restarted"
        );
    }

    #[test]
    fn download_completed_part_publishes_on_416() {
        let body = b"whole-file".to_vec();
        let (base, _ranges) = spawn_server(body.clone(), 0);
        let dir = tempfile::tempdir().unwrap();
        let m = ModelManager::with_registry(dir.path().to_str().unwrap(), local_entry(&base, ""));

        // `.part` already holds the entire file (crash after last byte).
        let model_dir = dir.path().join("test-model");
        fs::create_dir_all(&model_dir).unwrap();
        fs::write(model_dir.join("ggml-test.bin.part"), &body).unwrap();

        m.download("test-model", &|_s| {}).unwrap();
        assert_eq!(fs::read(model_dir.join("ggml-test.bin")).unwrap(), body);
    }

    #[test]
    fn download_skips_files_already_published() {
        let body = b"published".to_vec();
        let (base, ranges) = spawn_server(body.clone(), 0);
        let dir = tempfile::tempdir().unwrap();
        let m = ModelManager::with_registry(dir.path().to_str().unwrap(), local_entry(&base, ""));

        let model_dir = dir.path().join("test-model");
        fs::create_dir_all(&model_dir).unwrap();
        fs::write(model_dir.join("ggml-test.bin"), &body).unwrap();

        m.download("test-model", &|_s| {}).unwrap();
        assert!(
            ranges.lock().unwrap().is_empty(),
            "no network request for a present file"
        );
    }

    #[test]
    fn download_sha256_mismatch_fails_and_cleans_part() {
        let body = b"corrupted-content".to_vec();
        let (base, _ranges) = spawn_server(body, 0);
        let dir = tempfile::tempdir().unwrap();
        let m = ModelManager::with_registry(
            dir.path().to_str().unwrap(),
            local_entry(&base, &sha256_hex(b"expected-different-content")),
        );

        let err = m.download("test-model", &|_s| {}).unwrap_err();
        assert!(format!("{err}").contains("sha256 mismatch"));
        let model_dir = dir.path().join("test-model");
        assert!(!model_dir.join("ggml-test.bin").exists());
        assert!(
            !model_dir.join("ggml-test.bin.part").exists(),
            "bad part removed"
        );
    }

    #[test]
    fn urls_use_hf_resolve_pattern() {
        let reg = build_registry();
        let w = reg.iter().find(|e| e.id == "base-q5_1").unwrap();
        assert_eq!(
            w.files[0].url,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin"
        );
        let p = reg.iter().find(|e| e.id == PARAKEET_ID).unwrap();
        assert!(p.files.iter().all(|f| f.url.starts_with(&format!(
            "https://huggingface.co/{PARAKEET_REPO}/resolve/main/"
        ))));
    }
}
