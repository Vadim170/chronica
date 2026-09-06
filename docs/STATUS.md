# Implementation status — Transcriber native rewrite

> Living checkpoint. Updated as phases complete. Plan: `docs/archive/PRODUCT_PLAN.md`. Map: `docs/archive/PROJECT_MAP.md`.

- **Popover (`PopoverView.swift`):** метрики CPU/RAM/RTF/лаг/очередь перенесены мелкой серой строкой в самый низ (под кнопкой Старт/Стоп); освободившиеся ~92 pt отданы Live-ленте (`liveFeedMaxHeight` 220→312); высота окна не изменилась (520). Кнопка «Окно» убрана из футера (остались История/Настройки). Статус слушаю/тишина/обрабатываю перенесён в заголовок секции LIVE справа, хвост-строка снизу ленты убрана.

## Repo layout (new product, root is a fresh git repo)
```
/core            Rust engine crate `transcriber-core`  (the reusable core)
/apple           macOS SwiftUI app (menu bar)          (in progress)
/docs            STATUS, archive/{PRODUCT_PLAN, PROJECT_MAP, plan-overview.html}
/transcriber_webui_project   OLD python app — PORTING REFERENCE ONLY (gitignored)
/transcripts     real recording data (kept; gitignored)
```
Toolchains: Rust 1.96 (installed via rustup, `. "$HOME/.cargo/env"`), Swift 6.3 / Xcode 26.5, Apple Silicon.

## DONE — Rust core (`/core`)
Builds clean; **70 tests pass** (`cargo test`). `--features ffi` (UniFFI) compiles.

Contracts (tech-lead authored, stable): `types.rs`, `errors.rs`, `events.rs`, `config.rs`, `asr/mod.rs` (AsrBackend trait), `vad.rs` (Vad trait).
Implemented modules (verified):
- `lang.rs` — clean/garbage/score/pick_best (ported 1:1) — 15 tests
- `audio/resample.rs` — to_mono_16k_i16 (anti-aliased decimation) — 12 tests
- `audio/ring.rs` — lock-free SPSC PCM ring — 2 tests
- `interval.rs` — IntervalCutCoordinator (ported 1:1) — 9 tests
- `store.rs` — SQLite (intervals + voice_events, WAL, overlap query, hourly/daily, retention) — 6 tests
- `metrics.rs` — live metrics — 6 tests
- `model_manager.rs` — registry (34 models) + HF downloader (ureq+sha2) — 7 tests
- `api.rs` — optional tiny_http API (/api/intervals|transcriptions|voice-activity|state, bearer auth) — 7 tests
- `pipeline.rs` — **TranscriberCore facade + DSP thread + ASR worker + ticker** (tech-lead integration) — e2e tested
- `asr/mock.rs` — deterministic backend (default/ML-free build + tests)
- `src/bin/cli.rs` — harness stub

Config defaults (per product reqs): min_interval 30s, max 300s (regulable, clamped 30..300), silence_cut 2000ms, default model Parakeet TDT v3 int8, n_threads 4, api off.

Features: `default = [store, api, download, mock-asr]`; `sherpa`, `coreml`, `ffi`, `webrtc-vad`.

## ✅ VERIFIED ON THIS MAC (2026-06-19)
- **Real transcription works.** Parakeet TDT v3 int8 (sherpa-onnx) downloaded from HF (~640MB) and run via `transcriber-cli`:
  - EN: "Hello, this is a real on device test…the lazy dog." — RTF **0.082**
  - RU: "Привет, это проверка движка транскрибации на русском языке прямо на этом компьютере." — RTF **0.088**
  - Multilingual RU+EN confirmed; ~12× faster than realtime.
- **App installed & running** in the menu bar (`Scripts/install-debug.sh`): debug `Transcriber.app`, ad-hoc signed, links the **real sherpa core** (ORT + sherpa dylibs bundled in Contents/Frameworks via rpath). GUI launches; mic/system permissions to be granted by user.
- ggml whisper.cpp backend (`whispercpp`) added — consumes the ggml `.bin` from model_manager (closes the whisper-on-sherpa ONNX gap); `--features whispercpp` builds.

## DONE — real ASR backends (feature-gated)
- `asr/sherpa.rs` (sherpa-rs / ONNX Runtime) — whisper + parakeet. `cargo check --features sherpa` builds (ORT via cmake).
- `vad_silero.rs` (Silero via sherpa), wired into `vad::make_vad`; lib.rs declares it under `#[cfg(feature="sherpa")]`.
- `asr/coreml.rs` (Apple fast path via fluidaudiocli subprocess).
- ✓ parakeet HF repo id confirmed: `csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`.

## DONE — UniFFI + macOS app
- UniFFI Swift bindings generate (`apple/Scripts/build-core.sh`); `core_version` smoke ran.
- `/apple` SwiftPM app **builds end-to-end** and links the static core lib. Files:
  App/{main,AppDelegate,WindowManager}, Core/Engine (bridge), Audio/{AudioCapture(MicSource via AVAudioEngine),ProcessTapSource(CoreAudio tap 14.4+),ScreenCaptureSource(SCK)}, Design/{Theme,Components,Prefs}, Views/{Popover,MainWindow,Live,History,Dashboard,Settings}.
- `Scripts/package-app.sh` → `apple/dist/Transcriber.app` (release, 7.2 MB self-contained arm64 binary, LSUIElement + TCC strings, valid Info.plist).

## DONE — Android client (`/android`)
- Kotlin + Jetpack Compose app, namespace `app.transcriber.android`, minSdk 29.
- Reuses the SAME core via UniFFI Kotlin bindings; `.so` cross-compiled for arm64-v8a (cargo-ndk, NDK 29). Build script `android/build-core.sh`.
- Mic capture (AudioRecord) → pushAudioFrame; foreground service; EngineBridge mirrors the Swift Engine (events → StateFlow → Compose).
- **`./gradlew assembleDebug` → app-debug.apk (59MB)**; `./gradlew testDebugUnitTest` → 11 behavioral tests green (reducer logic).
- ⚠ Android runs on **mock ASR**: sherpa (ONNX Runtime) / whisper.cpp are NOT built for Android NDK yet — full pipeline works end-to-end but text is mock until a prebuilt ONNX Runtime for Android is added to jniLibs. System audio (MediaProjection) is a stub. Default core features (store/api/download) all cross-compile fine.

## TODO / remaining (honest)
- **Android real ASR**: код ГОТОВ дальше, чем писалось раньше: `android/build-core.sh` по умолчанию собирает `ffi,sherpa` и кладёт prebuilt ORT (sherpa-rs download-binaries v1.12.9) в jniLibs; реальные `libonnxruntime.so`/`libsherpa-onnx-c-api.so` лежат в `app/src/main/jniLibs/arm64-v8a/`. НЕ проверено на реальном устройстве (нужен прогон + поставка модели).
- **Android system audio**: `SystemAudioCapture.kt` реализован полностью (AudioPlaybackCaptureConfiguration, обработка ошибок, документированные ограничения DRM/звонков) — тоже ждёт живого прогона.
- **Not runtime-verified**: real transcription (needs model download + run) and audio capture (needs signed .app + TCC grants). Pipeline verified via mock backend e2e only; GUI not run (headless).
- **whisper-via-sherpa needs ONNX files**, but `model_manager` downloads ggml `.bin` (for whisper.cpp). Parakeet path fully covered. Reconcile if whisper-on-sherpa is used.
- Settings stubs: device picker / live level meter; "launch at login" (SMAppService) is a UI placeholder.
- Code signing + notarization + Sparkle for distribution (scripted, not executed).
- CLI harness (WAV-driven) still a stub.
- Deployment-target warnings silenced via MACOSX_DEPLOYMENT_TARGET=14.0 in build-core.sh.

## Раунд UI macOS — 2026-06-19 (тех-лид + субагенты)

Полировка меню-бар приложения и устранение продуктовых багов. Сборка/тесты/установка зелёные; приложение запущено, ASR — реальный sherpa.

- **#1 Popover вернули (стекло).** Левый клик иконки → `NSPopover` (transient, `preferredEdge=.minY`, заякорен к `statusItem.button.bounds`) — стрелка к иконке, выпадает вниз, соседние иконки не перекрывает. Контент на стекле (`NSHostingController` с прозрачным слоем). Правый/ctrl-клик → короткое `NSMenu` (через `menu.popUp`). Файл `Views/PopoverView.swift` создан заново: шапка (статус+таймер+«инт N·M сл»), Источники (тумблеры Микрофон/Система → `captureMic/captureSystem`, устройство·язык, мини-уровень `MiniBars`), Live-лента (новые сверху, 6 последних, кружок trackColor, хвост через `LiveTail`), мини-метрики RTF/Лаг/CPU/RAM, кнопка Старт/Стоп (`RecordButton`), футер (Окно/История/Настройки → `showWindow`). Высота ограничена (`maxHeight 560`, лента 320), popover не уходит вверх. `AppDelegate` ловит оба клика через `sendAction(on:)`.
- **#2 Sparkline слов** в popover (`WordsSparkline`): сглаженный area/line по сумме слов на интервал из `engine.liveFeed` (последние 24, хронологически), переиспользует `Sparkline`.
- **#3 Сайдбар не обрезается.** `RootView`: `.navigationSplitViewColumnWidth(min:232, ideal:248, max:300)`, верхний отступ 24pt под traffic lights, метки разделов `.lineLimit(1).fixedSize(horizontal:true)`. Подписи и карточка записи больше не срезаются.
- **#4 Пустые интервалы скрыты из Истории.** Чистая функция `HistoryLogic.isNonEmpty` (нужны и `totalWords>0`, и непустой текст) + `nonEmpty`; покрыто тестами.
- **#5 История — полный текст.** Новый `Views/HistoryLogic.swift` (`HistoryEntry` с `fullText`, `entries/matches/preview`). Список показывает превью текста с подсветкой совпадения (`AttributedString`); детали справа — полный текст по дорожкам; поиск по `fullText` (без повторного дёргания ядра в цикле). Тесты — `Tests/.../HistoryLogicTests.swift` (13).
- **#6 Дашборд «нет активности» — ИСПРАВЛЕН. Причина:** ядро хранит `voice_events.ts` как RFC3339 с локальным смещением зоны (`+03:00`), а SQLite сравнивает границы диапазона **лексикографически**; UI слал границы через `Fmt.isoPlain` — UTC с суффиксом `Z`. Строки `…+03:00` и `…Z` сортируются несогласованно (`'9' > '0'` в позиции часа), и сегодняшние события выпадали из верхней границы → пустой график. Корень в UI, не в ядре (в БД 32 voice_events / 57 intervals за сегодня). **Фикс:** добавлен `Fmt.isoLocal`/`Fmt.queryBound` (локальный ISO со смещением зоны) — для voiceActivity и intervals теперь шлём согласованный со стораджем формат. Плюс рефреш активности по `engine.liveFeed.count` (обновляется во время записи).
- **#7 Окно — liquid glass.** `RootView` рисует `VisualEffectView(.underWindowBackground, behindWindow)` на весь фон + матовый контент `bgBase.opacity(0.92)`; окно `isOpaque=false`, `backgroundColor=.clear`, прозрачный титлбар — углы скруглены системно, стекло читается по краям.
- **#8 Документация API + curl** в Настройках (секция «Эндпоинты и примеры curl»): `/api/intervals`, `/api/transcriptions`, `/api/voice-activity?type=hourly|daily`, `/api/state`; моноширинные примеры с кнопкой «Копировать», Bearer-заголовок только при непустом токене, base URL из `config.api`. На русском.
- **#9 Язык: Авто / Русский / English** в Настройках транскрипции (`LanguageMode .auto/.fixed("ru")/.fixed("en")` → `applyConfig`), дефолт Авто.
- **#10 Live: новое сверху.** `liveLines` без разворота (liveFeed уже новейший-первый), хвост «обрабатываю…» вверху, скролл к `head`. Применено и в окне Live, и в ленте popover.
- **#11 Сборка без mock-asr.** `build-core.sh`: `cargo build [--release] --no-default-features --features store,api,download,sherpa,whispercpp,ffi`. Проверено: в `lib/libtranscriber_core.a` 0 mock-символов; бинарь линкует реальный `libsherpa-onnx-c-api.dylib` + `libonnxruntime.1.17.1.dylib`. При сбое ASR теперь честная ошибка, а не молчаливый mock.

