#!/usr/bin/env bash
# =============================================================================
# make-icon.sh — генерация apple/Resources/AppIcon.icns
# =============================================================================
#
# Иконка рисуется кодом (CoreGraphics), а не берётся из графического редактора:
# никаких внешних зависимостей, результат воспроизводим, палитра совпадает с
# apple/Sources/Chronica/Design/Theme.swift.
#
# Использование:
#     apple/Scripts/make-icon.sh              # → apple/Resources/AppIcon.icns
#     OUT=/tmp/My.icns apple/Scripts/make-icon.sh
#
# Переменные окружения:
#     OUT   — путь результата (по умолчанию apple/Resources/AppIcon.icns)
#     KEEP_ICONSET=1 — не удалять промежуточный .iconset (для отладки дизайна)
#
# Требуется: Xcode CLT (swift + iconutil). Сети и сторонних пакетов НЕ нужно.
# Дизайн правится в apple/Scripts/make-icon.swift.
#
# Результат нужно закоммитить (apple/Resources/AppIcon.icns) — это ресурс
# приложения; package-app.sh и install-debug.sh кладут его в Contents/Resources,
# Info.plist ссылается на него ключом CFBundleIconFile = AppIcon.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"
SWIFT_SRC="$APPLE/Scripts/make-icon.swift"
OUT="${OUT:-$APPLE/Resources/AppIcon.icns}"

for tool in swift iconutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: '$tool' not found — install Xcode Command Line Tools" >&2
        exit 1
    fi
done

if [ ! -f "$SWIFT_SRC" ]; then
    echo "error: renderer not found: $SWIFT_SRC" >&2
    exit 1
fi

WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
cleanup() {
    if [ "${KEEP_ICONSET:-0}" = "1" ]; then
        echo "==> iconset kept at: $ICONSET"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

echo "==> rendering iconset (16…512@2x)"
swift "$SWIFT_SRC" "$ICONSET"

echo "==> building icns"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"

echo "==> done: $OUT"
file "$OUT"
