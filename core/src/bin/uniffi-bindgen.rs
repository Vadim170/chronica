//! UniFFI binding generator entry point. Build with `--features ffi` then:
//!   cargo run --features ffi --bin uniffi-bindgen -- \
//!       generate --library target/debug/libtranscriber_core.dylib \
//!       --language swift --out-dir <dir>

fn main() {
    #[cfg(feature = "ffi")]
    uniffi::uniffi_bindgen_main();
    #[cfg(not(feature = "ffi"))]
    eprintln!("rebuild with --features ffi to use the binding generator");
}