**Верификация:** `swift build` чисто; `swift test` — 24 зелёных (13 History + 4 LiveTail + 7 ModelSelection); `install-debug.sh` (после `pkill`) → `pgrep -x Transcriber` подтверждает запуск; `otool -L` подтверждает реальный sherpa ASR.

**Субагенты раунда:** (A) Dashboard #6 — `DashboardView.swift`; (B) History #4/#5 — `HistoryView.swift` + `HistoryLogic.swift` + тесты; (C) Settings #8/#9 — `SettingsView.swift`. Тех-лид сам: popover #1/#2 (`PopoverView.swift`, `AppDelegate.swift`), сайдбар #3 + окно-стекло #7 (`RootView.swift`), Live-разворот #10 (`LiveView.swift`), общий фикс зоны `Fmt.queryBound` (`Components.swift`), build-core #11, сведение и финальный гейт.

## Раунд UI macOS №2 — 2026-06-19 (тех-лид + субагенты)

Устранение продуктовых багов навигации и компоновки. Сборка/тесты/установка зелёные; приложение запущено, ASR — реальный sherpa.

- **#1 Popover — фиксированный размер, без скролла.** `Views/PopoverView.swift`: убран внутренний `ScrollView` ленты. Popover теперь фиксированной ширины (`popoverWidth = 344`), высота определяется содержимым (фиксированное число строк). Live-лента показывает только последние `maxLiveLines = 5` реплик (новое сверху), остальное не отображается — без прокрутки. Строка реплики ужата до `lineLimit(2)`, чтобы высота popover не «прыгала». Шапка/источники/sparkline/метрики/кнопка/футер — компактно, помещаются без скролла.
- **#2 + #6 Боковая панель НЕсворачиваемая.** `Views/RootView.swift`: `NavigationSplitView` заменён на кастомный `HStack` (панель фиксированной ширины `sidebarWidth = 232` + `Divider` + контент). Кнопки-тоггла свёртки больше нет — панель видима всегда, «застрять» нельзя. Список разделов — кастомные кнопки `SidebarItem` (иконка+подпись, подсветка выбранного через `accent.opacity(0.22)`, hover-фон), переключение через `nav.section = section` доступно из любого раздела. Glass-вид панели (`VisualEffectView(.sidebar, behindWindow)`) и карточка записи сверху сохранены.
- **#3 Обрезка/смещение сайдбара — устранено.** Панель рисуется от левого края окна (`HStack`, без balanced-распределения колонок NavigationSplitView, которое и давало смещение/обрезку). Верхний инсет 28pt освобождает зону кнопок-светофора, контент панели прижат `alignment: .topLeading` и не уходит за левый край. Подписи разделов (`lineLimit(1)`) и карточка записи видны полностью. Минимальный размер окна зафиксирован: `RootView.frame(minWidth:860, minHeight:560)` + `w.contentMinSize = 860×560` в `AppDelegate` — ничего не схлопывается.
- **#4 Примеры API — только при включённом API.** `Views/SettingsView.swift` (`ApiSettings`): секция «Эндпоинты и примеры curl» обёрнута в `if enabled`. Когда API выключен — секция скрыта, вместо неё компактная подсказка «Включите API, чтобы увидеть эндпоинты и примеры curl.». `.onAppear(perform: load)` перенесён на первую секцию.
- **#5 Блок «Внешний вид» удалён.** `Views/SettingsView.swift` (`GeneralSettings`): секция «Внешний вид» (только статичный текст, без реальных настроек) удалена целиком; `.onAppear` автозапуска перенесён на «Основные». В `Design/Prefs.swift` удалён мёртвый `followSystemAppearance` (нигде не читался), doc-комментарий приведён в соответствие. `showTimer/launchAtLogin/compactPopover` не тронуты.
- **#7 Пикеры даты в Истории.** `Views/HistoryView.swift`: оба `DatePicker` переведены на `.datePickerStyle(.field)` + фиксированная ширина `frame(width: 96)` — дата вида «19.06.2026» помещается целиком. Диапазон «с → по» обёрнут в surface-контейнер (`RoundedRectangle` с `surface1`, скругление `Radius.control`), разделитель `arrow.right` по центру, моноширинный шрифт. Кнопка обновления — аккуратная квадратная 28×28 на surface, accent-тоном. Логика `reload/isoStart/isoEnd` не тронута.

**Верификация:** `swift build` чисто; `swift test` — 24 зелёных (без регрессий); `install-debug.sh` (после `pkill`) → `pgrep -x Transcriber` подтверждает запуск (PID получен); `otool -L .build/debug/Transcriber | grep -i sherpa` подтверждает реальный sherpa ASR.

**Субагенты раунда:** (A) Settings #4/#5 — `SettingsView.swift` + `Prefs.swift`; (B) History #7 — `HistoryView.swift`. Тех-лид сам: popover #1 (`PopoverView.swift`), несворачиваемая навигация/сайдбар/окно #2/#3/#6 (`RootView.swift`, `AppDelegate.swift`), сведение и финальный гейт build/test/install.

## Раунд UI macOS №3 — 2026-06-19 (тех-лид + субагенты)

Надёжное позиционирование popover, семантический поиск, понятные метрики, синхронизация буфера с ядром. Сначала ПЕРЕГЕНЕРИРОВАНЫ Swift-биндинги (`build-core.sh`) — ядро обновило метрики (CPU p50/p90, RSS+пик, dropped в источниках) и снизило floor мин-интервала до 10с. Сборка/тесты/установка зелёные; приложение запущено (PID), ASR — реальный sherpa.

- **#1 Popover — собственная стеклянная панель (надёжно).** Отказ от капризного `NSPopover` в accessory-приложении. `App/AppDelegate.swift`: новый `PanelController` — borderless `NSPanel` (`.nonactivatingPanel`, `level = .statusBar`, прозрачный фон, материал `.popover`, скруглённые 12pt углы, тень). Кадр считается ВРУЧНУЮ от `statusItem.button.window.frame` в экранных координатах: центр по X под серединой кнопки, верх панели = `buttonFrame.minY - gap` (строго под нижней кромкой меню-бара → НИКОГДА не залезает на строку меню-бара), горизонтальный зажим в `visibleFrame` с полями. Закрытие — локальный+глобальный мониторы кликов вне панели и `windowDidResignKey`. `PopoverView` получил ФИКСИРОВАННУЮ высоту (`popoverHeight = 480`), середина обёрнута в `ScrollView` — контент не может вытолкнуть окно вверх.
- **#2 Семантический поиск в Истории.** Новый `Views/SemanticSearch.swift`: чистая логика `SemanticRanking` (тестируемо) + `@MainActor SemanticSearchEngine` с кэшем эмбеддингов по interval id. Три сигнала на интервал (0..1): exact (substring), fuzzy (доля совпавших токенов запроса), semantic (нормированный cosine эмбеддингов Apple `NLEmbedding`, `.russian`→`.english`, on-device; nil-модель → деградация до exact+fuzzy). Комбинирование: `score = exact·10 + fuzzy·4 + semantic·2` — exact гарантированно перевешивает max(fuzzy+semantic)=6, дословные совпадения всегда выше. Нулевые сигналы отсекаются. `HistoryView`: пустой запрос → прежняя группировка по дням (новое сверху); непустой → плоский ранжированный список, дословные подсвечены. 16 поведенческих тестов (без рантайма NLEmbedding).
- **#3 Слайдер мин-интервала 10–300с.** `Views/SettingsView.swift`: нижняя граница `slider("Мин. длина", …, 10...300, …)`; дефолт 30, применение через `applyConfig` (ядро clamp'ит к floor=10). Подпись «с».
- **#4 Метрики понятнее (popover + Дашборд).** Новые чистые форматтеры в `Design/Components.swift` `Fmt`: `cpuLine` («38% · мед 22% · p90 61%»), `ramLine` («1.1 ГБ · пик 1.4 ГБ», пик только если больше текущего), `droppedAudioLine` (сэмплы/16000 → «потеряно аудио: Xс», `nil` при 0 → показатель СКРЫТ). Popover (`PopoverView`) и Дашборд (`DashboardView`) показывают CPU тек+мед+p90, RAM тек+пик, лаг/очередь/RTF — с тултипами `.help(...)` (лаг 0 = реалтайм, очередь 0 = не отстаём, и т.д.). Дословное «потери N» убрано; потери аудио — отдельной строкой только при ненулевой сумме. 8 тестов форматтеров.
- **#5 `audioQueueSize` 2048 → 48000.** `Core/Engine.defaultConfig` синхронизирован с дефолтом ядра (`config.rs`: 48_000 = 3 с при 16 кГц). Раньше малый буфер перетирался → потери сэмплов; контракт Engine не менялся.
- **#6 Ось X графика — без наложения.** `DashboardView`: чистая `thinnedLabels(_:maxVisible:)` прорежает строковые метки оси (~10 видимых, правый край всегда подписан), `chartXAxis { AxisMarks(values: visibleXLabels) }`. Компактный формат (HH:00 / dd.MM) сохранён. Подписи не накладываются при любом числе бакетов.

**Верификация:** биндинги перегенерированы (`build-core.sh` — ядро + sherpa + UniFFI); `swift build` чисто; `swift test` — **48 зелёных** (24 старых + 16 semantic + 8 metric-format, без регрессий); `install-debug.sh` (после `pkill`) → `pgrep -x Transcriber` = PID; `otool -L` подтверждает `libsherpa-onnx-c-api.dylib` в `.build` и в `.app` (ORT+sherpa dylibs в Contents/Frameworks).

**Субагенты раунда:** (A) семантический поиск #2 — `SemanticSearch.swift` (новый) + `HistoryView.swift` + тесты; (B) настройки #3 — `SettingsView.swift`; (C) метрики-отображение #4 + ось графика #6 — `DashboardView.swift`. Тех-лид сам: перегенерация биндингов, popover-панель #1 (`AppDelegate.swift`, `PopoverView.swift`), форматтеры метрик + popover-метрики #4 (`Components.swift`, `PopoverView.swift`), Engine-константа #5 (`Engine.swift`), тесты форматтеров, сведение и финальный гейт build/test/install.

## Раунд UI macOS №4 — 2026-06-19 (скролл ленты + контраст стекла)

Две точечные правки в menu-bar UI. Сборка/тесты/установка зелёные; приложение запущено (PID), ASR — реальный sherpa.

- **#1 Скролл ТОЛЬКО на Live-ленте фраз.** `Views/PopoverView.swift` перестроен: шапка, ИСТОЧНИКИ, sparkline, мини-метрики (CPU/RAM/RTF/лаг), кнопка Старт/Стоп, футер — ФИКСИРОВАННЫЕ, всегда видны (нет общего `ScrollView`). Прокручивается только Live-лента: внутри `ScrollView` с потолком `liveFeedMaxHeight = 220` (новое сверху, показываются ВСЕ строки, а не `prefix(5)`). Высота окна поднята `popoverHeight 480 → 520` (фиксированные секции теперь занимают больше + ограниченная лента); итог стабилен — AppKit не выталкивает панель на меню-бар. Позиционирование «строго под иконкой» в `PanelController` не менялось.
- **#2 Контраст/стекло (по мотивам CodexBar).** Рецепт: размытие `NSVisualEffectView` (behindWindow) + СВЕРХУ полупрозрачный тёмный скрим + светлая hairline-рамка. Добавлен переиспользуемый `GlassBackground` + модификатор `.glassBackground(...)` в `Design/Theme.swift` (параметры: `material` дефолт `.hudWindow`, `dimming` дефолт 0.42, `cornerRadius`, `border`; затемнение — главный «контраст-винт»). Popover (`App/AppDelegate.swift` `PanelController`): материал сменён `.popover → .hudWindow`, поверх размытия добавлен тёмный скрим (NSView, `black.opacity(0.42)`) и hairline-рамка `white 0.10`, углы 14pt. Главное окно (`Views/RootView.swift`): тот же приём — над оконным стеклом мягкий скрим `black.opacity(0.22)` (мягче, т.к. контент-панели и так рисуются поверх матовым фоном). Подкрутка: `dimming`/`opacity` в `PanelController` (0.42) и `RootView` (0.22).

