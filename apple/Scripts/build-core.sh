#!/usr/bin/env bash
# Build the Rust core, generate Swift bindings, place artifacts into the
# SwiftPM package, then build the app. Usage: build-core.sh [debug|release]
set -euo pipefail

# Rust может быть поставлен не только rustup'ом (Homebrew, системный пакет,
# готовый образ CI) — тогда ~/.cargo/env не существует и безусловный `.` ронял
# бы скрипт под `set -e`. Подгружаем окружение rustup только если оно есть, а
# дальше требуем лишь наличие cargo в PATH.
if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo не найден в PATH." >&2
    echo "       Установите Rust (https://rustup.rs) или добавьте cargo в PATH." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/core"
APPLE="$ROOT/apple"
PROFILE="${1:-debug}"

# Минимальная поддерживаемая macOS. Должна совпадать с LSMinimumSystemVersion в
# apple/Resources/Info.plist и с platforms: [.macOS(.v14)] в apple/Package.swift:
# если ядро собрано под более новую цель, .app упадёт на минимально заявленной
# системе (или линкер выдаст «built for newer macOS»). Сверяем автоматически.
MACOS_MIN="${MACOS_MIN:-14.0}"
PLIST_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
    "$APPLE/Resources/Info.plist" 2>/dev/null || echo '')"
if [ -n "$PLIST_MIN" ] && [ "$PLIST_MIN" != "$MACOS_MIN" ]; then
    echo "error: MACOSX_DEPLOYMENT_TARGET ($MACOS_MIN) != LSMinimumSystemVersion ($PLIST_MIN)." >&2
    echo "       Приведите в соответствие Info.plist, Package.swift и этот скрипт." >&2
    exit 1
fi
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
# Прод-сборка приложения ВСЕГДА без mock-asr: собираем ядро с
# `--no-default-features` и явным набором фич. Так Parakeet всегда обслуживает
# реальный sherpa-onnx, а при сбое движок честно отдаёт ошибку, а не молча
# подменяет вывод детерминированным mock'ом (`mock-asr` входит в default крейта
# и раньше протекал в .app).
#
# `store`/`api`/`download` — персист SQLite, локальный HTTP API и загрузчик
# моделей; `sherpa` — реальный Parakeet (ONNX Runtime); `whispercpp` — ggml
# Whisper fast-path (Metal); `ffi` — UniFFI-биндинги.
FEATURES="${FEATURES:-store,api,download,sherpa,whispercpp,ffi}"

echo "==> building core ($PROFILE, --lib, --no-default-features --features $FEATURES)"
cd "$CORE"
# ТОЛЬКО `--lib`. Приложению нужны лишь артефакты библиотеки:
# `libtranscriber_core.a` (линкуется в .app), `libtranscriber_core.dylib`
# (из него uniffi-bindgen читает метаданные) и `.rlib` для сборки
# uniffi-bindgen ниже — все три даёт crate-type = ["lib","staticlib","cdylib"]
# из core/Cargo.toml.
#
# Без `--lib` cargo собирал ещё и `[[bin]] chronica` с этим ML-набором фич:
# CLI получал динамические зависимости на @rpath/libonnxruntime*.dylib и
# @rpath/libsherpa-onnx-c-api.dylib, но БЕЗ LC_RPATH — и `target/*/chronica`
# после каждой сборки приложения падал на старте с «Library not loaded ...
# no LC_RPATH's found». CLI собирается своей командой и без ML:
# `cargo build --release --bin chronica --no-default-features --features store`
# (см. docs/BUILD.md).
# MACOSX_DEPLOYMENT_TARGET экспортирован выше и сверен с Info.plist.
if [ "$PROFILE" = "release" ]; then
    cargo build --release --lib --no-default-features --features "$FEATURES"
    LIBDIR="$CORE/target/release"
else
    cargo build --lib --no-default-features --features "$FEATURES"
    LIBDIR="$CORE/target/debug"
fi

echo "==> generating Swift bindings"
GEN="$(mktemp -d)"
cargo run --features ffi --bin uniffi-bindgen -- \
    generate --library "$LIBDIR/libtranscriber_core.dylib" \
    --language swift --out-dir "$GEN"

echo "==> placing artifacts"
mkdir -p "$APPLE/Sources/transcriber_coreFFI/include" \
         "$APPLE/Sources/TranscriberCore" "$APPLE/lib"
cp "$GEN/transcriber_coreFFI.h"   "$APPLE/Sources/transcriber_coreFFI/include/"
cp "$GEN/transcriber_core.swift"  "$APPLE/Sources/TranscriberCore/"
cp "$LIBDIR/libtranscriber_core.a" "$APPLE/lib/"
rm -rf "$GEN"

# When sherpa is built, bundle the ONNX Runtime + sherpa dylibs next to the
# static lib so the app's rpath (./lib and @executable_path/../Frameworks)
# resolves them.
if [[ "$FEATURES" == *sherpa* ]]; then
    echo "==> copying sherpa/ONNX dylibs"
    cp -a "$LIBDIR"/libonnxruntime*.dylib "$APPLE/lib/" 2>/dev/null || true
    SHERPA_CAPI="$(find "$HOME/Library/Caches/sherpa-rs" -name 'libsherpa-onnx-c-api.dylib' 2>/dev/null | head -1)"
    if [ -n "$SHERPA_CAPI" ]; then
        cp -a "$(dirname "$SHERPA_CAPI")"/*.dylib "$APPLE/lib/" 2>/dev/null || true
    fi
fi

# When whispercpp is built, copy the STATIC whisper.cpp + ggml archives next to
# the core static lib so the app links them by name from ./lib. These are
# linked into the executable (not dylibs) — the metal shader is embedded in
# libggml-metal.a, so nothing extra needs bundling in Contents/Frameworks.
if [[ "$FEATURES" == *whispercpp* ]]; then
    echo "==> copying whisper.cpp/ggml static libs"
    WLIB="$(find "$CORE/target/$PROFILE/build" -path '*whisper-rs-sys*/out/lib' -type d 2>/dev/null | head -1)"
    if [ -n "$WLIB" ]; then
        cp -a "$WLIB"/libwhisper.a "$WLIB"/libggml*.a "$APPLE/lib/"
    else
        echo "WARN: whisper-rs-sys out/lib not found; whispercpp link will fail" >&2
    fi
fi

echo "==> swift build"
cd "$APPLE"
# Ядро без ML-рантаймов (mock-asr, CI/разработка без cmake+ORT) — не линкуем
# sherpa/whisper в Package.swift.
if [[ "$FEATURES" != *sherpa* && "$FEATURES" != *whispercpp* ]]; then
    export TRANSCRIBER_CORE_MOCK=1
    echo "    (TRANSCRIBER_CORE_MOCK=1 — ML runtimes are not linked)"
fi
swift build "${@:2}"
echo "==> done"
