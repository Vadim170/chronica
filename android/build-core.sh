#!/usr/bin/env bash
# Build the Rust core for Android: generate the Kotlin UniFFI bindings from a
# host build, then cross-compile the .so for each Android ABI into jniLibs.
#
# REAL ASR (P3): the default features now include `sherpa`, so the cross-built
# core links the ONNX Runtime / sherpa-onnx C-API. sherpa-rs (0.6) ships the
# `download-binaries` feature by default; for an Android target its build.rs
# downloads k2-fsa's prebuilt `sherpa-onnx-<tag>-android.tar.bz2` from GitHub
# (tag v1.12.9) and links `libsherpa-onnx-c-api.so` + `libonnxruntime.so`.
# Those two prebuilt .so are NOT emitted by `cargo ndk -o`, so this script
# also copies them from the cargo target dir into jniLibs alongside the core.
#
# Usage:
#   ./build-core.sh                          # arm64-v8a, features ffi,sherpa
#   ABIS="arm64-v8a x86_64" ./build-core.sh  # add the emulator ABI
#   FEATURES="ffi" ./build-core.sh           # mock-only build (no ORT)
#
# Requirements (install once):
#   cargo install cargo-ndk
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
set -euo pipefail
. "$HOME/.cargo/env"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(cd "$HERE/../core" && pwd)"
APP="$HERE/app"

# NDK 29 (per the task environment). Override ANDROID_NDK_HOME to use another.
: "${ANDROID_NDK_HOME:=$HOME/Library/Android/sdk/ndk/29.0.13599879}"
export ANDROID_NDK_HOME
if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: NDK not found at ANDROID_NDK_HOME=$ANDROID_NDK_HOME" >&2
    exit 1
fi

# Cargo features. `sherpa` pulls the ONNX Runtime ASR backend (real Parakeet);
# it auto-downloads the prebuilt Android ONNX Runtime via sherpa-rs's
# `download-binaries`. Override FEATURES=ffi for a mock-only (ORT-free) build.
FEATURES="${FEATURES:-ffi,sherpa}"
# Which ABIs to cross-compile. arm64-v8a covers all modern physical devices.
# NOTE: the prebuilt ORT tarball only ships arm64-v8a / armeabi-v7a / x86 /
# x86_64; an emulator build needs x86_64 here AND in app/build.gradle.kts.
ABIS="${ABIS:-arm64-v8a}"

# A dedicated target dir keeps this build from clobbering a parallel Mac build.
: "${CARGO_TARGET_DIR:=$CORE/target}"
export CARGO_TARGET_DIR

# Map an Android ABI to its Rust target triple (for locating prebuilt libs).
abi_to_triple() {
    case "$1" in
        arm64-v8a)     echo "aarch64-linux-android" ;;
        armeabi-v7a)   echo "armv7-linux-androideabi" ;;
        x86)           echo "i686-linux-android" ;;
        x86_64)        echo "x86_64-linux-android" ;;
        *) echo "ERROR: unknown ABI $1" >&2; exit 1 ;;
    esac
}

echo "==> [1/4] host build for bindgen (--features $FEATURES)"
cd "$CORE"
cargo build --features "$FEATURES"
HOST_DYLIB="$CARGO_TARGET_DIR/debug/libtranscriber_core.dylib"

echo "==> [2/4] generating Kotlin bindings -> app/src/main/java/uniffi"
# Bindings are deterministic from the library; regenerate every build so they
# never drift from the core's FFI surface.
rm -rf "$APP/src/main/java/uniffi"
cargo run --features "$FEATURES" --bin uniffi-bindgen -- \
    generate --library "$HOST_DYLIB" \
    --language kotlin --out-dir "$APP/src/main/java"

echo "==> [3/4] cross-compiling .so for: $ABIS"
NDK_ARGS=()
for abi in $ABIS; do NDK_ARGS+=( -t "$abi" ); done
cargo ndk "${NDK_ARGS[@]}" -o "$APP/src/main/jniLibs" \
    build --release --features "$FEATURES"

echo "==> [4/4] placing ORT / sherpa-onnx runtime libs (if sherpa enabled)"
for abi in $ABIS; do
    dst="$APP/src/main/jniLibs/$abi"
    # cargo-ndk also copies sherpa-rs's own cdylib artifact (libsherpa_rs-*.so);
    # it is a build by-product, not a runtime dependency. Drop it.
    rm -f "$dst"/libsherpa_rs-*.so 2>/dev/null || true

    if [[ ",$FEATURES," == *",sherpa,"* ]]; then
        triple="$(abi_to_triple "$abi")"
        rel="$CARGO_TARGET_DIR/$triple/release"
        ok=1
        for lib in libsherpa-onnx-c-api.so libonnxruntime.so; do
            if [ -f "$rel/$lib" ]; then
                cp -f "$rel/$lib" "$dst/$lib"
            else
                echo "WARN: $lib not found in $rel (expected from sherpa-rs download-binaries)" >&2
                ok=0
            fi
        done
        if [ "$ok" = 0 ]; then
            echo "WARN: ORT runtime libs missing for $abi — the APK would crash at load." >&2
        fi
    fi
done

echo "==> done. jniLibs:"
find "$APP/src/main/jniLibs" -name '*.so' -exec ls -lh {} \;
