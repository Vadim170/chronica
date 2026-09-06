# Chronica — сборка из исходников

Как собрать ядро и macOS-приложение, как получить подписанный и нотаризованный
DMG, и что делать, когда сборка падает. Общее описание проекта —
[`../README.ru.md`](../README.ru.md).

---

## 1. Пререквизиты

| Что | Версия | Зачем |
|---|---|---|
| macOS | 14.0+ | цель сборки; релиз собирается на Apple Silicon (`arm64`) |
| Rust | ≥ 1.80 | `rust-version` в `core/Cargo.toml`. Подойдёт rustup, Homebrew или системный пакет — скрипты подхватывают `~/.cargo/env`, если он есть, и дальше требуют только `cargo` в `PATH` |
| Xcode | 16+ (Swift 6) | SwiftPM-сборка приложения |
| Xcode CLT | — | `swift`, `iconutil`, `codesign`, `otool`, `install_name_tool` |
| **cmake** | любая свежая | `whisper-rs-sys` собирает нативный whisper.cpp. Без cmake сборка с фичей `whispercpp` падает |
| Сеть | на время сборки | `sherpa-rs` скачивает предсобранные бинарники sherpa-onnx / ONNX Runtime; `cargo` тянет зависимости |

Веса моделей для сборки **не нужны** — их скачивает уже собранное приложение.

---

## 2. Фиче-флаги ядра

Ядро (`core/Cargo.toml`) собирается под разные задачи одним набором флагов:

| Фича | Что даёт |
|---|---|
| `store` | хранилище SQLite (`rusqlite`, bundled) |
| `api` | локальный HTTP-сервер (`tiny_http`); включает `store` |
| `download` | менеджер моделей: загрузка с HF, sha256 |
| `mock-asr` | фиктивный ASR-бэкенд — сборка и тесты без ML-рантаймов |
| `sherpa` | реальный ASR: sherpa-onnx / ONNX Runtime (Parakeet) |
| `whispercpp` | реальный ASR: whisper.cpp через `whisper-rs` (Metal на Apple) |
| `coreml` | опциональный Apple fast-path под тем же трейтом `AsrBackend` |
| `ffi` | биндинги UniFFI для Swift/Kotlin |
| `webrtc-vad` | альтернативный VAD, оставлен для паритета со старым движком |

- **По умолчанию:** `store,api,download,mock-asr` — собирается и тестируется
  без единой тяжёлой зависимости. Это то, что гоняет `cargo test`.
- **Прод-приложение:** `--no-default-features --features
  store,api,download,sherpa,whispercpp,ffi`. Именно этот набор подставляет
  `apple/Scripts/build-core.sh` (переменная `FEATURES`).

---

## 3. Сборка ядра

```bash
cd core

cargo test                                  # дефолтные (mock) фичи
cargo check --features ffi                  # поверхность FFI компилируется
cargo check --no-default-features \
  --features store,api,download,sherpa,whispercpp,ffi   # реальный ASR
```

Для сборки с реальным ASR полезно выставить `MACOSX_DEPLOYMENT_TARGET=14.0` —
`build-core.sh` делает это сам.

### 3.1. CLI `chronica`

CLI — это `[[bin]] chronica` того же крейта. Работа с базой у него **чистое
чтение SQLite**, поэтому штатная сборка идёт **без ML-рантаймов**: только фича
`store`.

```bash
cd core
cargo build --release --bin chronica --no-default-features --features store
# готовый файл: core/target/release/chronica
cp target/release/chronica /usr/local/bin/          # чтобы был в PATH
chronica --help
```

Такой бинарь **самодостаточен**: `otool -L` показывает только системные
библиотеки, ни ONNX Runtime, ни sherpa, ни whisper.cpp рядом не нужны. Именно
это и обещает документация — CLI читает ту же базу и не требует запущенного
приложения.

> **Не собирайте CLI набором фич приложения.** С `sherpa`/`whispercpp` бинарь
> получает динамические зависимости `@rpath/libonnxruntime*.dylib` и
> `@rpath/libsherpa-onnx-c-api.dylib`, но своего `LC_RPATH` у него нет — запуск
> падает с `Library not loaded ... no LC_RPATH's found`. Поэтому
> `apple/Scripts/build-core.sh` собирает ядро только как `--lib` и `chronica`
> не трогает; ML-free сборка CLI проверяется в CI (job «packaging & versions»).

