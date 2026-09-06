#!/usr/bin/env bash
# Assemble Chronica.app (menu-bar agent) from a release build.
# The Rust core is statically linked into the executable, so the bundle only
# needs the binary + Info.plist. Signing/notarization are separate steps.
#
# Usage: Scripts/package-app.sh   (output: apple/dist/Chronica.app)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"

# 1. Build core (release) + bindings, then the Swift app (release).
"$APPLE/Scripts/build-core.sh" release -c release

BIN="$APPLE/.build/release/Chronica"
if [ ! -f "$BIN" ]; then
    echo "error: release binary not found at $BIN" >&2
    exit 1
fi

APP="$APPLE/dist/Chronica.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Chronica"
cp "$APPLE/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Bundle dynamic deps (sherpa + ONNX Runtime) for the rpath.
mkdir -p "$APP/Contents/Frameworks"
cp -a "$APPLE"/lib/*.dylib "$APP/Contents/Frameworks/" 2>/dev/null || true

# Иконка приложения (Info.plist: CFBundleIconFile = AppIcon).
# Генерируется Scripts/make-icon.sh — в релизе её отсутствие это ошибка.
if [ ! -f "$APPLE/Resources/AppIcon.icns" ]; then
    echo "error: apple/Resources/AppIcon.icns не найден — запустите Scripts/make-icon.sh" >&2
    exit 1
fi
cp "$APPLE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Локализация. Каталог строк едет в ресурсный бандл SwiftPM
# `Chronica_Chronica.bundle` (в нём `{en,ru}.lproj/Localizable.{strings,
# stringsdict}`). Бандл кладём в `Contents/Resources` — штатное место ресурсов,
# именно там его ищет `Bundle.strings` (см. Sources/Chronica/Design/L10n.swift;
# сгенерированный SwiftPM `Bundle.module` смотрит рядом с `Bundle.main.bundleURL`,
# то есть в КОРЕНЬ .app, куда вложенный бандл класть нельзя).
STRINGS_BUNDLE="$APPLE/.build/release/Chronica_Chronica.bundle"
if [ -d "$STRINGS_BUNDLE" ]; then
    cp -a "$STRINGS_BUNDLE" "$APP/Contents/Resources/"
else
    echo "error: $STRINGS_BUNDLE не найден — каталог строк не собран" >&2
    exit 1
fi
# Локализованные строки Info.plist (TCC-диалоги, CFBundleDisplayName,
# копирайт) — рядом, в `Contents/Resources/<lang>.lproj`.
for lproj in "$APPLE"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    mkdir -p "$APP/Contents/Resources/$(basename "$lproj")"
    cp -a "$lproj"/. "$APP/Contents/Resources/$(basename "$lproj")/"
done

# Юридика внутри бандла: собственная лицензия и уведомления о сторонних
# компонентах (ONNX Runtime, sherpa-onnx, whisper.cpp/ggml, Silero VAD,
# Rust-крейты, модели). Требование их лицензий — поставлять текст вместе с
# бинарной дистрибуцией, поэтому файлы кладём в Contents/Resources.
for legal in LICENSE THIRD_PARTY_NOTICES.md; do
    if [ -f "$ROOT/$legal" ]; then
        cp "$ROOT/$legal" "$APP/Contents/Resources/$legal"
    else
        echo "error: $legal не найден в корне репозитория — он обязателен в дистрибуции" >&2
        exit 1
    fi
done

# SwiftPM/Xcode может оставить в исполняемом файле rpath конкретной машины
# (например, путь toolchain Xcode или workspace apple/lib). Удаляем их до
# последующей подписи Developer ID/Ad-hoc и оставляем только рабочие пути
# приложения внутри бандла.
sanitize_bundle_rpaths() {
    local target="$1"
    local rpath
    while IFS= read -r rpath; do
        case "$rpath" in
            /usr/lib/swift|@loader_path|@executable_path/../Frameworks)
                ;;
            *)
                echo "==> removing non-bundle rpath: $rpath"
                install_name_tool -delete_rpath "$rpath" "$target"
                ;;
        esac
    done < <(otool -l "$target" | awk '
        /LC_RPATH/ { in_rpath=1; next }
        in_rpath && $1 == "path" {
            sub(/^[[:space:]]*path[[:space:]]+/, "", $0)
            sub(/[[:space:]]+\(offset [0-9]+\)[[:space:]]*$/, "", $0)
            print
            in_rpath=0
        }
    ')
}

assert_bundle_rpaths() {
    local target="$1"
    local rpath
    local has_framework_rpath=0
    while IFS= read -r rpath; do
        case "$rpath" in
            /usr/lib/swift|@loader_path)
                ;;
            @executable_path/../Frameworks)
                has_framework_rpath=1
                ;;
            *)
                echo "error: unexpected runtime rpath in $target: $rpath" >&2
                return 1
                ;;
        esac
    done < <(otool -l "$target" | awk '
        /LC_RPATH/ { in_rpath=1; next }
        in_rpath && $1 == "path" {
            sub(/^[[:space:]]*path[[:space:]]+/, "", $0)
            sub(/[[:space:]]+\(offset [0-9]+\)[[:space:]]*$/, "", $0)
            print
            in_rpath=0
        }
    ')
    if [ "$has_framework_rpath" -ne 1 ]; then
        echo "error: $target is missing @executable_path/../Frameworks rpath" >&2
        return 1
    fi
}

sanitize_bundle_rpaths "$APP/Contents/MacOS/Chronica"
assert_bundle_rpaths "$APP/Contents/MacOS/Chronica"

echo "==> built $APP"
echo "Next (real distribution):"
echo "  DEV_ID_APP='Developer ID Application: ... (TEAMID)' \\"
echo "  NOTARY_PROFILE='chronica-notary' Scripts/sign-notarize.sh"
echo "    → подпись inside-out + entitlements, DMG, нотаризация, stapler"
echo "Run locally:  open '$APP'   (grant Microphone + Screen/System-Audio permissions)"