**Верификация №4:** `swift build` чисто; `swift test` — **48 зелёных** (без регрессий, новых тестов не добавляли — правки чисто визуальные); `install-debug.sh` (после `pkill`) → `pgrep -x Transcriber` = PID; `otool -L .build/debug/Transcriber | grep sherpa` = `libsherpa-onnx-c-api.dylib` (реальный ASR). Визуальный рендер субагентом не проверялся — параметры затемнения вынесены для быстрой подкрутки.

## Раунд UI macOS №5 — 2026-06-19 (история метрик в Engine + 24ч-аналитика popover)

Дашборд и popover. Сборка/тесты/установка зелёные; приложение запущено (PID), ASR — реальный sherpa.

- **#1 История метрик переехала в Engine (переживает переоткрытие Дашборда).** Раньше rolling-история sparkline'ов жила в самой `DashboardView` (`@State MetricHistory`) и сбрасывалась при пересоздании вью. Теперь в долгоживущем `Core/Engine.swift`: `@Published private(set) var metricHistory: [MetricSample]` (`struct MetricSample { cpu: Float; ramBytes: UInt64; ts: Date }`), наполняется в `handle(.metrics)` через `recordMetricSample`, кап `metricHistoryCap = 600` (~10 мин при ~1/с). Добавление с капом вынесено в ЧИСТУЮ `Engine.appendCapped(_:_:cap:)` (тестируема). Контракт Engine аддитивен, ничего не сломано. `DashboardView` удалил локальный `MetricHistory` и `.onChange(of: engine.metrics)`; sparkline'ы читают из `engine.metricHistory`.
- **#3 RAM — консистентность числа и графика.** Sparkline RAM теперь берёт ИМЕННО ряд `ramBytes` из `metricHistory` (`.map { Double($0.ramBytes)/1_048_576 }`, МБ), CPU-sparkline — ряд `cpu`. Раньше была путаница рядов (RAM-график «скакал», т.к. брал не тот ряд). Число RAM-карточки = `Fmt.ramLine(memoryRssBytes, memoryRssPeakBytes)` («тек · пик»). RTF/Лаг истории нет — в их sparkline передаётся пустой ряд (число берётся из `engine.metrics`, не сломано).
- **#2 Равная высота KPI-карточек.** `KpiCard`: содержимое `.frame(maxHeight:.infinity, alignment:.topLeading)` + `Spacer(minLength:0)` перед Sparkline (число/подпись прижаты вверх, sparkline вниз), сама карточка `.frame(maxHeight:.infinity)` → в `LazyVGrid` все 4 карточки тянутся до самой высокой. CPU с подписью больше не выше остальных.
- **#4 p90 убран из UI.** CPU-карточка Дашборда: подпись только медиана (`"мед N%"`), p90 не показывается; тултип поправлен. Поля ядра не трогались.
- **#5 Мета-инфа popover — серая, в одну строку.** Шапка `Views/PopoverView.swift`: счётчики «инт N · M сл» — `Theme.Color.textTertiary`, `.metricSmall`, `.lineLimit(1)` + усечение хвоста.
- **#6 Popover: график за 24ч + статистика за 24ч + полоса покрытия.** Старый `WordsSparkline` (слова по интервалам из `liveFeed`) заменён на `DayActivity`: берёт интервалы за 24ч из ХРАНИЛИЩА (`engine.intervals(from:to:)` с `Fmt.queryBound`, надёжнее ленты в памяти), считает чистой `Activity24h.window(intervals:now:)` → `Window24h` с 24 часовыми бакетами (старый→новый, сумма слов по часам, флаг `active` = был ли интервал в часе, агрегаты `totalWords/totalIntervals`). Рисует `Sparkline` по словам (h34) + под ним `CoverageBar` (полоса покрытия 24ч: час с интервалом — акцент, иначе приглушённый `surface2`). Заголовок «Активность за 24 часа», справа серая статистика «N сл · M инт». Обновляется в `.task` и `.onChange(of: liveFeed.count)` (хранится в `@State Window24h?`, тяжёлый запрос не на каждом рендере). Чистые функции и `HourBucket/Window24h/CoverageBar` вынесены в `Design/Components.swift`.
- **Тесты (новый `Tests/TranscriberTests/Activity24hTests.swift`, 8 шт.):** кап `appendCapped` (добавление/срез старого/ровно у капа), 24ч-бакетинг (24 бакета старый→новый, суммы слов в правильные часы, агрегаты), покрытие per-hour, исключение интервалов вне окна. Календарь/зона зафиксированы (UTC) для детерминизма.

**Верификация №5:** `swift build` чисто; `swift test` — **55 зелёных** (47 старых + 8 новых поведенческих); `install-debug.sh` (после `pkill`) → `pgrep -x Transcriber` = PID; `otool -L .build/debug/Transcriber | grep sherpa` = `libsherpa-onnx-c-api.dylib` (реальный ASR цел). Визуальный рендер не проверялся автоматически.

**Субагенты раунда:** (A) Dashboard #1-чтение/#2/#3/#4 — `DashboardView.swift`; (B) Popover #5/#6 — `PopoverView.swift`. Тех-лид сам: `Engine.metricHistory`+`appendCapped` #1 (`Engine.swift`), общие чистые функции 24ч/покрытие + `CoverageBar` (`Components.swift`), тесты, сведение и финальный гейт build/test/install.

## Раунд №6 — 2026-06-19 (горячее применение настроек во время записи)

Часть настроек теперь применяется БЕЗ перезапуска записи; модель — только перезапуском по кнопке. Сборка/тесты/установка зелёные; приложение запущено (PID), ASR — реальный sherpa.

**Что применяется на лету (без перезапуска, во время записи):**
- **Длина интервала** — мин. и макс. (`min_interval_s` / `max_interval_s`).
- **Пауза тишины** для реза (`silence_cut_ms`).
- **Порог VAD** — `silero_threshold` (вероятность речи Silero) и `rms_fallback` (RMS-сетка).
- **Язык распознавания** (`LanguageMode`: авто / ru / en) — перечитывается на КАЖДОМ интервале.

**Что только по кнопке «Применить» (с перезапуском сессии): МОДЕЛЬ.** Бесшовной смены модели нет: модель — снимок старта. Кнопка делает стоп → ожидание полной остановки ядра → `loadModel` → `start` → возобновление захвата (если шла запись); если простаивали — модель сохраняется и применится на следующем старте.

### Ядро (`/core`)
- **Общий `RuntimeParams`** (`pipeline.rs`): `{ min_interval_s, max_interval_s, silence_cut_ms, silero_threshold, rms_fallback, language }`, хранится как `Arc<parking_lot::Mutex<RuntimeParams>>` в `TranscriberCore`. Инициализируется из конфига в `new()`; пересинхронизируется из текущего cfg в `start()`.
- **`configure()`** помимо сохранения конфига и API-toggle ОБНОВЛЯЕТ поля `RuntimeParams` под мьютексом (интервалы/тишина/VAD/язык). Модель не трогает.
- **`IntervalCutCoordinator::set_params(min,max,silence)`** (`interval.rs`) — горячее обновление полей; конструктор `new(min,max,silence)` сохранён как есть (его используют тесты).
- **`Vad::set_threshold(silero, rms)`** (`vad.rs`) — дефолт no-op; `RmsVad` обновляет RMS-порог; `SileroVad` (`vad_silero.rs`, под feature `sherpa`) обновляет RMS мгновенно, а при изменении silero-порога пересоздаёт нативный детектор (sherpa не даёт менять порог у существующего; при сбое — оставляет рабочий со старым порогом).
- **`dsp_loop`** принимает `Arc<Mutex<RuntimeParams>>` и на каждом тике зовёт `coord.set_params(...)` и для каждого канала `vad.set_threshold(...)` (дёшево, parking_lot). **`asr_loop`** принимает тот же `Arc` и читает ТЕКУЩИЙ `language` на каждом интервале (вместо снимка `cfg.language`).
- **Тесты (поведение):** `interval.rs` — снижение `max` форсирует рез раньше; смена `silence_cut` меняет момент реза. `vad.rs` — `RmsVad::set_threshold` переключает вердикт `is_speech` на пограничном кадре. Старые тесты не тронуты.
- Проверка: `cargo test` — **80 зелёных** (77 unit + 2 e2e + doc); `cargo check --features ffi,sherpa` — чисто (Silero `set_threshold` под sherpa компилируется).

### macOS (`/apple`)
- **Интервал/тишина/VAD/язык** в `Views/SettingsView.swift` зовут `engine.applyConfig` при каждом изменении (на лету). Добавлен слайдер **«Порог речи (VAD)»** (0.1…0.9 → `vad.sileroThreshold`). Подписи обновлены: явно сказано «Применяется на лету — без перезапуска».
- **Модель — кнопка «Применить»** (`Core/Engine.swift` + `Views/ModelsView.swift`): выбор модели больше НЕ применяется сам. `Engine.stageModel(_:)` лишь ставит `@Published pendingModel` в очередь (если отличается от активной); `applyModelRestart()` коммитит её в конфиг и, если идёт запись, перезапускает сессию. В `ModelsView` выбор строки помечает её «выбрана», сверху появляется баннер с кнопкой **«Применить»** и подсказкой о перезапуске; внизу пояснение, что интервал/VAD/язык — на лету, а модель — перезапуском.
- **Тесты:** `ModelSelectionTests` дополнены поведением staging: выбор другой модели → `hasPendingModel`/`pendingModel` выставлены, активная не меняется; выбор активной — очищает очередь. Прежние тесты целы.
- Проверка: `swift build` чисто; `swift test` — **57 зелёных**; `install-debug.sh` (после `pkill -x Transcriber`) → `pgrep -x Transcriber` = PID; `otool -L .build/debug/Transcriber | grep sherpa` = `libsherpa-onnx-c-api.dylib` (реальный ASR цел).

**Субагентов в этом раунде не привлекалось** (ядро — гейт для UI-сборки; всё вёл тех-лид централизованно).

## Раунд оптимизации памяти/CPU — 2026-06-19 (тех-лид + 3 субагента)

Жалоба: RSS 1.7 ГБ (модель ~640 МБ), растёт до 2.5 ГБ за сессию; CPU тратится «не только на запись/распознавание». Диагностика и фикс. Сборка/тесты/установка зелёные; приложение запущено (PID), ASR — реальный sherpa.

**Диагноз (почему так было):**
- `encoder.int8.onnx` = **652 МБ** (decoder+joiner ещё ~18 МБ) — это и есть «модель», но на диске.
- Дефолтный провайдер `Acceleration::Auto` → `get_default_provider()` → на Apple **CoreML EP**. CoreML EP держит ONNX-веса в памяти И компилирует отдельное CoreML-представление (≈2× модели) → отсюда «лишний» гигабайт в стационаре.
- **Утечка → рост до 2.5 ГБ:** CoreML EP создаёт autoreleased ObjC-объекты на КАЖДЫЙ инференс, а ASR-воркер — сырой `std::thread` (`tc-asr`) без Cocoa autorelease-пула → объекты не освобождаются за сессию.
- **CPU не на месте:** `Engine.pushFrame` гонял КАЖДЫЙ realtime-фрейм через `Task { @MainActor }` → ресэмплинг на UI-потоке + накопление `Task`/копий PCM под контеншеном.
- `NLEmbedding` (ru+en, семантический поиск) грузились `lazy` и висели вечно — сотни МБ ради поиска в Истории.

