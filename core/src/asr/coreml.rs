//! Apple-only fast path for Parakeet via FluidAudio's CoreML pipeline.
//!
//! Rust cannot call CoreML / Swift directly, so this backend shells out to a
//! prebuilt `fluidaudiocli` (the same tool the legacy Python WebUI drove in
//! `MacOSParakeetBackend`). Each call writes the f32 chunk to a temporary 16kHz
//! mono WAV, runs `fluidaudiocli transcribe <wav> --output-json <json>`, and
//! parses `{ "text", "durationSeconds", "wordTimings": [{ "endTime" }] }`.
//!
//! `load` locates the binary via `TC_FLUIDAUDIO_CLI` (explicit path) or by name
//! on `PATH`. If neither resolves, it returns `Err(CoreError::Backend(..))` so
//! `asr::create_backend` falls through to sherpa / mock. The CoreML model
//! `.mlmodelc` bundles are managed by `fluidaudiocli` itself (downloaded into
//! `~/Library/Application Support/FluidAudio`), so the Rust core does not stage
//! them.

use std::io::Write as _;
use std::path::PathBuf;
use std::process::Command;

use crate::asr::{is_safe_asr_audio, AsrBackend, AsrResult, BackendInit};
use crate::errors::CoreError;

const SAMPLE_RATE: u32 = 16_000;

pub struct CoreMlParakeet {
    /// Absolute path to the `fluidaudiocli` binary.
    binary: PathBuf,
}

impl CoreMlParakeet {
    pub fn load(_init: &BackendInit) -> Result<Self, CoreError> {
        let binary = locate_binary().ok_or_else(|| {
            CoreError::Backend(
                "CoreML fast-path requires fluidaudiocli (set TC_FLUIDAUDIO_CLI or put it on \
                 PATH); the macOS shell normally provides it"
                    .into(),
            )
        })?;
        Ok(Self { binary })
    }
}

impl AsrBackend for CoreMlParakeet {
    fn transcribe_once(
        &mut self,
        audio_f32_16k: &[f32],
        language: Option<&str>,
    ) -> Result<AsrResult, CoreError> {
        // Keep the same backend-wide input contract as sherpa and whisper.cpp.
        // A short/non-finite buffer must not reach the native CLI (or create a
        // misleading tiny WAV); the pipeline normally filters it first, but
        // this guard also protects direct callers.
        if !is_safe_asr_audio(audio_f32_16k) {
            return Ok(AsrResult::default());
        }
        let wav = TempPath::new("wav")?;
        let json = TempPath::new("json")?;
        write_wav_16k_mono(&wav.path, audio_f32_16k)?;

        let output = Command::new(&self.binary)
            .arg("transcribe")
            .arg(&wav.path)
            .arg("--output-json")
            .arg(&json.path)
            .output()
            .map_err(|e| CoreError::Backend(format!("spawn fluidaudiocli: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(CoreError::Backend(format!(
                "fluidaudiocli transcribe failed ({}): {}",
                output.status,
                stderr.trim()
            )));
        }

        let payload = std::fs::read_to_string(&json.path)
            .map_err(|e| CoreError::Backend(format!("read fluidaudio json: {e}")))?;
        let value: serde_json::Value = serde_json::from_str(&payload)
            .map_err(|e| CoreError::Backend(format!("parse fluidaudio json: {e}")))?;

        let text = value
            .get("text")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .trim()
            .to_string();

        // Prefer the max word end time; fall back to durationSeconds.
        let seg_end_rel = value
            .get("wordTimings")
            .and_then(|w| w.as_array())
            .and_then(|arr| {
                arr.iter()
                    .filter_map(|w| w.get("endTime").and_then(|v| v.as_f64()))
                    .fold(None, |acc: Option<f64>, e| {
                        Some(acc.map_or(e, |a| a.max(e)))
                    })
            })
            .or_else(|| value.get("durationSeconds").and_then(|v| v.as_f64()))
            .map(|s| s as f32);

        Ok(AsrResult {
            text,
            language: language.map(|s| s.to_string()),
            seg_end_rel,
        })
    }

    fn supports_multi_candidate(&self) -> bool {
        false
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Find the fluidaudiocli binary: explicit env override first, then PATH.
fn locate_binary() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("TC_FLUIDAUDIO_CLI") {
        let path = PathBuf::from(p);
        if path.is_file() {
            return Some(path);
        }
        return None;
    }
    which_on_path("fluidaudiocli")
}

/// Minimal `which`: scan `$PATH` entries for an executable file.
fn which_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).find_map(|dir| {
        let candidate = dir.join(name);
        candidate.is_file().then_some(candidate)
    })
}

/// A temp file path under the system temp dir, removed on drop.
struct TempPath {
    path: PathBuf,
}

impl TempPath {
    fn new(ext: &str) -> Result<Self, CoreError> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let name = format!("tc-coreml-{}-{nanos}.{ext}", std::process::id());
        Ok(Self {
            path: std::env::temp_dir().join(name),
        })
    }
}

impl Drop for TempPath {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Write mono 16kHz 16-bit PCM WAV from f32 samples (clamped to -1..1).
fn write_wav_16k_mono(path: &std::path::Path, samples: &[f32]) -> Result<(), CoreError> {
    let data_len = (samples.len() * 2) as u32;
    let mut buf: Vec<u8> = Vec::with_capacity(44 + data_len as usize);

    let byte_rate = SAMPLE_RATE * 2; // mono * 16-bit
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes()); // PCM fmt chunk size
    buf.extend_from_slice(&1u16.to_le_bytes()); // PCM
    buf.extend_from_slice(&1u16.to_le_bytes()); // channels
    buf.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&2u16.to_le_bytes()); // block align
    buf.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    for &s in samples {
        let v = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
        buf.extend_from_slice(&v.to_le_bytes());
    }

    let mut f = std::fs::File::create(path)
        .map_err(|e| CoreError::Backend(format!("create temp wav: {e}")))?;
    f.write_all(&buf)
        .map_err(|e| CoreError::Backend(format!("write temp wav: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::asr::MIN_ASR_AUDIO_SAMPLES;

    #[test]
    fn native_input_contract_rejects_short_or_nonfinite_audio() {
        assert!(!is_safe_asr_audio(&vec![0.1; MIN_ASR_AUDIO_SAMPLES - 1]));
        assert!(is_safe_asr_audio(&vec![0.1; MIN_ASR_AUDIO_SAMPLES]));

        let mut non_finite = vec![0.1; MIN_ASR_AUDIO_SAMPLES];
        non_finite[MIN_ASR_AUDIO_SAMPLES / 2] = f32::NAN;
        assert!(!is_safe_asr_audio(&non_finite));
    }
}
