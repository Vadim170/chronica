//! transcriber-core — reusable native engine for dual-source local speech
//! transcription. The platform shell pushes PCM frames; the core handles
//! resampling, VAD, interval cutting, ASR, persistence, metrics and an
//! optional local HTTP API, emitting events back to the shell.
//!
//! Module map (▶ = implemented in this file set, ◇ = filled by module owners):
//!   types, errors, events, config, vad, asr  ▶ contracts (stable)
//!   lang, interval, audio::{resample,ring}    ◇ pure DSP/logic
//!   store, metrics, model_manager, api        ◇ services
//!   pipeline + TranscriberCore facade         ▶ integration (this crate)

pub mod asr;
pub mod config;
pub mod diag;
pub mod errors;
pub mod events;
pub mod types;
pub mod vad;
#[cfg(feature = "sherpa")]
pub mod vad_silero;

// Filled in by module owners; declared as they land so the contract layer
// compiles on its own with `--no-default-features --features mock-asr`.
#[cfg(feature = "api")]
pub mod api;
pub mod audio;
pub mod interval;
pub mod lang;
pub mod metrics;
#[cfg(feature = "download")]
pub mod model_manager;
pub mod pipeline;
#[cfg(feature = "store")]
pub mod store;

pub use errors::CoreError;
pub use events::{CoreEventListener, EventBus};
pub use pipeline::TranscriberCore;
pub use types::*;

#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();
