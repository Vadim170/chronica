#!/usr/bin/env bash
# =============================================================================
# sign-notarize.sh — Developer ID signing + Apple notarization для Chronica
# =============================================================================
#
# Подписывает apple/dist/Chronica.app сертификатом «Developer ID Application»
# (Hardened Runtime ON, App Sandbox OFF — см. docs/archive/PRODUCT_PLAN.md), собирает
# DMG, отправляет ЕГО в нотариальную службу Apple, степлит тикет и на DMG, и на
# .app, затем проверяет вердикт Gatekeeper.
#
# Это путь ДИСТРИБУЦИИ. Локальная разработка — Scripts/install-debug.sh
# (ad-hoc `codesign --sign -`); этот скрипт для неё НЕ нужен.
#
# -----------------------------------------------------------------------------
# Что делает (порядок принципиален)
# -----------------------------------------------------------------------------
#   1. Подписывает каждый dylib в Contents/Frameworks «изнутри наружу»
#      (--options runtime --timestamp), затем главный бандл — БЕЗ `--deep`.
#      `--deep` официально deprecated для дистрибуции: он навязывает вложенному
#      коду entitlements главного бинарника и молча пропускает то, что не
#      понимает. Правильный способ — подписывать вложенное отдельно и первым.
#   2. Верифицирует подпись (`--verify --strict --deep` — для ПРОВЕРКИ
#      `--deep` как раз уместен) и вердикт Gatekeeper (`spctl`).
#   3. Собирает DMG (Scripts/make-dmg.sh) из уже подписанного .app.
#   4. Нотаризует DMG (`notarytool submit --wait`), степлит тикет на DMG и на
#      .app: тикет выдаётся по cdhash кода, поэтому одной отправки DMG хватает
#      обоим артефактам.
#
# -----------------------------------------------------------------------------
# Переменные окружения
# -----------------------------------------------------------------------------
#   DEV_ID_APP       ОБЯЗАТЕЛЬНО. «Developer ID Application: Имя (TEAMID)».
#                    Список своих: security find-identity -v -p codesigning
#   TEAM_ID          Apple Developer Team ID (10 символов). Для сообщений и
#                    сверки с идентичностью.
#   NOTARY_KEYCHAIN  Необязательный путь к связке ключей, где лежит профиль
#                    notarytool. Нужен в CI, где профиль кладётся во временную
#                    связку, а не в login.keychain. Пусто = связка по умолчанию.
#   NOTARY_PROFILE   Имя keychain-профиля notarytool (по умолчанию
#                    "chronica-notary"). Создаётся один раз:
#                        xcrun notarytool store-credentials "chronica-notary" \
#                          --apple-id "you@example.com" \
#                          --team-id "TEAMID" \
#                          --password "<app-specific-password>"
#                    (либо --key/--key-id/--issuer для App Store Connect API key)
#   ENTITLEMENTS     Путь к plist с правами. По умолчанию
#                    apple/Resources/Chronica.entitlements. ОБЯЗАТЕЛЕН: без
#                    com.apple.security.device.audio-input под Hardened Runtime
#                    микрофон молча не работает. Скрипт падает, если файла нет.
#   APP              Путь к бандлу (по умолчанию apple/dist/Chronica.app).
#   DMG              Путь к образу. Если не задан — его вычислит make-dmg.sh
#                    (apple/dist/Chronica-<version>.dmg).
#   NOTARIZE_TARGET  dmg (по умолчанию) | app | none.
#                      dmg  — собрать DMG и нотаризовать его (рекомендуется);
#                      app  — нотаризовать zip с .app (без DMG);
#                      none — только подписать и проверить.
#   REQUIRE_SIGNING  1 — падать (exit 1) при отсутствии DEV_ID_APP вместо
#                    мягкого выхода. Выставляется в CI (release.yml), чтобы
#                    релиз без секретов не «прошёл» молча.
#
# Флаги: --dry-run       печатать команды, ничего не выполнять
#        --sign-only     то же, что NOTARIZE_TARGET=none
#        --notarize-only пропустить подпись (.app уже подписан на прошлом шаге)
#                        и сразу нотаризовать/застеплить. Используется в CI,
#                        где подпись, сборка DMG и нотаризация — разные шаги.
#
# Пример:
#     DEV_ID_APP="Developer ID Application: Vadim Makarov (ABCDE12345)" \
#     TEAM_ID="ABCDE12345" \
#     NOTARY_PROFILE="chronica-notary" \
#     ./Scripts/sign-notarize.sh
#
# БЕЗОПАСНОСТЬ: если DEV_ID_APP пуст или остался плейсхолдером, скрипт печатает
# инструкцию и выходит с кодом 0 (REQUIRE_SIGNING=1 → 1), НИЧЕГО не подписывая —
# запуск на машине без ключей безвреден.
# =============================================================================

