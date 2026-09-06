#!/usr/bin/env bash
# =============================================================================
# make-dmg.sh — сборка образа для распространения Chronica
# =============================================================================
#
# Собирает apple/dist/Chronica-<version>.dmg из уже готового
# apple/dist/Chronica.app: сжатый образ (UDZO) с томом «Chronica», внутри —
# приложение и символическая ссылка на /Applications (классический drag-n-drop).
#
# ПОРЯДОК ШАГОВ ВАЖЕН:
#     package-app.sh  →  sign-notarize.sh (подпись .app)  →  make-dmg.sh
#     →  sign-notarize.sh (нотаризация DMG + stapler)
# Приложение внутри DMG должно быть подписано ДО упаковки: образ read-only,
# переподписать содержимое потом уже нельзя.
# sign-notarize.sh умеет вызвать этот скрипт сам (см. NOTARIZE_TARGET=dmg).
#
# -----------------------------------------------------------------------------
# Переменные окружения
# -----------------------------------------------------------------------------
#   DEV_ID_APP     Идентичность «Developer ID Application: Имя (TEAMID)» для
#                  подписи САМОГО DMG. Если пуста/плейсхолдер — образ соберётся
#                  неподписанным, с предупреждением (годится для локальной
#                  проверки, НЕ годится для раздачи).
#                  Посмотреть свои: security find-identity -v -p codesigning
#   NOTARY_PROFILE Имя keychain-профиля notarytool. Здесь НЕ используется —
#                  нотаризацию делает sign-notarize.sh; указан для симметрии
#                  документации релизных скриптов.
#   APP            Путь к .app (по умолчанию apple/dist/Chronica.app).
#   DMG            Путь к результату (по умолчанию
#                  apple/dist/Chronica-<CFBundleShortVersionString>.dmg).
#   VOLNAME        Имя тома (по умолчанию «Chronica»).
#
# Использование:
#     apple/Scripts/make-dmg.sh
#     DEV_ID_APP="Developer ID Application: Имя (ABCDE12345)" apple/Scripts/make-dmg.sh
#
# Побочный результат: рядом с DMG пишется <dmg>.sha256 (формат `shasum -a 256`),
# он прикладывается к GitHub Release (.github/workflows/release.yml).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"

APP="${APP:-$APPLE/dist/Chronica.app}"
VOLNAME="${VOLNAME:-Chronica}"
DEV_ID_APP="${DEV_ID_APP:-}"
PLACEHOLDER="Developer ID Application: Your Name (TEAMID)"

if [ ! -d "$APP" ]; then
    echo "error: app bundle not found: $APP" >&2
    echo "       build it first: apple/Scripts/package-app.sh" >&2
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    echo "error: cannot read CFBundleShortVersionString from $PLIST" >&2
    exit 1
fi
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo '?')"

DMG="${DMG:-$APPLE/dist/Chronica-$VERSION.dmg}"

echo "==> App     : $APP"
echo "==> Version : $VERSION (build $BUILD)"
echo "==> Output  : $DMG"

# Предупреждаем, если внутрь образа кладётся неподписанное/ad-hoc приложение:
# после упаковки исправить это уже нельзя.
if ! codesign --verify --strict "$APP" >/dev/null 2>&1; then
    echo "WARN: приложение не проходит codesign --verify — DMG соберётся, но раздавать его нельзя." >&2
elif codesign -dv "$APP" 2>&1 | grep -q 'Signature=adhoc'; then
    echo "WARN: приложение подписано ad-hoc (не Developer ID) — Gatekeeper его отклонит." >&2
fi

# --- Стейджинг: .app + ссылка на /Applications -------------------------------

WORK="$(mktemp -d)"
STAGE="$WORK/$VOLNAME"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STAGE"

# ditto, а не cp: сохраняет расширенные атрибуты и не ломает подпись бандла.
echo "==> staging bundle"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
# .DS_Store из стейджинга попал бы в образ — чистим на всякий случай.
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true

# --- Сборка образа ------------------------------------------------------------

echo "==> hdiutil create (UDZO)"
rm -f "$DMG"
mkdir -p "$(dirname "$DMG")"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG" >/dev/null

# --- Подпись образа -----------------------------------------------------------

if [ -z "$DEV_ID_APP" ] || [ "$DEV_ID_APP" = "$PLACEHOLDER" ]; then
    echo "WARN: DEV_ID_APP не задан — DMG остаётся НЕПОДПИСАННЫМ." >&2
    echo "      Для раздачи: DEV_ID_APP='Developer ID Application: ... (TEAMID)' $0" >&2
else
    echo "==> signing DMG as: $DEV_ID_APP"
    codesign --force --timestamp --sign "$DEV_ID_APP" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

# --- Контрольная сумма --------------------------------------------------------

echo "==> sha256"
( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )

echo "==> done: $DMG"
echo "Next: нотаризация и stapler —"
echo "  DEV_ID_APP=... NOTARY_PROFILE=... DMG='$DMG' apple/Scripts/sign-notarize.sh"
