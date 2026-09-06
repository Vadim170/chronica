//! Deterministic mock backend for tests and the ML-free default build.
//! Produces stable, inspectable output without any model files.

use super::{AsrBackend, AsrResult, BackendInit};
use crate::errors::CoreError;
use crate::types::ModelSpec;

pub struct MockBackend {
    multi: bool,
}

impl MockBackend {
    pub fn load(init: &BackendInit) -> Result<Self, CoreError> {
        // Whisper family advertises multi-candidate so engine logic is exercised.
        let multi = matches!(init.model, ModelSpec::Whisper { .. });
        Ok(Self { multi })
    }
}

impl AsrBackend for MockBackend {
    fn transcribe_once(
        &mut self,
        audio_f32_16k: &[f32],
        language: Option<&str>,
    ) -> Result<AsrResult, CoreError> {
        // Emit a deterministic, non-garbage sentence whose word count scales
        // with audio length, so interval/word accounting is testable.
        let secs = (audio_f32_16k.len() as f32 / 16_000.0).max(0.0);
        let words = (secs.round() as usize).clamp(1, 50);
        let token = match language {
            Some("ru") => "привет",
            Some("en") => "hello",
            _ => "mock",
        };
        let text = std::iter::repeat(token)
            .take(words)
            .collect::<Vec<_>>()
            .join(" ");
        Ok(AsrResult {
            text,
            language: language.map(|s| s.to_string()),
            seg_end_rel: Some(secs),
        })
    }

    fn supports_multi_candidate(&self) -> bool {
        self.multi
    }
}