set -euo pipefail

# --- Конфигурация (переопределяется через env) --------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"

DEV_ID_APP="${DEV_ID_APP:-Developer ID Application: Your Name (TEAMID)}"
TEAM_ID="${TEAM_ID:-TEAMID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-chronica-notary}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
APP="${APP:-$APPLE/dist/Chronica.app}"
DMG="${DMG:-}"
ENTITLEMENTS="${ENTITLEMENTS:-$APPLE/Resources/Chronica.entitlements}"
NOTARIZE_TARGET="${NOTARIZE_TARGET:-dmg}"
REQUIRE_SIGNING="${REQUIRE_SIGNING:-0}"

PLACEHOLDER="Developer ID Application: Your Name (TEAMID)"

DRY_RUN=0
SKIP_SIGN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)       DRY_RUN=1 ;;
        --sign-only)     NOTARIZE_TARGET="none" ;;
        --notarize-only) SKIP_SIGN=1 ;;
        *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# Аргументы notarytool для нестандартной связки ключей (CI).
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi

# --- Хелперы ------------------------------------------------------------------

# run: печатает команду и выполняет её (кроме --dry-run).
run() {
    echo "+ $*"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        "$@"
    fi
}

# --- Предохранитель: без реальной идентичности не подписываем ------------------

if [[ -z "$DEV_ID_APP" || "$DEV_ID_APP" == "$PLACEHOLDER" ]]; then
    cat >&2 <<EOF
==> Developer ID не сконфигурирован (DEV_ID_APP пуст или плейсхолдер).

Скрипт НИЧЕГО не подписывает и не нотаризует, пока вы его не настроите.

Как настроить:
  1. Установите сертификат «Developer ID Application» в связку ключей
     (Apple Developer portal / Xcode → Accounts → Manage Certificates).
  2. Создайте профиль notarytool (один раз):
       xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
         --apple-id "you@example.com" --team-id "<TEAMID>" \\
         --password "<app-specific-password>"
  3. Запустите с вашей идентичностью:
       DEV_ID_APP="Developer ID Application: Your Name (ABCDE12345)" \\
       TEAM_ID="ABCDE12345" \\
       NOTARY_PROFILE="$NOTARY_PROFILE" \\
       $0

Для локальной разработки (без нотаризации) — Scripts/install-debug.sh.
EOF
    if [[ "$REQUIRE_SIGNING" == "1" ]]; then
        echo "REQUIRE_SIGNING=1 → это ошибка (релизная сборка без секретов)." >&2
        exit 1
    fi
    exit 0
fi

# --- Preflight ----------------------------------------------------------------

if [[ ! -d "$APP" ]]; then
    echo "ERROR: app bundle not found: $APP" >&2
    echo "       Соберите его: Scripts/package-app.sh" >&2
    exit 1
fi

# Entitlements обязательны: без com.apple.security.device.audio-input под
# Hardened Runtime микрофон будет молча запрещён.
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "ERROR: entitlements plist not found: $ENTITLEMENTS" >&2
    echo "       Он обязателен (микрофон под Hardened Runtime)." >&2
    echo "       Переопределяется переменной ENTITLEMENTS." >&2
    exit 1
fi
if ! plutil -lint "$ENTITLEMENTS" >/dev/null; then
    echo "ERROR: entitlements plist is malformed: $ENTITLEMENTS" >&2
    exit 1
fi
# plutil ОДНОГО НЕДОСТАТОЧНО. codesign парсит entitlements парсером AMFI,
# который строже: например, две чёрточки подряд внутри XML-комментария (что
# запрещено стандартом XML) plutil пропускает, а codesign падает с
# «Failed to parse entitlements». Ловим это здесь, а не на середине релиза.
if command -v xmllint >/dev/null 2>&1; then
    if ! xmllint --noout "$ENTITLEMENTS"; then
        echo "ERROR: entitlements is not well-formed XML: $ENTITLEMENTS" >&2
        echo "       Частая причина: '--' внутри XML-комментария." >&2
        exit 1
    fi
fi

case "$NOTARIZE_TARGET" in
    dmg|app|none) ;;
    *) echo "ERROR: NOTARIZE_TARGET must be dmg|app|none (got '$NOTARIZE_TARGET')" >&2; exit 2 ;;
esac

echo "==> Identity     : $DEV_ID_APP"
echo "==> Team ID      : $TEAM_ID"
echo "==> Profile      : $NOTARY_PROFILE"
echo "==> App          : $APP"
echo "==> Entitlements : $ENTITLEMENTS"
echo "==> Notarize     : $NOTARIZE_TARGET"
[[ "$DRY_RUN" -eq 1 ]] && echo "==> MODE         : dry-run (ни одна команда не выполняется)"