**Фиксы:**
- **#1 Провайдер по умолчанию `Auto → Cpu`** (`core/src/config.rs`, `apple/.../Engine.swift defaultConfig`). CPU/XNNPACK держит ОДНУ резидентную копию модели (нет дублирования) и не трогает CoreML.framework (нет ObjC-утечки). int8 на CPU остаётся сильно реалтайм (RTF ~0.2–0.3 ожидаемо). Enum `Acceleration` сохранён — CoreML доступен явным выбором, но с пониманием цены RAM.
- **#2 Защитный autorelease-пул на каждый интервал** в `asr_loop` (`pipeline.rs`): `let _arpool = autorelease_pool();` сразу после извлечения job. Helper `autorelease_pool()`/`ArPool` — `objc_autoreleasePoolPush/Pop` через `#[link(name="objc")]`, cfg-gated (macOS/iOS), pop на `Drop` (panic-safe); на прочих ОС — no-op. Гарантирует слив autoreleased-объектов, даже если когда-нибудь снова выберут CoreML.
- **#3 Realtime-аудио мимо главного потока** (`Engine.swift`): новый `CoreBox` (`@unchecked Sendable`, ядро под коротким неконтендящимся `NSLock`); `nonisolated let coreBox`, ставится в `boot()`. `nonisolated func pushFrame` теперь зовёт `coreBox.pushFrame(...)` СИНХРОННО с аудиопотока — `Task { @MainActor }` убран. Ресэмплинг ушёл с UI-потока, накопление `Task` исключено. Подпись `pushFrame` не менялась → `CaptureManager` не тронут.
- **#4 `bg_queue_size` 64 → 4** (`config.rs` + `Engine.swift`). Каждый job очереди — аудио до 300с×16кГц×2 канала ≈ 19 МБ; worst-case очереди срезан с ~1.2 ГБ до ~80 МБ. Интервалы крупные и не копятся (RTF мал), 4 хватает.
- **#5 `NLEmbedding` — загрузка по требованию, выгрузка по простою** (`Views/SemanticSearch.swift`). Вместо `lazy var` — optionals + флаг + `unloadTask`. `rankedEntries` при непустом запросе зовёт `ensureEmbeddingsLoaded()` + `armIdleUnload()` (таймер 5с); пустой запрос — только взводит выгрузку. `unloadEmbeddings()` нилит обе модели и чистит кэш эмбеддингов. Загрузчик вынесен в инъектируемое замыкание (тестируемость без реального NLEmbedding). 3 новых теста (loader-once / empty-no-load / unload-clears-cache+reload).

**Верификация:** `cargo test` — **79 зелёных**; `cargo check --features ffi,sherpa` чисто. `build-core.sh debug` — `.a` пересобрана, биндинги перегенерированы (FFI-поверхность не менялась), `swift build` чисто. `swift test` — **60 зелёных** (57 + 3 новых). `install-debug.sh` (после `pkill`) → `pgrep -x Transcriber` = PID; `otool -L` подтверждает `libsherpa-onnx-c-api.dylib` + `libonnxruntime.1.17.1.dylib` в `.build` и в `.app`. **Рантайм-замер RAM не делался** (нужна реальная запись с разрешениями mic/system) — фиксы подтверждены статически/сборкой; ожидаемый эффект: стационар ↓ на ~600 МБ…1 ГБ (нет дублирования модели), рост за сессию устранён (нет ObjC-утечки + нет накопления Task), поиск-эмбеддеры не висят вне поиска.

**Субагенты раунда:** (A) Rust core #1/#2/#4 — `config.rs`, `pipeline.rs`; (B) Swift аудио #3 + дефолты — `Engine.swift`; (C) Swift семантика #5 — `SemanticSearch.swift` + тесты. Тех-лид: диагностика (otool/du/grep), контракты, проверка диффов, финальный гейт (build-core/swift/install/otool).

## Раунд UX поиска в Истории — 2026-06-19 (тех-лид)

Две правки по семантическому поиску. Сборка/тесты/установка зелёные; приложение запущено (PID), ASR — реальный sherpa.

- **#1 Скролл результатов всегда наверх.** При смене состава/порядка результатов список поиска должен возвращаться к самому релевантному (верхнему). `Views/HistoryView.swift`: результаты активного поиска вынесены в `@State rankedResults` (пересчёт чистой `recomputeRanked()` на изменение `search`, данных периода в `reload()`, и готовности эмбеддеров — НЕ на каждый рендер, т.к. у `rankedEntries` есть побочка запуска загрузки/таймера). Список обёрнут в `ScrollViewReader`, строки получили `.id(entry.id)`, `.onChange(of: rankedResults.map(\.id))` скроллит `proxy.scrollTo(top, anchor: .top)` с лёгкой анимацией. Прежний computed `ranked` удалён.
- **#2 Ввод в поиск не блокируется загрузкой модели.** Загрузка `NLEmbedding` теперь АСИНХРОННАЯ. `Views/SemanticSearch.swift`: `ensureEmbeddingsLoaded()` запускает `Task.detached(.userInitiated)` (загрузчик помечен `@Sendable`), модели переносятся на главный актор боксом `EmbeddingModels (@unchecked Sendable)` через `applyLoadedEmbeddings`. Пока модель не готова — семантический сигнал = 0, поиск идёт по exact+fuzzy сразу. По завершении флипается `@Published embeddingsReady` → `HistoryView.onChange` → пересчёт с семантикой и автоскролл наверх. Гонки закрыты: `Task.isCancelled` после загрузчика + guard `loadTask != nil` в `applyLoadedEmbeddings`; `unloadEmbeddings()` отменяет загрузку и сбрасывает `embeddingsReady`. `cachedEmbedding` больше НЕ кэширует пустой вектор, пока `!embeddingsLoaded` (иначе семантика не включилась бы после догрузки). Таймер выгрузки по простою (5с) сохранён.
- **Тесты:** 3 lifecycle-теста переведены на `async` + тестовый seam `awaitEmbeddingLoadForTesting()` (ждёт фоновую загрузку) и потокобезопасный `LoadCounter (@unchecked Sendable)` для `@Sendable`-загрузчика. Проверяют: загрузка ровно один раз в активном окне; пустой запрос не грузит; выгрузка чистит кэш и разрешает перезагрузку.

**Верификация:** `swift build` чисто; `swift test` — **60 зелёных** (19 в SemanticSearchTests, включая 3 async; без регрессий); `install-debug.sh` (после `pkill`) → `pgrep -x Transcriber` = PID. Рантайм поведения скролла/догрузки в живом UI не проверялось автоматически (нужен прогон в приложении с реальными данными Истории).

## Раунд диагностики памяти + тесты расхода — 2026-06-19 (тех-лид)

Жалоба: даже после перехода на CPU-провайдер UI показывает RAM 1.9 ГБ · пик 2.4 ГБ; «пик как будто сохраняется между запусками». Замерили факт, нашли причину, добавили тесты расхода.

**Замеры (живой процесс `footprint`/`vmmap` + новый тест ядра):**
- `MALLOC_LARGE ≈ 1.7 ГБ` — сюда ONNX Runtime кладёт веса модели + арену активаций. CoreML/Espresso/ANE — только залинкованные dylib, **нет `.mlmodelc`/данных Espresso → CoreML EP не активен** (CPU-провайдер реально применился, дублирования нет).
- Тест `memory_footprint_parakeet` (chunk 10/15/30с, 15–20 инференсов): **рост iter5→end ≈ 0 МБ** — УТЕЧКИ НЕТ, RSS плато и даже падает (арена ORT отдаётся между инференсами). «после загрузки» 2.0–2.4 ГБ, стационар 1.47/1.72/1.67 ГБ (10/15/30с — разброс перекрывает эффект чанка).
- **Вывод:** пик ~2.4 ГБ — это ОДНОРАЗОВЫЙ спайк при загрузке модели (ORT оптимизирует граф int8-модели), который потом оседает. Стационар ~1.5–1.7 ГБ — это сами веса Parakeet 0.6B int8, резидентно в ORT (диск 652 МБ → ~1.4–1.5 ГБ в памяти). Не утечка.

**Что сделано:**
- **Тесты расхода памяти.** `core/src/metrics.rs`: публичный `process_rss_bytes()` (mach RSS). `core/src/asr/sherpa.rs`: `#[cfg(test)] mod memory_tests` с `#[ignore]`-тестом `memory_footprint_parakeet` — грузит реальную модель (CPU), гоняет N инференсов синуса, печатает пол/пик/стационар/рост и **ассертит рост<150МБ после прогрева (лик-гард)**. Запуск: `cargo test --features sherpa memory_footprint -- --ignored --nocapture` (env `TC_MEM_CHUNK_S`/`TC_MEM_ITERS`/`TRANSCRIBER_MODELS_PATH`).
- **Чанк транскрипции — оставлен 30с.** Пробовали 15с, но выигрыш по RSS в пределах шума (арена и так отдаётся), а мелкий чанк режет слова на границах. Коммент в `pipeline.rs` фиксирует замеры и решение.
- **Метрики строго сессионные (RAM-only).** `Engine.handle`: при выходе из `.recording` чистим `metrics = nil` и `metricHistory = []`; историю sparkline'ов копим только во время записи (guard). На диск метрики не пишутся вообще (SQLite — только intervals/voice_events). После остановки/перезапуска потребительская метаинфа не «зависает».

**Единственный надёжный рычаг ниже ~1.5 ГБ — меньшая модель** (Parakeet 0.6B меньше не бывает): квантованный whisper через whisper.cpp (`small-q5_1` ~180 МБ файл → ~0.4–0.6 ГБ резидентно; `base-q5_1` ~60 МБ). Компромисс по точности — решение за пользователем (модель переключается в разделе «Модели»).

**Верификация:** `cargo test` — 79 зелёных; `cargo test --features sherpa memory_footprint --ignored` — проходит (лик-гард зелёный); `build-core.sh debug` чисто; `swift test` — 60 зелёных; `install-debug.sh` → `pgrep` = PID.

## How to build/test the core
```
. "$HOME/.cargo/env"
cd core
cargo test                      # default features, 70 tests
cargo check --features ffi      # Swift FFI surface
```
Not committed yet (per user). Rudiments already deleted (old *_old files, Layer-1 root scripts).

## Раунд «серьёзный проект»: надёжность + инфраструктура — 2026-07-02 (тех-лид)

По плану `docs/ROADMAP.md` (фазы A/B). Сборка/тесты зелёные; поведение реального ASR не менялось.

**Фаза A — надёжность:**
- **Загрузчик моделей (`model_manager.rs`)**: retry с экспоненциальным бэкофом (4 попытки; transport/429/5xx — transient, прочие HTTP — permanent), докачка `.part` через HTTP `Range` (206 → append; 416 при полном `.part` → публикация), пропуск уже скачанных файлов, sha256 файла целиком после завершения (когда дайджест в реестре непустой). 8 поведенческих тестов против локального tiny_http-сервера.
- **Пайплайн**: сбой ASR на чанке больше не молчит — событие `Error{Backend}` «ASR failed on N/M chunks» раз на канал за интервал; воркер `tc-asr` оборачивает интервал в `catch_unwind` (Rust-паника бэкенда = дроп интервала + `Error{Internal}`, воркер живёт; release-профиль переведён `panic=abort → unwind`, иначе catch_unwind мёртв). C++ abort по-прежнему ловится только диагностикой `diag.rs`. 3 теста воркера (failing/panicking backend).
- **Engine.swift**: ошибка `downloadModel` → `lastError` (раньше `try?` съедал — «зависший прогресс»); ошибки store-запросов логируются NSLog (раньше молча пустой список).