Команда `transcribe` (разовая проверка ASR на WAV) — единственная, которой нужен
ML-рантайм. В штатной сборке её нет в `--help`, а вызов печатает подсказку и
выходит с кодом 2. Нужна она — гоняйте через `cargo run` с реальным движком:

```bash
cargo run --release --features sherpa --bin chronica -- transcribe speech.wav
```

Именно `cargo run`: он подставляет `DYLD_FALLBACK_LIBRARY_PATH` на `target/`, где
лежат dylib sherpa/ORT. Запуск такого бинаря по прямому пути падает — своего
`LC_RPATH` у него нет. И помните, что путь у него общий с ML-free сборкой
(`target/release/chronica`): собранный с `sherpa` бинарь её перезаписывает, так
что копию в `/usr/local/bin` обновляйте только из ML-free сборки.

---

## 4. Сборка приложения

Всё живёт в `apple/Scripts/`. Скрипты вызывают друг друга в правильном порядке,
руками их последовательность повторять не нужно.

### 4.1. `build-core.sh` — ядро, биндинги, линковка, `swift build`

```bash
cd apple
./Scripts/build-core.sh debug       # или: release
swift run Chronica               # запуск dev-сборки из терминала
```

Что он делает: собирает **библиотеку** ядра (`cargo build --lib`) с `FEATURES`
(по умолчанию `store,api,download,sherpa,whispercpp,ffi`), генерирует
Swift-биндинги через `uniffi-bindgen`, раскладывает `.a` и dylib в `apple/lib/`,
сверяет `MACOSX_DEPLOYMENT_TARGET` с `LSMinimumSystemVersion` из `Info.plist` и
запускает `swift build`.

`--lib` здесь принципиален: приложению нужны только артефакты библиотеки, а без
ограничения таргетов cargo пересобирал заодно и `chronica` с ML-фичами — и
ломал CLI (см. 3.1).

Переменные: `FEATURES`, `MACOS_MIN` (по умолчанию `14.0`). Аргументы после
первого прокидываются в `swift build` (`./Scripts/build-core.sh release -c release`).

> Сгенерированные биндинги **не правят руками** — они пересоздаются этим
> скриптом при каждой сборке.

### 4.2. `install-debug.sh` — поставить debug-сборку на свой Mac

```bash
cd apple
pkill -x Chronica || true
./Scripts/install-debug.sh
```

Собирает debug с реальным sherpa, складывает `Chronica.app`, подписывает
**ad-hoc** (`codesign --sign -`) тем же plist прав, что и релиз — чтобы
поведение микрофона в dev и в релизе не расходилось, — и запускает приложение.
Переменная: `ENTITLEMENTS` (по умолчанию `apple/Resources/Chronica.entitlements`).

### 4.3. `package-app.sh` — релизный бандл

```bash
cd apple
./Scripts/package-app.sh            # → apple/dist/Chronica.app
```

Release-сборка ядра и приложения, `Info.plist`, иконка, dylib в
`Contents/Frameworks`, `LICENSE` и `THIRD_PARTY_NOTICES.md` в
`Contents/Resources` (требование лицензий), чистка «машинных» rpath с проверкой,
что в бандле остались только `/usr/lib/swift`, `@loader_path` и
`@executable_path/../Frameworks`.

Иконка обязательна: если `apple/Resources/AppIcon.icns` отсутствует, скрипт
падает. Сгенерировать — `./Scripts/make-icon.sh` (рисуется кодом, сеть не нужна).

### 4.4. `sign-notarize.sh` — подпись Developer ID и нотаризация

```bash
cd apple
DEV_ID_APP="Developer ID Application: Имя (ABCDE12345)" \
TEAM_ID="ABCDE12345" \
NOTARY_PROFILE="chronica-notary" \
./Scripts/sign-notarize.sh
```

Порядок внутри: подпись каждого dylib «изнутри наружу» (`--options runtime
--timestamp`, без `--deep`), затем главный бандл → верификация подписи и
вердикта Gatekeeper → сборка DMG → `notarytool submit --wait` → stapler на DMG и
на `.app`.

Профиль notarytool создаётся один раз:

```bash
xcrun notarytool store-credentials "chronica-notary" \
  --apple-id "you@example.com" --team-id "ABCDE12345" \
  --password "<app-specific-password>"
```

Переменные окружения:

| Переменная | Смысл |
|---|---|
| `DEV_ID_APP` | **обязательна**. `security find-identity -v -p codesigning` покажет доступные |
| `TEAM_ID` | Team ID (10 символов) |
| `NOTARY_PROFILE` | имя keychain-профиля notarytool (по умолчанию `chronica-notary`) |
| `NOTARY_KEYCHAIN` | путь к связке ключей с профилем — нужен в CI |
| `ENTITLEMENTS` | plist прав (по умолчанию `apple/Resources/Chronica.entitlements`) |
| `APP` / `DMG` | пути к бандлу и образу |
| `NOTARIZE_TARGET` | `dmg` (по умолчанию) · `app` · `none` |
| `REQUIRE_SIGNING` | `1` — падать без `DEV_ID_APP` вместо мягкого выхода (так делает CI) |

Флаги: `--dry-run`, `--sign-only`, `--notarize-only`.

Без ключей скрипт печатает инструкцию и выходит с кодом 0, ничего не подписывая —
запуск на машине без сертификатов безвреден.

### 4.5. `make-dmg.sh` — образ для распространения

```bash
apple/Scripts/make-dmg.sh           # → apple/dist/Chronica-<version>.dmg
```

Сжатый образ (UDZO) с томом «Chronica»: приложение и симлинк на `/Applications`.
Переменные: `DEV_ID_APP` (подпись самого образа), `APP`, `DMG`, `VOLNAME`.

**Порядок шагов принципиален** — приложение внутри DMG должно быть подписано
ДО упаковки, образ read-only и переподписать содержимое потом нельзя:

```
package-app.sh → sign-notarize.sh (подпись .app) → make-dmg.sh
               → sign-notarize.sh (нотаризация DMG + stapler)
```

`sign-notarize.sh` умеет вызвать `make-dmg.sh` сам (`NOTARIZE_TARGET=dmg`).

### 4.6. Релиз через CI

`.github/workflows/release.yml` делает всё это по пушу тега `v*` и публикует
GitHub Release с DMG и файлом `.sha256`. Нужны секреты репозитория
(`MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`,
`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`) — их перечень и способ
получения расписаны в шапке самого workflow. Preflight падает с явным списком
недостающих секретов, а `REQUIRE_SIGNING=1` не даёт «зелёному» релизу выйти
неподписанным.

Версия задана в трёх местах (`core/Cargo.toml`, `apple/Resources/Info.plist`,
`android/app/build.gradle.kts`) и обязана совпадать — это проверяет
`scripts/check-versions.sh` (гоняется в CI и перед релизом). `CFBundleVersion` —
целочисленный build number, монотонно растущий.

---

## 5. Локализация (English + Русский)

Интерфейс локализован на английский и русский; язык выбирает система. Строки
живут в **String Catalog** — `apple/Sources/Chronica/Resources/Localizable.xcstrings`
(source language `en`, локализации `en` и `ru`). Базовый язык пакета задан в
`apple/Package.swift` (`defaultLocalization: "en"`), каталог попадает в
ресурсный бандл SwiftPM `Chronica_Chronica.bundle` через
`resources: [.process("Resources")]`.

Доступ из кода — только через хелперы из `apple/Sources/Chronica/Design/L10n.swift`:

```swift
Text(L("popover.start"))                      // без аргументов
Text(L("models.pending.selected", modelName)) // с аргументами
Text(L("metric.records", count))              // с плюрализацией
LApp("vision.prompt.body", context)           // язык ИНТЕРФЕЙСА, а не локали
```

`LApp` нужен там, где текст уезжает наружу (промпт vision-модели журнала
экрана): модель обязана отвечать на языке интерфейса.

### 5.1. Как добавить строку

1. Добавить ключ в `Localizable.xcstrings` — **стабильный семантический**
   (`settings.general.launchAtLogin`), не сам текст. У ключа обязаны быть
   ОБЕ локализации в состоянии `translated`:

   ```json
   "settings.general.launchAtLogin" : {
     "extractionState" : "manual",
     "localizations" : {
       "en" : { "stringUnit" : { "state" : "translated", "value" : "Launch at Login" } },
       "ru" : { "stringUnit" : { "state" : "translated", "value" : "Запускать при входе в систему" } }
     }
   }
   ```

   Для строк с числом («N записей») вместо `stringUnit` — `variations.plural`:
   у `en` формы `one`/`other`, у `ru` — `one`/`few`/`many`/`other`.