FRAMEWORKS="$APP/Contents/Frameworks"

if [[ "$SKIP_SIGN" -eq 1 ]]; then
    echo "==> --notarize-only: подпись пропущена (бандл подписан ранее)."
else

# --- 1a. Вложенные dylib — первыми (inside-out) -------------------------------

# Вложенный код подписывается СВОИМ вызовом codesign и БЕЗ entitlements
# приложения: entitlements принадлежат главному исполняемому файлу. Подпись тем
# же Developer ID даёт совпадение Team ID, поэтому Library Validation проходит
# и com.apple.security.cs.disable-library-validation не нужен.
echo "==> Подпись вложенных dylib в Contents/Frameworks ..."
if [[ -d "$FRAMEWORKS" ]]; then
    found_dylib=0
    while IFS= read -r -d '' dylib; do
        found_dylib=1
        run codesign --force --options runtime --timestamp \
            --sign "$DEV_ID_APP" "$dylib"
    done < <(find "$FRAMEWORKS" -type f -name '*.dylib' -print0)
    if [[ "$found_dylib" -eq 0 ]]; then
        echo "    (dylib не найдены — ядро слинковано статически?)"
    fi
else
    echo "    (директории Contents/Frameworks нет — пропускаем)"
fi

# --- 1b. Главный бандл — БЕЗ --deep -------------------------------------------

echo "==> Подпись главного бандла (hardened runtime, entitlements, без --deep) ..."
run codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEV_ID_APP" "$APP"

# --- 2. Верификация подписи ---------------------------------------------------

echo "==> Верификация подписи ..."
run codesign --verify --strict --deep --verbose=4 "$APP"

echo "==> Фактические entitlements бинарника ..."
run codesign --display --entitlements - "$APP"

echo "==> Оценка Gatekeeper (до нотаризации ожидаемо «rejected»/unnotarized) ..."
if [[ "$DRY_RUN" -eq 0 ]]; then
    spctl --assess --type exec --verbose=4 "$APP" || true
else
    echo "+ spctl --assess --type exec --verbose=4 $APP"
fi

fi  # SKIP_SIGN

if [[ "$NOTARIZE_TARGET" == "none" ]]; then
    echo "==> NOTARIZE_TARGET=none — остановились после подписи."
    exit 0
fi

# --- 3. Нотаризация -----------------------------------------------------------

if [[ "$NOTARIZE_TARGET" == "dmg" ]]; then
    if [[ -z "$DMG" ]]; then
        echo "==> Сборка DMG (make-dmg.sh) ..."
        run env DEV_ID_APP="$DEV_ID_APP" APP="$APP" "$APPLE/Scripts/make-dmg.sh"
        VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$APP/Contents/Info.plist" 2>/dev/null || echo '')"
        DMG="$APPLE/dist/Chronica-$VERSION.dmg"
    fi
    if [[ "$DRY_RUN" -eq 0 && ! -f "$DMG" ]]; then
        echo "ERROR: DMG не найден: $DMG" >&2
        exit 1
    fi

    echo "==> Отправка DMG в нотариальную службу (несколько минут) ..."
    run xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait

    # Тикет привязан к cdhash подписанного кода, поэтому одной отправки DMG
    # достаточно, чтобы застеплить и образ, и приложение внутри/рядом.
    echo "==> Stapler: DMG ..."
    run xcrun stapler staple "$DMG"
    echo "==> Stapler: .app ..."
    run xcrun stapler staple "$APP"

    echo "==> Проверка stapler ..."
    run xcrun stapler validate "$DMG"
    run xcrun stapler validate "$APP"

    echo "==> Gatekeeper: приложение ..."
    run spctl --assess --type exec --verbose=4 "$APP"
    echo "==> Gatekeeper: образ ..."
    run spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

    echo "==> Готово. Подписано, нотаризовано, застеплено:"
    echo "    $APP"
    echo "    $DMG"
else
    ZIP="${APP%.app}.zip"
    echo "==> ZIP для нотаризации: $ZIP"
    run ditto -c -k --keepParent "$APP" "$ZIP"

    echo "==> Отправка в нотариальную службу (несколько минут) ..."
    run xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

    echo "==> Stapler: .app ..."
    run xcrun stapler staple "$APP"
    run xcrun stapler validate "$APP"

    echo "==> Gatekeeper ..."
    run spctl --assess --type exec --verbose=4 "$APP"

    echo "==> Готово. Подписано, нотаризовано, застеплено: $APP"
fi