**Фаза B — инфраструктура:**
- **CI** `.github/workflows/ci.yml`: ядро на ubuntu+macos (fmt/clippy -D warnings/test/check --features ffi), macOS-приложение против mock-ядра, проверка версий.
- **Mock-линковка приложения**: `TRANSCRIBER_CORE_MOCK=1` в `Package.swift` отключает линковку sherpa/whisper (для CI/разработки без cmake+ORT); `build-core.sh` выставляет сам, если FEATURES без sherpa/whispercpp. Проверено локально: mock-ядро + swift test = 69 зелёных; реальная сборка после отката цела (otool: sherpa на месте).
- **LICENSE** (MIT), **CHANGELOG.md** (Keep a Changelog; журнал разработки остаётся здесь), **rustfmt.toml** + весь core отформатирован (cargo fmt, механически), clippy 0 warnings, **Cargo.lock в git** (убран из .gitignore), `scripts/check-versions.sh` (Cargo.toml ↔ Info.plist ↔ build.gradle.kts, включён в CI).
- Репо-гигиена (прошлым коммитом): `apple/dist/`, `apple/lib/` больше не в git (артефакты сборки).

**Верификация:** `cargo test` — 90 зелёных (88 unit + 2 e2e); `cargo clippy --all-targets` — 0 предупреждений; `cargo fmt --check` чисто; `swift build` + `swift test` — 69 зелёных (и с mock-ядром, и с реальным); `check-versions.sh` — OK (0.1.0×3).


## Раунд Chronica: сборщик контекста + журнал дел с экрана — 2026-07-02 (ветка feature/context-collector)

Переклассификация продукта: не просто транскрибатор, а локальный сборщик контекста работы.
Продуктовое переименование **Transcriber → Chronica** (CFBundleName/DisplayName, заголовок окна,
`dist/Chronica.app` в скриптах, README/AGENTS). Технические id (bundle id, крейт, FFI-модули)
СОЗНАТЕЛЬНО не тронуты: смена bundle id сбрасывает TCC-разрешения, смена крейта пересоздаёт
FFI-поверхность; отложено до первого подписанного релиза. `CFBundleExecutable` остался
`Transcriber` (имя бинаря SwiftPM-продукта).

**Новый модуль `apple/Sources/Transcriber/Screen/`:**
- `ScreenContext.swift` — ЧИСТАЯ логика: `ScreenObservation`/`Activity`, `Sessionizer`
  (наблюдение продолжает блок при том же приложении, похожем заголовке (Jaccard ≥ 0.5 /
  префикс / пустой) и паузе ≤ gap=3×период; непустое описание обновляет блок, пустое не
  стирает), `FrameHash` (aHash 8×8, порог «не изменился» < 6 бит), `VisionPrompt` (RU-промпт
  «опиши работу», контекст app+заголовок окна).