2. Пересобрать продукты компиляции каталога. SwiftPM, в отличие от Xcode, НЕ
   компилирует `.xcstrings` сам, поэтому `{en,ru}.lproj/Localizable.{strings,
   stringsdict}` лежат в репозитории рядом с каталогом и обновляются вручную:

   ```bash
   xcrun --sdk macosx xcstringstool compile \
       apple/Sources/Chronica/Resources/Localizable.xcstrings \
       -o apple/Sources/Chronica/Resources
   ```

3. Использовать ключ в коде через `L(...)`/`LApp(...)`.
4. `cd apple && swift test` — `LocalizationCatalogTests` проверит полноту
   каталога, наличие всех русских форм плюрализации, совпадение числа
   подстановок по языкам и то, что скомпилированные `.lproj` не разъехались с
   каталогом (шаг 2 не забыт).

Проверить, что каталог доехал до бандла:

```bash
ls apple/.build/debug/Chronica_Chronica.bundle/*.lproj
# en.lproj/Localizable.strings  en.lproj/Localizable.stringsdict
# ru.lproj/Localizable.strings  ru.lproj/Localizable.stringsdict
```

### 5.2. Как посмотреть другой язык

Приложение следует языку системы. Чтобы прогнать интерфейс на конкретном языке,
не меняя систему:

```bash
# английский
defaults write io.github.vadim170.chronica AppleLanguages -array en
# русский
defaults write io.github.vadim170.chronica AppleLanguages -array ru
# вернуть «как в системе»
defaults delete io.github.vadim170.chronica AppleLanguages
```

После записи приложение нужно перезапустить (`pkill -x Chronica`, затем
запустить снова). Пользователю то же самое доступно из интерфейса ОС:
**Системные настройки → Основные → Язык и регион → Приложения**.

Тем же способом можно прогнать ВСЕ тесты в русской локали (домен — хост
XCTest):

```bash
cd apple && swift build --build-tests
defaults write com.apple.dt.xctest.tool AppleLanguages -array ru
xcrun xctest -XCTest All .build/debug/ChronicaPackageTests.xctest
defaults delete com.apple.dt.xctest.tool AppleLanguages
```

### 5.3. Строки Info.plist

Тексты системных запросов доступа (`NSMicrophoneUsageDescription`,
`NSAudioCaptureUsageDescription`, `NSScreenCaptureUsageDescription`),
`CFBundleDisplayName` и `NSHumanReadableCopyright` локализуются ОТДЕЛЬНО — через
`apple/Resources/{en,ru}.lproj/InfoPlist.strings`. В `Info.plist` остаются
английские значения как дефолт (плюс `CFBundleDevelopmentRegion = en` и
`CFBundleLocalizations = [en, ru]`).

`install-debug.sh` и `package-app.sh` кладут в собранный `.app`:

- `Chronica_Chronica.bundle` → `Contents/Resources/` (там его ищет
  `Bundle.strings`; сгенерированный SwiftPM `Bundle.module` смотрит рядом с
  `Bundle.main.bundleURL`, то есть в корень `.app`, куда вложенный бандл класть
  нельзя — раскладка и подпись этого не любят);
- `Resources/{en,ru}.lproj/InfoPlist.strings` → `Contents/Resources/{en,ru}.lproj/`.

---

## 6. Сборка без ML-рантаймов (mock)

Полезно, когда нет cmake, нет сети для скачивания ONNX Runtime или нужен быстрый
цикл по UI.

```bash
cd apple
FEATURES=store,api,download,mock-asr,ffi ./Scripts/build-core.sh debug
```

`build-core.sh` сам выставит `TRANSCRIBER_CORE_MOCK=1`, если в `FEATURES` нет ни
`sherpa`, ни `whispercpp` — `Package.swift` тогда не линкует ML-библиотеки.
Именно так CI собирает и тестирует приложение.

Ручной вариант (как в `ci.yml`):

