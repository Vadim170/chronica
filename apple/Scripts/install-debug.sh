#!/usr/bin/env bash
# Build a DEBUG Chronica.app (real sherpa ASR), ad-hoc sign it, and launch
# it on this Mac. For local development only — grant Microphone + System-Audio
# permissions on first run. Distribution uses package-app.sh + Developer ID
# (см. Scripts/sign-notarize.sh, Scripts/make-dmg.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"

# Тот же plist прав, что и в релизе: `codesign --sign -` (ad-hoc) принимает
# --entitlements, поэтому dev-сборка получает com.apple.security.device.
# audio-input ровно так же, как подписанная. Так поведение микрофона в dev и в
# релизе не расходится.
ENTITLEMENTS="${ENTITLEMENTS:-$APPLE/Resources/Chronica.entitlements}"

"$APPLE/Scripts/build-core.sh" debug

BIN="$APPLE/.build/debug/Chronica"
APP="$APPLE/dist/Chronica.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Chronica"
cp "$APPLE/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Bundle the dynamic deps (sherpa + ONNX Runtime); rpath resolves them.
cp -a "$APPLE"/lib/*.dylib "$APP/Contents/Frameworks/" 2>/dev/null || true
# Иконка (CFBundleIconFile=AppIcon). Генерируется Scripts/make-icon.sh.
if [ -f "$APPLE/Resources/AppIcon.icns" ]; then
    cp "$APPLE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "WARN: apple/Resources/AppIcon.icns отсутствует — запустите Scripts/make-icon.sh" >&2
fi

# Локализация. Каталог строк едет в ресурсный бандл SwiftPM
# `Chronica_Chronica.bundle` (в нём `{en,ru}.lproj/Localizable.{strings,
# stringsdict}`). Бандл кладём в `Contents/Resources` — штатное место ресурсов,
# именно там его ищет `Bundle.strings` (см. Sources/Chronica/Design/L10n.swift;
# сгенерированный SwiftPM `Bundle.module` смотрит рядом с `Bundle.main.bundleURL`,
# то есть в КОРЕНЬ .app, куда вложенный бандл класть нельзя).
STRINGS_BUNDLE="$APPLE/.build/debug/Chronica_Chronica.bundle"
if [ -d "$STRINGS_BUNDLE" ]; then
    cp -a "$STRINGS_BUNDLE" "$APP/Contents/Resources/"
else
    echo "WARN: $STRINGS_BUNDLE отсутствует — интерфейс покажет ключи вместо текста" >&2
fi
# Локализованные строки Info.plist (TCC-диалоги, CFBundleDisplayName,
# копирайт) — рядом, в `Contents/Resources/<lang>.lproj`.
for lproj in "$APPLE"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    mkdir -p "$APP/Contents/Resources/$(basename "$lproj")"
    cp -a "$lproj"/. "$APP/Contents/Resources/$(basename "$lproj")/"
done

# SwiftPM/Xcode может оставить в исполняемом файле rpath конкретной машины
# (например, путь toolchain Xcode или workspace apple/lib). На другой машине
# этих путей нет, и dyld/Xprotect может отклонить приложение ещё до main().
# Оставляем только пути, действующие внутри бандла; выполняем до подписи.
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

# Ad-hoc подпись inside-out (как в релизе, без --deep): сначала вложенные
# dylib, затем бандл — с entitlements. `--options runtime` здесь НЕ ставим:
# под Hardened Runtime ad-hoc подпись включает Library Validation, а у ad-hoc
# нет Team ID — совпадения не будет и dyld отвергнет наши dylib. Hardened
# Runtime включается только в релизной подписи Developer ID
# (Scripts/sign-notarize.sh), где Team ID у бандла и dylib общий.
if [ -f "$ENTITLEMENTS" ]; then
    ENT_ARGS=(--entitlements "$ENTITLEMENTS")
else
    echo "WARN: $ENTITLEMENTS не найден — подписываем без entitlements" >&2
    ENT_ARGS=()
fi
while IFS= read -r -d '' dylib; do
    codesign --force --sign - "$dylib"
done < <(find "$APP/Contents/Frameworks" -type f -name '*.dylib' -print0 2>/dev/null)
# ${ARR[@]+"${ARR[@]}"} — безопасное раскрытие пустого массива под `set -u`
# (в bash 3.2, который штатно стоит в macOS, простое "${ARR[@]}" падает).
codesign --force --sign - ${ENT_ARGS[@]+"${ENT_ARGS[@]}"} "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "==> launching $APP"
open "$APP"