- `ActivityStore.swift` — отдельная SQLite `screen.sqlite` (рядом с БД ядра): `activities` +
  `observations`, время — epoch INTEGER (без ловушки лексикографики зон из раунда UI №1 #6),
  ретеншн `deleteOlderThan(days:)` (дефолт 90 дней), WAL.
- `VisionDescriber.swift` — протокол + `OllamaDescriber` (`/api/generate`, images base64,
  temperature 0.2; `probe()` через `/api/tags` → ready / modelMissing(hint: ollama pull …) /
  unavailable). Ollama выбран как единственный способ настоящей локальной маленькой VLM без
  встраивания тяжёлого ML-рантайма; бэкенд заменяем (MLX/llama.cpp — кандидаты).
- `ScreenObserver.swift` — оркестратор (@MainActor): тик по периоду (дефолт 60с, 30…600),
  SCScreenshotManager (кадр ≤1024px, JPEG 0.6, курсор скрыт), фронтальное приложение
  (NSWorkspace) + заголовок окна (CGWindowList, требует «Запись экрана»), aHash-скип
  неизменных кадров БЕЗ вызова LLM (контекст окна тоже не менялся), сессионизация → store,
  `todayActivities` published. Деградация: нет разрешения → статус noPermission; LLM
  недоступна → наблюдение всё равно пишется (app+заголовок — ценный лог), статус
  backendUnavailable с подсказкой.

**UI:** новый раздел «Дела» (`ActivitiesView`): блоки за выбранный день, время/приложение/
заголовок/описание/×N наблюдений; раскрытие блока подтягивает ТРАНСКРИПЦИЮ речи за интервал
дела (`engine.intervals` по перекрытию, `Fmt.queryBound`) — дело = «что делал + что говорилось».
Настройки → секция «Экран (журнал дел)»: тумблер (по умолчанию ВЫКЛ — приватность), период,
адрес Ollama, модель, кнопка «Проверить» со статусом. `Prefs`: screenEnabled/screenPeriodS/
screenRetentionDays/ollamaURL/visionModel.

**Тесты (+18, итого 87 Swift):** `ScreenContextTests` (12: сессионизация — старт/продление/
смена приложения/разрыв по паузе/пустое описание/бэкфилл заголовка/похожесть заголовков;
aHash — идентичность/малое изменение под порогом/инверсия > порога; промпт) и
`ActivityStoreTests` (6: CRUD, диапазон-перекрытие новые-сверху, наблюдения, ретеншн,
lastActivity) на реальной SQLite во временном каталоге.

**Верификация:** `swift build` чисто (0 warnings); `swift test` — 87 зелёных; ядро не
менялось (90 зелёных с прошлого раунда); `install-debug.sh` → приложение запущено (PID),
разделы открываются. Живой прогон vision-пайплайна требует установленной Ollama + модели
(`ollama pull qwen2.5vl:3b`) и разрешения «Запись экрана» — в headless-сессии не выполнялся,
готовность бэкенда видна кнопкой «Проверить» в Настройках.

## Раунд Chronica: единый раздел «Журнал» + экспорт за период — 2026-07-02 (ветка feature/context-collector)

По просьбе: дела и история — один блок; лёгкий экспорт за день/период (от-до), включающий
дела, открытые окна и транскрипцию, структурированно и ПОКАНАЛЬНО (как в API).

- **Объединение разделов.** `AppSection` `.history` + `.activities` → один `.journal` («Журнал»,
  иконка `book.pages`). `RootView`/`PopoverView` (футер-ссылка) обновлены. Новый `Views/JournalView.swift`:
  общий тулбар (заголовок + сегментированный переключатель Дела/Транскрипция + период «от→по» +
  кнопка «Сегодня» + меню «Экспорт») над контентом. `HistoryView` и `ActivitiesView` переведены на
  ВНЕШНИЙ период (`from`/`to` приходят из `JournalView`), собственные пикеры периода убраны;
  `HistoryView` сохранил поиск/семантику/детали, `ActivitiesView` — статус/список/раскрытие с
  подтянутой транскрипцией. Оба раскрывают выбор «день» в полный диапазон [начало from .. конец to].
- **Экспорт (`Screen/JournalExport.swift`, чистый).** `JournalExport.build(...)` собирает ЕДИНЫЙ
  `JournalDocument` (Codable): `activities[]` (id/время/app/title/summary/observationCount + `windows[]`
  — открытые окна = наблюдения экрана во времени) и `transcription` (`count` + `intervals[]` → `channels[]`
  {channelId,text,words,language} — та же форма, что `/api/intervals`). Сериализация: `json()`
  (детерминированный — sortedKeys+pretty, round-trips) и `markdown()` (дела с окнами, транскрипция
  поканально, пустые каналы не печатаются). `suggestedFilename()` + `hhmm()`. Даты дел форматируются
  ISO8601 (инъектируемо для тестов), строки времени интервалов — как из ядра. `JournalView.export()`
  собирает сырьё за период (`engine.intervals` + `observer.activities`/`observations`) и пишет через
  NSSavePanel; ошибка сохранения — в тулбар.
- **Тесты (+7, `JournalExportTests`):** маппинг дел+окон, транскрипция поканально (все каналы как в API,
  строки времени из ядра), детерминизм JSON + round-trip, секции/поканальные строки Markdown, пустой
  документ, `hhmm`, имя файла. Итого Swift — **94 зелёных**.

**Верификация:** `swift build` чисто (0 warnings); `swift test` — 94 зелёных; `install-debug.sh` →
`Chronica.app` запущен (PID), `otool` подтверждает реальный sherpa. Экспорт-логика покрыта юнит-тестами;
живой NSSavePanel в headless не гонялся.

## Раунд стабильности: SIGABRT на коротком ASR-чанке — 2026-08-03

### Доказательства и причина

- В crash reports за **19 июня, 21 июня, 8 июля и 31 июля** повторяется один сценарий: процесс `tc-asr` завершается по **SIGABRT** (последний отчёт — примерно через 22 минуты после запуска), внутри ONNX Runtime фиксируется `ConvInteger` с недопустимой формой входа `{0,128}` и foreign/C++ exception.
- Это не OOM/jetsam: завершение инициирует нативное исключение ASR, а не memory-pressure termination; в отчётах нет признаков `EXC_RESOURCE`/jetsam.
- Корень — короткий ненулевой хвост после VAD/разреза интервала. Для него feature extractor Parakeet мог получить нулевую временную ось, после чего ORT abort'ил за границей Rust unwind. `catch_unwind` такой foreign exception не перехватывает. Дополнительный входной риск — нулевые `sample_rate`/`channels` от захвата, способные попасть в ресемплер.

### Исправления

**Rust-ядро:**

- Введён единый контракт `MIN_ASR_AUDIO_SAMPLES = 3_200` (16 кГц, 200 мс): короткие ненулевые хвосты отбрасываются до native ASR и не считаются backend failure; добавлены проверки finite/минимальной длины перед Sherpa, whisper.cpp и CoreML.
- `push_audio_frame` и ресемплер отклоняют `sample_rate == 0`/`channels == 0`, исключая деление на ноль и неоднозначное «нулевое число каналов = mono».
- В `TranscribeStats` короткие чанки учитываются отдельно (`skipped_chunks`), при этом пустая строка канала сохраняется в interval/store, а ложные backend-error/voice-activity события не создаются.
- Добавлены boundary-тесты для короткого/граничного/неfinite аудио, хвоста после полного чанка, мультиканального commit и неверных метаданных; тесты native input contract не требуют весов.

**Swift audio/Engine:**

- `CaptureManager` делает rollback уже запущенных источников в обратном порядке, очищает частичный старт и делает повторные `start`/`stop` идемпотентными.
- `ScreenCaptureSource` получил bounded async setup с отменой, защищённым результатом гонки и отказом при отсутствии потока; `Engine` удерживает start/stop tasks, поколения lifecycle и ждёт завершения старого Rust stop перед retry/model restart, чтобы stale completion не остановил свежую сессию.
- Новые `AudioLifecycleTests` покрывают rollback/retry, ошибки захвата, stop во время старта/ожидания и bounded SCK setup без TCC/устройства.

**Screen/Vision lifecycle:**

- `ScreenObserver` проверяет поколение и cancellation после каждого SCK/Vision await и перед изменением `status`, `lastObservation`, `todayActivities`, hash/context и SQLite; ownership дорогого тика теперь generation-scoped, поэтому свежий запуск не блокируется старым cancellation-игнорирующим await, а старый `defer` не очищает ownership нового поколения. Неверный период зажимается до безопасного диапазона, `stop` идемпотентен.
- `OllamaDescriber` получил транспортный seam, явный bounded timeout/cancellation race и degradation: при недоступной VLM app/title-наблюдение всё равно сохраняется. Production timeout оставлен 120 с; тесты подставляют короткие значения.
- Новые поведенческие/конкурентные `ScreenObserverLifecycleTests` и `VisionDescriberTests` проверяют stale stop→restart, overlap только между разными поколениями, игнорирование stale result, timeout/cancel и backend degradation без Screen Recording/Ollama.

### Верификация и остаток риска

- `cargo fetch` завершился успешно. `cargo test` — **94 unit-теста + 2 e2e зелёных**; full-feature `cargo check` для реального ядра (`store,api,download,sherpa,whispercpp,ffi`) — зелёный. `cargo clippy -D warnings`, `cargo fmt --all -- --check` и `git diff --check` — чистые.
- Реальный ignored-регрессионный тест Parakeet на коротком ненулевом чанке — **1 passed за 4.56 с**. Memory soak `15×1 с` — **1 passed за 7.31 с**: `iter5→end growth = 0 МБ`, floor/peak/end RSS = **2202/2217/2217 МБ**.
- `swift build` чисто; `swift test` — **109/109 зелёных** (включая новые audio/screen/vision lifecycle tests). Канонический `/Applications/Chronica.app` установлен и запущен одним PID; хеш совпадает с `dist`, `codesign`/`otool` зелёные, старый backup-путь сохранён.
- Наблюдение idle-приложения составило около 12 минут (из них 3 минуты сэмплировались отдельно): процесс оставался жив, новых crash reports не появилось.
- Остаточный риск честно ограничен ручной проверкой: автоматический live-soak записи микрофона и системного звука длительностью **15+ минут** не выполнялся из-за UI/TCC; пользовательский live-прогон всё ещё желателен.

## Раунд скрытого зависания записи и финальная интеграционная проверка — 2026-08-04

### Доказательства 20-часового зависания

- Процесс `Transcriber` с PID **63473** жил более **22 часов**. В SQLite/WAL состояние было фактически заморожено: последняя `voice_event` — **19:28**, после неё свежих голосовых событий не появлялось; в сэмпле процесса не было рабочих потоков `tc-*` (`tc-dsp`/`tc-asr`/`tc-tick`), хотя UI мог показывать запись.
- За зависший период записано **1 104** коротких интервала длительностью примерно **0,9–1,3 с**; отдельно видны гигантские интервалы **427 с** и **7593 с**. Потерянный хвост аудио оценён примерно в **424 с**.

### Причинная цепочка

Старый таймер тишины был сокращён до 1 с и начал быстро ставить задания; ASR-очередь насыщалась, после чего блокирующая отправка DSP и неограниченный drain приводили к потере аудио, остановке рабочих потоков и устаревшему UI без явного сигнала ошибки.

### Исправления

**Ядро:** исправлен инвариант границ интервала; drain ограничен; для ASR-очереди используется `try_send` с учётом дропа и rate-limit предупреждений; backlog отбрасывается при остановке; добавлен DSP heartbeat и событие `Error` + `StateError` при отключении рабочего потока.

**macOS/Apple:** введены generation-токены для lifecycle, Listener, capture failure и аудиосинков; watchdog использует monotonic heartbeat и sustained queue-saturation deadline, останавливает захват без скрытой записи; transient overload остаётся recoverable warning; `activityRevision`, reset/age live-feed и обновление графиков работают по сессионным событиям; relaunch явный, подтверждённый и idempotent; ошибки захвата доходят до Engine.

### Верификация и остаток риска

- Core: **104/104** теста; full-feature check и clippy зелёные. Реальный короткий tail-регрессионный тест Parakeet пройден.
- Apple: **120/120** тестов, `swift build` чистый (0 warnings). Memory soak **15×1 с**: RSS **2622 МБ**, рост **0 МБ**. Реальный install-debug: хеш **49c…** совпал между `apple/dist` и каноническим `/Applications/Chronica.app`; `codesign` и `otool` подтверждают корректный bundle/динамические зависимости; единственный PID **95895** наблюдался 3 минуты без падения.
- `git diff --check` чистый. Коммит и push намеренно приостановлены до отдельного разрешения на очистку истории.
- Честный остаток: автоматический 20-часовой live-soak с реальным микрофоном и системным звуком не выполнялся. Нативный hard hang остаётся некancellable, но watchdog и подтверждённый relaunch ограничивают его последствия. У ProcessTap нет API асинхронной invalidation; в этом случае действует watchdog.

## Раунд панели меню-бара: toggle/reducer и SwiftUI performance — 2026-08-09

### Поведение панели

- Переключение панели переведено на явный reducer состояний `closed → opening → open → closing → closed` с generation-токеном. Устаревшие callbacks анимаций не могут повторно открыть или закрыть более новое поколение.
- Иконка статус-бара активна уже в состояниях `opening`/`open` и выключается сразу при `closing`. Второй клик по той же иконке обрабатывается как единый toggle и не оставляет панель или generation в промежуточном состоянии.
- Все пути закрытия сведены к одному reducer: второй клик, внешний клик (с исключением клика по самому статус-бару), Escape, смена экрана/Space и потеря key-фокуса. Повторные close-запросы идемпотентны.
- Скрытая ветка `PopoverView` теперь лёгкая: она наблюдает только `PanelVisibilityModel`; тяжёлый `Engine`-содержащий контент монтируется на следующем тике после показа и удаляется при скрытии.

### Устранение причин лагов

- `DayActivity` выполняет SQLite/FFI-запрос интервалов асинхронно. Обновление запускается только по commit-only `intervalRevision`, отменяется при новом поколении/скрытии, схлопывает дубли и использует кэш снимка. Запрос не удерживает lock аудиопути `CoreBox`.
- Размер весов модели вычисляется фоновым обходом и читается из кэша; `View.body`/`.help` больше не запускают рекурсивное сканирование каталога.
- Live-лента ограничена числом строк для компактной панели, строится через `LazyVStack`; ISO/time форматтеры переиспользуются вместо создания `DateFormatter` на каждую строку.
- Скрипты install/package очищают dev-rpath перед подписью после того, как XProtect блокировал прежний запуск; в релизный bundle попадают только канонические пути загрузки.

### Верификация

- Реальный ASR `install-debug.sh` — **PASS**; `swift test` — **132/132**; `codesign` — **PASS**. Канонический хеш установленного приложения совпадает с `dist`: **de6fdc1c…**.
- `LC_RPATH` содержит только `/usr/lib/swift`, `@loader_path` и `@executable_path/../Frameworks`; `otool` подтверждает sherpa/ONNX зависимости.
- В скрытом состоянии runtime наблюдались **CPU 0.0%**, RSS около **54 МБ**. В трёхсекундном sample main thread **2388/2388** раз был заблокирован в event loop, без SwiftUI layout; до исправлений было около **107% CPU** и **3053/3053** выборок в SwiftUI layout.
- Автоматизация кликов через Accessibility недоступна (ошибка **-10827**). Поведение закрыто reducer-тестами и cross-review; ручное подтверждение toggle/закрытия пользователем остаётся желательным.

## Раунд подготовки публичного релиза macOS — 2026-09-03 (тех-лид + Opus-субагенты)

Цель владельца: публичный релиз именно macOS-приложения — минимализм без «мусора» в UI, стабильность,
низкая нагрузка на RAM/CPU/диск, «быстро получить что надо», понятное API для разработчиков.
Метод: три read-only аудита (ядро, приложение, готовность к релизу) → волны кодирования по
непересекающимся файлам (A1 lifecycle · A2 упаковка/подпись/CI · C1 пайплайн/VAD/реестр ·
C2 хранилище/API v1/CLI в отдельном worktree · C3 retention+FFI · A3 UI · A4 связка с новым FFI ·
D документация · P полировка) → гейты fmt/clippy/cargo test/swift test → реальная установка.

### Найдено и исправлено (блокеры релиза)
- **Хвост записи терялся при «Стоп»** (регрессия незакоммиченного раунда 2026-08-04): `stop` выставлялся
  до сброса хвоста, ASR-воркер выходил по флагу. Теперь очередь `AsrMsg{Interval,Tail,Finish}`: штатная
  остановка дорабатывает backlog и хвост; отброс — только по `abort` после `STOP_DEADLINE` 60 с с одним
  событием Error. e2e `pushes_audio_and_commits_interval_via_flush` снова зелёный без правок теста.
- **Дрейф таймлайна ~1 с на каждый рез по тишине** (`check_cut` брал `mono_now` вместо момента реза):
  за день до 15–20 мин расхождения и застрявшее в буфере аудио. Исправлено; 3 теста падают на откате.
- **Silero VAD никогда не включался** (путь только из env `TC_SILERO_VAD`): всегда работал RMS, слайдер
  «порог речи» был пустышкой. Теперь `silero-vad` в реестре (csukuangfj/vad, 1.8 МБ, sha256), путь по
  конвенции `<models>/silero-vad/silero_vad.onnx`, докачивается с любой ASR-моделью, скрыт из списка
  моделей; без файла — RMS + одно предупреждение на сессию. Проверено с реальными весами (ignored-тест).
- **Прогресс скачивания модели не доходил до UI в простое** (guard по поколению глушил
  `.modelProgress`) — первый запуск шёл «вслепую». Guard перенесён внутрь сессионных событий.
- **Entitlements отсутствовали**: под Hardened Runtime микрофон молча отказывал бы. Добавлен
  `Chronica.entitlements` (`audio-input`), подпись inside-out без `--deep`, DMG, иконка, NOTICES.
- **sha256 моделей были пустыми** (проверка целостности мертва) — заполнены для Parakeet (4 файла),
  whisper large-v3-turbo(-q5_0), Silero. `n_threads` оставлен 4 по замеру (см. ниже).

### Ядро
- Схема БД v2 (`PRAGMA user_version`, миграции): `start_ms/end_ms/ts_ms` (epoch ms) вместо
  лексикографического сравнения ISO; FTS5 по `interval_texts` с откатом на LIKE; `query_intervals`
  одним JOIN (было N+1); `overview` с лимитом 1000 + `overview_range`; PRAGMA synchronous=NORMAL,
  journal_size_limit 8 МБ, busy_timeout; `retention_sweep_all`, `optimize`, `vacuum`, `info`.
- `CoreConfig.retention_days` (uniffi default 0 = всегда), чистка в тикере при старте и раз в сутки.
- HTTP API v1 (`core/src/api_v1.rs`): единый конверт `{ok,data|error}`, health/openapi без токена,
  intervals с keyset-пагинацией, `intervals/{id}`, transcript (text/md/json), search, activity,
  export (форма `JournalExport`), CORS только localhost, constant-time токен, отказ старта на
  не-loopback без токена, пул 3 потока; старые `/api/*` — вечные алиасы. `docs/API.md`, `docs/openapi.json`.
- CLI `transcriber-cli`: today/transcript/search/stats/export/db(info|vacuum|retention)/transcribe,
  `--json`, читает БД без приложения. `docs/DATA.md`.
- FFI аддитивно: `MetricsSnapshot.dropped_intervals`, `ensure_vad_model`, `search_intervals`,
  `intervals_overview_range`, `interval_by_id`, `store_maintenance`, `store_info` (+`StoreInfo`).
- Пайплайн: `catch_unwind` вокруг DSP, `StateChanged{Error}` при стале, error-path `start()` join'ит
  поднятые потоки, `load_model` освобождает старый бэкенд до создания нового и отказывает во время записи,
  медленный тик 200 мс для параметров/метрик (было 100 Гц), дебаунс пересоздания Silero, кольцо
  160 000 сэмплов (10 с) и `DSP_STALL_TIMEOUT` 3 с, ротация `core.log` 2 МБ.
- Замер RSS/RTF Parakeet (M4, chunk 30 с): threads 1/2/4 → пик 2.62/2.62/2.59 ГБ при загрузке,
  стационар 2.43/1.78/1.16 ГБ, RTF 0.235/0.124/0.088 → 4 потока лучше по всем осям.

### macOS-приложение
- Lifecycle: graceful quit (`terminateLater` до 5 с), relaunch с `createsNewApplicationInstance` и
  проверкой pid, `humanMessage(CoreError)` вместо дампов enum, разрешение микрофона без семафора на
  главном потоке, SCK-старт без 10-секундного фриза, переустановка tap при смене устройства, sleep/wake
  (захват снимается на сон, ре-арм после пробуждения, при провале — явный рестарт сессии),
  `captureMic/captureSystem` @Published + `sourceChangeHint`, ScreenObserver пропускает тик при
  простое/заблокированном экране и чистит ретеншн раз в сутки. Переименования Transcriber→Chronica
  в агрегатном устройстве/очередях/логах (bundle id, executable и папка данных — не тронуты).
- UI: popover без телеметрии (статус, таймер, тумблеры источников, активность 24 ч одним числом,
  live-лента, Старт/Стоп, одна строка проблемы `SessionHealth`), onboarding (`PopoverOnboarding`:
  скачать модель / открыть настройки микрофона / готов); контекстное меню только действия + «О Chronica»;
  окно — Журнал · Модели · Настройки; инженерные метрики — в окне «Диагностика» (Настройки →
  Дополнительно); график активности переехал в Журнал; Модели — плоский список (Parakeet + 5 whisper,
  остальные под спойлером); Настройки — Основные / Журнал экрана (частота picker, срок хранения) /
  Дополнительно (нарезка, VAD, Ollama, API с автогенерацией токена, срок хранения расшифровок,
  Диагностика). Дефолт vision-модели `qwen3-vl:2b` (Apache-2.0) вместо `qwen2.5vl:3b`
  (Qwen Research License). Удалены MiniBars (фейковый VU), CoverageBar, MetricView, GlassBackground,
  секция curl-примеров, Live- и Dashboard-разделы. Доступность: labels на иконочных кнопках,
  сплошной фон при Reduce Transparency. SemanticSearch: кэш переживает выгрузку модели, idle 60 с, top-200.
- Упаковка: `Chronica.entitlements`, `sign-notarize.sh` (inside-out, DMG, stapler, dry-run),
  `make-dmg.sh`, `make-icon.sh`/`AppIcon.icns`, Info.plist (честные TCC-строки от имени Chronica,
  CFBundleVersion=1, иконка, категория), `THIRD_PARTY_NOTICES.md` + копия в бандл, CI на всех ветках
  + job реального набора фич + packaging-lint, `release.yml` по тегу, issue-шаблон.

### Документация
README.md (EN, основной) + README.ru.md, docs/PRIVACY.md, docs/BUILD.md, docs/API.md, docs/DATA.md,
docs/openapi.json, CONTRIBUTING.md, SECURITY.md, публичный docs/ROADMAP.md; внутренние
PRODUCT_PLAN/PROJECT_MAP/plan-overview/старый ROADMAP → docs/archive/. CHANGELOG: [0.1.0] — 2026-09.

### Верификация
- Ядро: `cargo fmt --check`, `cargo clippy --all-targets -D warnings` — чисто; `cargo test` — **192/192**
  (170 lib + 15 cli + 7 e2e); `cargo check` полного набора фич (sherpa+whispercpp+ffi) и CI-набора
  (mock-asr+ffi) — зелёные. Реальный Silero прогнан ignored-тестом с настоящими весами (PASS).
- Приложение: `swift build` — 0 ошибок/0 предупреждений компилятора; `swift test` — **234/234**.
- `install-debug.sh` — **PASS**: ядро пересобрано, биндинги перегенерированы, `.app` собран, ad-hoc
  подпись с `Chronica.entitlements` (`audio-input` встроен), `codesign --verify --strict --deep` OK,
  `LC_RPATH` только `/usr/lib/swift`, `@loader_path`, `@executable_path/../Frameworks`; `otool -L`
  подтверждает sherpa/ONNX из `Contents/Frameworks`; иконка и `CFBundleVersion=1` в бандле.
- Установлено в `/Applications/Chronica.app` (хеш `1bbd6751…` совпадает с `dist`; прежняя сборка —
  `/Applications/Chronica.app.bak-20260903-0440`), запущено одним PID; в простое **RSS 57–64 МБ,
  CPU 0.0%**, новых crash-репортов нет, `core.log` — только маркер старта сессии.
- `git diff --check`: единственные замечания — trailing whitespace в СГЕНЕРИРОВАННЫХ
  `transcriber_core.swift`/`transcriber_coreFFI.h` (артефакт uniffi-bindgen, не правится руками).
- Не выполнялось: живая запись с микрофоном/системным звуком (UI/TCC — владельцем), реальная подпись
  Developer ID/нотаризация (нет ключей), проверка журнала экрана (в локальном Ollama нет моделей).

### Честный остаток / решения владельца
- Реальная подпись Developer ID + нотаризация не прогонялись (нет ключей) — скрипты проверены dry-run.
- Bundle id / executable / папка данных — переименованы в следующем раунде (см. ниже).
- Локализация UI — выполнена в следующем раунде (см. ниже); Homebrew tap; Sparkle — позже.
- Живой soak 15+ мин с реальным микрофоном/системным звуком владельцем.
- Скриншоты для README (`docs/screenshots/`), коммит бинарной иконки.

## Раунд переименования и локализации — 2026-09-03 (тех-лид + Opus-субагенты)

Решения владельца: bundle id `io.github.vadim170.chronica` (reverse-DNS по нику GitHub), процесс и
SwiftPM-таргет `Chronica`, папка данных `Application Support/Chronica`, CLI `chronica`; крейт
`transcriber-core` и FFI-имена остаются внутренними. Интерфейс — английский и русский по языку системы.
Окно «О Chronica» с авторством «Разработал Вадим Макаров».

### Переименование (A)
- `Package.swift`: пакет/продукт/таргет `Chronica`, `Sources/Chronica`, `Tests/ChronicaTests` (git mv).
- `Info.plist`: `CFBundleIdentifier io.github.vadim170.chronica`, `CFBundleExecutable Chronica`.
- Миграции (`Core/Migration.swift`): папка данных переносится один раз (`moveItem`, мгновенно на одном
  томе), при сбое — работа со старой папкой + понятная ошибка; настройки `pref.*` копируются из домена
  `app.transcriber.mac`; login item перерегистрируется, если автозапуск был включён. 17 тестов.
- Окно «О Chronica» (`Views/AboutView.swift`): иконка, версия и сборка, авторство (локализуемый ключ),
  ссылка на GitHub, MIT, «Сторонние компоненты» (NOTICES из бандла или GitHub), атрибуция Parakeet.
- Скриншоты владельца в `docs/screenshots/` подключены в README EN/RU.
- Доки/скрипты/CI: пути данных, `defaults delete io.github.vadim170.chronica`, `swift run Chronica`,
  `chronica today`.

### Ядро (B, C5)
- CLI `chronica` (`[[bin]]`), дефолт БД `Application Support/Chronica/store/transcriber.sqlite` с откатом
  на старый путь и предупреждением; `search` печатает фрагменты ~200 символов с выделением совпадения
  (ANSI только на tty), `--limit` 20; `stats` без границ — «всё время (с … по …)»; `today` — с датой.
- Реестр: размеры и sha256 всех 33 whisper-моделей из HF API (tree); `total_bytes` известен до
  скачивания (в UI исчезло «≈1 ГБ» у base/small); мёртвых id нет.
- `Store::search_hits` + `SearchHit{interval, channel_id, snippet}`; `/api/v1/search` аддитивно отдаёт
  `channel_id`/`snippet`; `docs/openapi.json` схема `SearchHit`.

### Локализация (C)
- `Localizable.xcstrings` — **261 ключ** (14 plural), en (source) + ru, все `translated`; SwiftPM 6.3 не
  компилирует `.xcstrings`, поэтому рядом закоммичены продукты `xcstringstool compile` (`en.lproj`,
  `ru.lproj`), тест сверяет их с каталогом. Хелпер `L(...)` через `Bundle.strings` (сначала
  `Contents/Resources/Chronica_Chronica.bundle`, затем `Bundle.module` для `swift build/test`).
- `InfoPlist.strings` en/ru (TCC-строки, имя, копирайт); `CFBundleDevelopmentRegion=en`,
  `CFBundleLocalizations=[en,ru]`. Скрипты кладут бандл строк и `*.lproj` в `Contents/Resources`.
- Найдено и исправлено: плюрализация брала формы из региона (`Locale.current`), а не языка интерфейса —
  добавлен `Bundle.stringsLocale`; `%d` печатал код ошибки с разделителем разрядов.
- UX по скриншотам владельца: «0 сл» при пустых данных скрыто; fallback размера модели —
  «размер уточняется» вместо «≈1 ГБ». Тесты прогнаны в en и ru — зелёные в обеих локалях.

### Гигиена тестов (R3)
- Факт раунда: `swift test` создавал `Engine` с реальным `Application Support` и выполнил боевую миграцию —
  папка владельца `Transcriber` → `Chronica` переименована во время прогона тестов. Данные целы; запущенное
  старое приложение продолжало запись и транскрипцию по открытым дескрипторам (WAL обновлялся).
- Исправлено: `Engine.init(dataRoot:prefs:)` — тесты передают временный каталог и изолированные
  `Prefs(defaults:migrate:)`; миграция только в `Engine.productionDataRoot()`; защитные тесты
  `EngineDataIsolationTests` (реальный AS не меняется, явный корень используется без миграции).

### Верификация
- Ядро: fmt/clippy чисто; `cargo test` — **202/202** (174 lib + 21 cli + 7 e2e); `cargo check` полного и
  CI-набора фич — OK; `chronica db info|stats|search|today` на реальной базе владельца (21 787 интервалов,
  схема v2, FTS5) — работает, фрагменты и подписи периода корректны.
- Приложение: `swift build` без предупреждений; `swift test` — **271/271** (в обеих локалях).
- `package-app.sh` (release) — **PASS**: `apple/dist/Chronica.app` 69 МБ, `CFBundleIdentifier
  io.github.vadim170.chronica`, `CFBundleExecutable Chronica`, `CFBundleLocalizations [en, ru]`, в
  `Contents/Resources` — `AppIcon.icns`, `Chronica_Chronica.bundle` (en/ru), `en.lproj`, `ru.lproj`,
  `LICENSE`, `THIRD_PARTY_NOTICES.md`; `Frameworks` — sherpa/ONNX; `LC_RPATH` только штатные; ad-hoc
  подпись с entitlements — `valid on disk`, `satisfies its Designated Requirement`.
- Не выполнялось: установка и запуск новой сборки — старое приложение (`app.transcriber.mac`, PID 66262)
  в момент гейта активно записывало; чтобы не прервать запись владельца и не поднять второй захват,
  установка отложена (инструкция — в отчёте владельцу).

### Остаток
- Старая запись login item «Transcriber» и разрешения TCC для нового bundle id — выдать заново.
- Markdown-экспорт ядра (API/CLI) — заголовки на русском; локализация экспорта по языку — позже.

## Раунд подсветки иконки меню-бара — 2026-09-03 (жалоба владельца)

**Симптом:** при клике иконка в меню-баре мигала дважды — «активируется, деактивируется, снова
активируется, и открывается панель»; у нативных приложений подсветка включается один раз и держится
до закрытия.

**Механика (подтверждена зондом на живом `NSStatusItem` со свизлом `setHighlighted:`):** action
статусной кнопки висит на mouseUp (`sendAction(on: [.leftMouseUp, .rightMouseUp])`), а AppKit гасит
`isHighlighted` сам — не на mouseUp, а СРАЗУ ПОСЛЕ возврата из action. Наш `highlight(true)` внутри
`applyPanelEvent` затирался, и подсветка возвращалась только на следующем принятом переходе
(`openingFinished`) — после fade-in 0.12 с и хопа main-очереди. Итого ~130 мс тёмной иконки.

**Отвергнутые варианты (проверены зондом):** `sendAction(on: .leftMouseDown)` у `NSStatusBarButton` не
добавляет вызов на нажатии, а ЗАМЕНЯЕТ им вызов на отпускании — toggle уехал бы на mouseDown, прямо в
hazard, от которого стоит `suppressNextResign`; `setButtonType(.pushOnPushOff)` + `state` не годится —
`NSStatusBarButtonCell` сам переключает `state` на каждом клике; монитор событий вызывается до
диспатча, то есть до сброса AppKit.

**Решение:** подсветка стала чистой производной трёх причин — `StatusHighlightState{isPressed,
panelPhase, isMenuOpen}` + `StatusHighlightReducer` (AppDelegate.swift:100-155). О нажатии модель
узнаёт из локального монитора `[.leftMouseDown, .rightMouseDown]` по кадру окна статусной кнопки
(монитор ничего не решает и не съедает событие); `clickResolved` отправляется ПОСЛЕ маршрутизации
клика; сразу после клика значение пере-выставляется шагом main-очереди (после сброса AppKit, до
кадра). Контекстное меню держит подсветку через `NSMenuDelegate.menuDidClose`. «Залипшее» нажатие
(отпустили мимо иконки — action не приходит) снимается по `NSEvent.pressedMouseButtons`.
Решение toggle осталось на mouseUp; generation-токены `PanelStateReducer`, защита от
`windowDidResignKey`, `⌘Q`-монитор и graceful quit не тронуты.

**Верификация:** `swift build` без предупреждений; `swift test` — **279/279** (+8 тестов на
последовательность подсветки: нет провала между нажатием и открытием; ровно один `on` и один `off` за
цикл клик-открыть/клик-закрыть; клик снаружи/Escape/resign гасят один раз; правый клик активен, пока
висит меню; устаревшие поколения подсветку не трогают). Релизный `.app` пересобран и ad-hoc подписан.
Синтетический клик для сквозной проверки недоступен (терминалу не выдан Accessibility, `AXIsProcessTrusted
== false`), поэтому визуальное подтверждение — за владельцем: левый клик, второй клик, клик снаружи,
Escape, правый клик, а также «нажать и отпустить мимо иконки».

## Раунд CLI и инциденты установки — 2026-09-03

### Баг сборки CLI (найден при живой проверке)
`build-core.sh` собирал ядро без ограничения таргетов, поэтому вместе с библиотекой пересобирался и
`[[bin]] chronica` с ML-набором фич: бинарь получал `@rpath/libonnxruntime*.dylib` и
`@rpath/libsherpa-onnx-c-api.dylib` при полном отсутствии `LC_RPATH` и падал на старте
(«Library not loaded … no LC_RPATH's found»). То есть после каждой штатной сборки приложения CLI,
обещанный в документации, был неработоспособен.

**Исправлено:** `build-core.sh` собирает `--lib` (артефакты `.a`/`.dylib`/`.rlib` даёт
`crate-type = ["lib","staticlib","cdylib"]`; биндинги из такого `.dylib` совпали байт-в-байт);
штатная сборка CLI — `cargo build --release --bin chronica --no-default-features --features store`
(2.2 МБ, `otool -L` без onnx/sherpa/whisper). Команда `transcribe` в ML-free сборке скрыта из help и
даёт понятную ошибку с командой пересборки. В CI-job `packaging & versions` добавлена проверка
линковки (через `if … exit 1`, а не `! … | grep` — под `set -e` отрицаемый конвейер шаг не валит) и
запуск `--help`. Документация: `docs/BUILD.md` §3.1, `docs/DATA.md`, оба README.

### Инцидент 1: два экземпляра приложения
При установке новой сборки проверка «запущено ли приложение» была написана так, что не прерывала
выполнение (`pgrep … || echo`), и бандл в `/Applications` был заменён, а второй экземпляр запущен,
пока работал экземпляр владельца из `apple/dist` (PID 94741, шла запись). Около 40 секунд жили два
процесса с одним bundle id. Лишний экземпляр снят; резервная копия — `/Applications/
Chronica.app.bak-20260903-1455`. **Проверка последствий:** интервалы за окно 14:50–14:56 идут строго
последовательно, без перекрытий и дублей — второй экземпляр запись не начинал, база не пострадала,
crash-репортов нет. Вывод на будущее: перед заменой бандла проверка должна ЖЁСТКО прерывать
установку (`pgrep -x Chronica && exit 1`), а не логировать.

### Инцидент 2: пропавший кеш sherpa-onnx
У владельца `install-debug.sh` упал на линковке ядра: `ld: library 'onnxruntime.1.17.1' not found`,
`search path ~/Library/Caches/sherpa-rs/... not found`. Причина не в коде: каталог кеша
предсобранных бинарников sherpa-onnx/ONNX Runtime исчез — на системном диске оставалось ~14 ГБ, а
`~/Library/Caches` macOS освобождает как purgeable. Лечение: `cargo clean -p sherpa-rs-sys` + сборка
(фича `download-binaries` качает заново, ~30 с). Восстановлено; `apple/lib` собран заново, проверено
`nm`: 0 mock-символов, 474 внешних символа sherpa/ONNX — линкуется реальный ASR. Полезно знать:
`core/target` занимает ~4.7 ГБ.

### Паника CLI при обрыве вывода
`chronica today | head` завершался паникой (`failed printing to stdout: Broken pipe`, код 101): Rust
глушит SIGPIPE, а `println!` на EPIPE паникует. Весь stdout переведён на обёртку с разбором
`io::Error`: EPIPE — тихий выход с кодом 0 (как у `cat`/`grep`), прочие ошибки записи — сообщение в
stderr и код 1 (раньше тоже была бы паника). Вариант с `SIGPIPE = SIG_DFL` отвергнут: он даёт код 141
и не лечит остальные ошибки записи. Коды прочих ошибок не изменились (неизвестная команда — 2,
отсутствующая база — 1).

### Верификация
Ядро: fmt/clippy чисто, `cargo test` — **203/203** (174 lib + 22 cli + 7 e2e); CLI на живой базе
(22 271 интервал, схема v2, FTS5) — `db info`, `stats`, `search`, `today`, `--json` работают, только
чтение; конвейеры (`| head`, `| head -c`) дают код 0 и пустой stderr; `otool -L` без ML-библиотек.
Приложение: `swift test` — **279/279**; `build-core.sh debug` и `package-app.sh` проходят.

## Раунд единой ленты журнала и лечения подсветки иконки — 2026-09-05

Две жалобы владельца: (1) «есть Activities и есть Transcription… я бы не разделял так. Всегда
показывал все + линии разделяющие в местах где выключали или включали транскрипцию или закрывали
приложение. Это и на мини меню по иконке и на экране окна» (плюс наблюдение «после обновления
приложения старые транскрипции не видны» — панель строила ленту только из событий в памяти);
(2) «мигание иконки всё ещё сохранилось… стало быстрее, но оно есть».

### Журнал сессий в ядре (схема v3)
Таблица `sessions(id, started_at, started_ms, ended_at, ended_ms, stop_reason)` + индекс по
`started_ms`; миграция по образцу v2 (шаг в транзакции + `PRAGMA user_version`), `SCHEMA_VERSION = 3`.
Пайплайн открывает сессию в `start()` и закрывает в `stop()` (`stop_reason='user'`) либо аварийно
(`'error'` — паника DSP, watchdog, abort); незакрытая строка = процесс убит, то есть «приложение
закрылось». Ошибки записи сессии не валят start/stop (пишутся в `diag`). Чтение: `sessions(from,to)`,
`last_sessions(limit)`, плюс `recent_intervals(limit)` (последние интервалы одним JOIN — панели нужен
хвост истории без выбора периода). FFI аддитивно: `query_sessions`, `recent_sessions`,
`recent_intervals`, тип `SessionRecord`. HTTP: `GET /api/v1/sessions` (+ `docs/openapi.json`,
`docs/API.md`). CLI: `chronica sessions`, в `db info` — счётчик сессий. Разделители в UI строятся по
ФАКТУ включения/выключения записи, а не по эвристике «пауза больше N секунд».

### Единая лента (приложение)
Сегмент «Дела | Транскрипция» убран; `ActivitiesView.swift` и `HistoryView.swift` удалены, из
`LiveFeed.swift` остался только `LiveTail`. Новое: `Views/JournalFeed.swift` — чистая логика
(`build(intervals:activities:sessions:now:)` → элементы `.day/.separator/.line/.activity`, тотальный
порядок «время ↓ → ранг ↓ → id ↓», где ранг ставит «Запись остановлена» над последней репликой, а
«Запись включена» под первой; схлопывание цепочек разделителей с приоритетом
`failed > appClosed > started > stopped`; `capped(limit:)` режет хвост и убирает повисший заголовок
дня; `mergedIntervals(stored:live:)` — история плюс живые события без дублей) и
`Views/JournalFeedView.swift` — сама лента. Панель меню-бара грузит `recentIntervalsAsync(50)` +
`recentSessionsAsync(10)` на utility-потоке с debounce 150 мс, отменой при скрытии и кэшем снимка,
поверх накладывает `liveFeed`; лимит 80 строк. Локализация: +6 ключей, −15 мёртвых, итого 252.
Убрано вместе с двухколоночным режимом: правая панель детали интервала и экспорт ОДНОГО интервала
(экспорт периода и копирование реплики остались).

### Подсветка иконки: почему прошлая правка не помогла и что сделано
Замер зондом (живой `NSStatusItem`, свизл `setHighlighted:`, синтетический клик с настоящим
tracking-циклом, хук `+[CATransaction commit]` как признак реального кадра): baseline — **581.8 мс**
суммарной экспозиции и **6060 тёмных CA-коммитов** на 12 кликов. Причина промаха прошлой правки:
`DispatchQueue.main.async { refreshStatusHighlight() }` встаёт в очередь ПОСЛЕ блока, который монтирует
тяжёлую SwiftUI-ветку панели (87–114 мс), поэтому восстановление приходило слишком поздно. Наблюдатель
run loop на `beforeWaiting` не видит коммитов, сделанных внутри вёрстки SwiftUI и
`NSAnimationContext`, — отсюда ложное впечатление, что провала нет.
Решение: `StatusHighlightPin` (AppDelegate.swift:157-234) — класс ОДНОГО объекта (ячейки статусной
кнопки) подменяется созданным в рантайме подклассом, который глушит `highlight(false)`, пока подсветка
нужна модели; снятие пина делается ДО собственного сброса, иначе иконка залипла бы. Плюс
`CFRunLoopPerformBlock(...commonModes)` вместо `main.async` — восстановление в том же проходе.
Приватные имена не используются (класс берётся у объекта, переопределяется публичный
`NSCell.highlight(_:withFrame:in:)`), приём тот же, что у KVO; при неудаче подмены деградация мягкая
(остаётся блок run loop). Результат замера: **0.00 мс и 0 тёмных коммитов**. Отвергнуты: свой слой
подсветки (AppKit всё равно подсвечивает на своём tracking, нативная подсветка — не плоский цвет),
`state`/`.pushOnPushOff` (фон не рисуется, ячейка сама дёргает `setNextState`), `statusItem.menu`
(ноль миганий по построению, но это переписывание всего lifecycle панели — вынесено в рекомендации).

### Верификация
Ядро: fmt/clippy чисто, `cargo test` — **218/218**. Приложение: `swift build` без предупреждений,
`swift test` — **299/299** (в том числе 5 новых тестов подсветки на ЖИВОМ `NSButton` с подачей
настоящего сброса AppKit; проверка мутацией: снятие пина роняет 7 ассертов) и 17 тестов `JournalFeed`.
Честный остаток: попиксельного подтверждения с экрана нет (у терминала нет TCC для screencapture и
синтетического клика), измерялись экспозиция модели и состояние ячейки на каждом коммите
CoreAnimation; визуальная проверка — за владельцем.
