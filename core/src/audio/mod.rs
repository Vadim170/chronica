//! Audio helpers: resampling to the canonical 16kHz mono i16 format, and a
//! lock-free SPSC ring used to move PCM from the realtime capture callback to
//! the DSP thread without blocking.

pub mod resample;
pub mod ring;
