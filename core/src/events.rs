//! Event delivery to the platform shell.
//!
//! The shell registers a single listener; the core fans events out to it from
//! whatever internal thread produced them. The shell is responsible for
//! hopping to its UI thread.

use crate::types::CoreEvent;
use parking_lot::RwLock;
use std::sync::Arc;

/// Implemented by the platform (UniFFI callback interface on Swift/Kotlin).
#[cfg_attr(feature = "ffi", uniffi::export(callback_interface))]
pub trait CoreEventListener: Send + Sync {
    fn on_event(&self, event: CoreEvent);
}

/// Internal fan-out point. Cloneable; thread-safe.
#[derive(Clone, Default)]
pub struct EventBus {
    listener: Arc<RwLock<Option<Box<dyn CoreEventListener>>>>,
}

impl EventBus {
    pub fn new() -> Self {
        Self {
            listener: Arc::new(RwLock::new(None)),
        }
    }

    pub fn set_listener(&self, listener: Box<dyn CoreEventListener>) {
        *self.listener.write() = Some(listener);
    }

    pub fn emit(&self, event: CoreEvent) {
        if let Some(l) = self.listener.read().as_ref() {
            l.on_event(event);
        }
    }
}