```bash
cd core
cargo build --no-default-features --features store,api,download,mock-asr,ffi
mkdir -p ../apple/lib && cp target/debug/libtranscriber_core.a ../apple/lib/
cd ../apple && TRANSCRIBER_CORE_MOCK=1 swift build && TRANSCRIBER_CORE_MOCK=1 swift test
```

> Прод-приложение собирается **без** `mock-asr`: для Parakeet всегда реальный
> движок, при сбое — честная ошибка, а не молчаливая подмена.

---

## 7. Гейты качества

Ровно то, что гоняет CI (`.github/workflows/ci.yml`) — прогоняйте локально
перед PR:

```bash
cd core
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo check --features ffi
cargo build --release --bin chronica --no-default-features --features store
otool -L target/release/chronica | grep -icE 'onnx|sherpa|whisper'   # 0

cd ../apple
swift build
swift test
ls .build/debug/Chronica_Chronica.bundle/*.lproj   # каталог строк доехал
plutil -lint Resources/Info.plist Resources/*/InfoPlist.strings
```

Плюс в CI: `cargo check` полного набора фич реального ASR на macOS, сборка и
тесты приложения против mock-ядра, `bash -n` по всем скриптам, `plutil -lint` и
`xmllint` по plist'ам, проверка entitlements через настоящий `codesign`,
ML-free сборка CLI с проверкой `otool -L` и `scripts/check-versions.sh`.

Поведенческие тесты ядра и приложения гоняются в CI на каждый push.
Тесты, которым нужны веса модели, устройство или нативная библиотека, помечены
`#[ignore]` и в обычный прогон не попадают.

---

## 8. Типичные ошибки

**`Operation not permitted` при чтении файлов репозитория.**
Репозиторий лежит в `~/Documents`, а это защищённый TCC каталог: хост-приложению
(Terminal, iTerm, VS Code) нужен **Full Disk Access** в Системных настройках →
Конфиденциальность и безопасность. Иначе `cargo`/`swift` не прочитают исходники.

**`cmake: command not found` / падение `whisper-rs-sys`.**
Не установлен cmake: `brew install cmake`. Либо соберите без Whisper —
уберите `whispercpp` из `FEATURES` (или используйте mock-сборку, раздел 6).

**`ld: warning: object file ... was built for newer 'macOS' version than being linked`.**
**Безвредно.** Предсобранные бинарники sherpa/ORT собраны под более новую цель,
чем наши `MACOSX_DEPLOYMENT_TARGET=14.0`. На работу это не влияет;
`build-core.sh` дополнительно сверяет цель с `LSMinimumSystemVersion`, чтобы
расхождение не уехало в релиз.

**`error: cargo не найден в PATH`.**
Rust поставлен не rustup'ом, и `~/.cargo/env` нет. Добавьте `cargo` в `PATH`
или поставьте Rust с https://rustup.rs.

**Приложение не запускается после `install-debug.sh`, или XProtect ругается.**
Обычно причина — «машинные» rpath, оставленные SwiftPM. Скрипты чистят их перед
подписью; если правили сборку руками, проверьте:
`otool -l .../Contents/MacOS/Chronica | grep -A2 LC_RPATH` — должны остаться
только `/usr/lib/swift`, `@loader_path` и `@executable_path/../Frameworks`.

**Диалоги TCC не появляются.**
Запросы разрешений показываются только у подписанного приложения (ad-hoc подписи
из `install-debug.sh` достаточно). `swift run Chronica` из терминала — это
процесс без бандла, там микрофон не спросится.

**Сборка встала на скачивании sherpa-onnx / ONNX Runtime.**
`sherpa-rs` тянет предсобранные бинарники с GitHub на этапе `build.rs`. Нужна
сеть; за прокси может потребоваться `HTTPS_PROXY`.

---

## 9. Android (экспериментально)

Публичного релиза Android нет — клиент собирается и гоняет тот же Rust-core
через UniFFI Kotlin, но как продукт не выпускается.

```bash
cd android && ./build-core.sh        # .so (cargo-ndk) + Kotlin-биндинги
./gradlew assembleDebug              # → app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest
```

Нужны Android SDK + NDK и `cargo install cargo-ndk`. Подробности, переменные
(`ABIS`, `FEATURES`) и список требований — в шапке
[`../android/build-core.sh`](../android/build-core.sh) и в
[`../android/README.md`](../android/README.md). В CI Android не собирается.
