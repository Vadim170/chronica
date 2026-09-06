//! Error type shared across the core. Maps to `ErrorCode` for the FFI surface.

use crate::types::ErrorCode;

#[cfg_attr(feature = "ffi", derive(uniffi::Error))]
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("config: {0}")]
    Config(String),
    #[error("model load: {0}")]
    ModelLoad(String),
    #[error("model download: {0}")]
    ModelDownload(String),
    #[error("audio: {0}")]
    Audio(String),
    #[error("backend: {0}")]
    Backend(String),
    #[error("store: {0}")]
    Store(String),
    #[error("api: {0}")]
    Api(String),
    #[error("internal: {0}")]
    Internal(String),
}

impl CoreError {
    pub fn code(&self) -> ErrorCode {
        match self {
            CoreError::Config(_) => ErrorCode::Config,
            CoreError::ModelLoad(_) => ErrorCode::ModelLoad,
            CoreError::ModelDownload(_) => ErrorCode::ModelDownload,
            CoreError::Audio(_) => ErrorCode::Audio,
            CoreError::Backend(_) => ErrorCode::Backend,
            CoreError::Store(_) => ErrorCode::Store,
            CoreError::Api(_) => ErrorCode::Api,
            CoreError::Internal(_) => ErrorCode::Internal,
        }
    }
}
