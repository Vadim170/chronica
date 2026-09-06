#!/usr/bin/env bash
# Версия продукта задаётся в ТРЁХ местах (core/Cargo.toml, apple Info.plist,
# android build.gradle.kts) и обязана совпадать. Скрипт падает при расхождении;
# гоняется в CI и перед релизом.
#
# Дополнительно проверяет CFBundleVersion (build number) в Info.plist: Apple
# требует, чтобы он был ЦЕЛЫМ ЧИСЛОМ (точнее — 1–3 целых через точку) и рос от
# сборки к сборке. Раньше туда клали «0.1.0» — то же, что и маркетинговая
# версия; при апдейтах это ломает сравнение сборок у Gatekeeper/LaunchServices.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/apple/Resources/Info.plist"

plist_get() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null && return 0
    # Linux-раннеры CI не имеют PlistBuddy — читаем plist текстом.
    sed -n "s|.*<key>$1</key>[^<]*<string>\([^<]*\)</string>.*|\1|p" "$PLIST" | head -1
}

cargo_v="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/core/Cargo.toml" | head -1)"
plist_v="$(plist_get CFBundleShortVersionString)"
plist_build="$(plist_get CFBundleVersion)"
gradle_v="$(sed -n 's/.*versionName = "\(.*\)".*/\1/p' "$ROOT/android/app/build.gradle.kts" | head -1)"

echo "core/Cargo.toml            : $cargo_v"
echo "apple Info.plist           : $plist_v (build $plist_build)"
echo "android build.gradle.kts   : $gradle_v"

fail=0

if [ -z "$cargo_v" ] || [ "$cargo_v" != "$plist_v" ] || [ "$cargo_v" != "$gradle_v" ]; then
    echo "FAIL: versions differ (or not found) — align all three before release." >&2
    fail=1
fi

# CFBundleVersion — монотонный build number. Допускаем целое ("1", "42") и
# форму "major.minor.patch" из целых; запрещаем всё прочее.
if [ -z "$plist_build" ]; then
    echo "FAIL: CFBundleVersion not found in $PLIST" >&2
    fail=1
elif ! printf '%s' "$plist_build" | grep -Eq '^[0-9]+$'; then
    echo "FAIL: CFBundleVersion='$plist_build' — ожидается целое число (build number)," >&2
    echo "      например 1, 2, 3 … Маркетинговая версия живёт в CFBundleShortVersionString." >&2
    fail=1
fi

# Частая ошибка: build number скопировали из маркетинговой версии.
if [ -n "$plist_build" ] && [ "$plist_build" = "$plist_v" ]; then
    echo "FAIL: CFBundleVersion совпадает с CFBundleShortVersionString ('$plist_v')." >&2
    echo "      Это разные вещи: build number растёт при каждой публикуемой сборке." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "OK: versions in sync ($cargo_v), build number $plist_build"
