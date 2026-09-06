# AGENTS.md — контекст и стандарты проекта Chronica (ранее Transcriber)

> Этот файл читают все агенты, работающие над проектом. Коротко: что за продукт,
> какие цели, как устроен репозиторий и каких стандартов держаться.
> **Перед работой загляни в `docs/STATUS.md`** — это живой чекпоинт текущего состояния.

---

## О проекте

**Chronica** — локальный **сборщик контекста работы**: непрерывная транскрипция речи
(микрофон + системный звук) + журнал «дел» с экрана (периодический скриншот → локальная
маленькая vision-LLM через Ollama → сессионизация в блоки дел; только macOS). Работает
**полностью on-device** (ни аудио, ни скриншоты не покидают устройство). Это прод-продукт,
не прототип. Пользовательские идентификаторы переименованы: bundle id
`io.github.vadim170.chronica`, исполняемый файл `Chronica`, данные в
`~/Library/Application Support/Chronica` (одноразовая миграция со старых имён —
`apple/Sources/Chronica/Core/Migration.swift`). Внутренние имена НЕ меняем: крейт
`transcriber-core`, FFI `transcriber_core`/`TranscriberCore`, файл базы
`transcriber.sqlite` — см. примечание в README.

- **Одно переиспользуемое ядро** (Rust) + нативные оболочки: **macOS** (рабочая), **Android**
  (собрана), **iOS** — в планах (то же ядро).
- **Модели — только whisper и parakeet.** Дефолт: **Parakeet TDT 0.6b v3 int8** (мультиязычный,
  русский+английский). Реальная транскрибация на macOS подтверждена (RU+EN, RTF ≈ 0.08).
- Движок **интервальный**: захват → ресемпл 16кГц моно → VAD → нарезка на интервалы
  (30с…5мин, регулируемо, рез в паузах тишины между словами) → ASR → SQLite → события.

## Цели

- Прод-качество и **низкое потребление ресурсов** (приоритет).
- **Одно ядро на все платформы**: вся логика (нарезка, VAD, хранение, события, конфиг,
  метрики, опциональный API) — в ядре; платформенные только захват аудио, ML-рантайм и UI.
- Стильный **тёмный glass-UI**; история с **семантическим поиском**; дашборд метрик;
  менеджер моделей (скачивание с HuggingFace); опциональный локальный HTTP API.

## Структура репозитория

```
/core      Rust-крейт `transcriber-core` — движок (переиспользуемый)
           types/errors/events/config (контракты) · lang · audio/{resample,ring} ·
           interval · vad(+vad_silero) · store(SQLite+FTS5) · metrics ·
           model_manager(HF) · api(tiny_http)+api_v1 · diag(паники и stderr в
           core.log) · pipeline(фасад TranscriberCore + DSP/ASR потоки) ·
           asr/{mod,mock,sherpa,coreml,whispercpp} · bin/{cli,uniffi-bindgen}.
           FFI — UniFFI (feature `ffi`).
           Фичи: default=[store,api,download,mock-asr]; sherpa, whispercpp, coreml,
           ffi, webrtc-vad. Прод-набор: store,api,download,sherpa,whispercpp,ffi.
/apple     macOS-приложение (SwiftUI + AppKit, agent в menu bar).
           Sources/Chronica (продукт `Chronica`) · Tests/ChronicaTests ·
           Sources/{TranscriberCore,transcriber_coreFFI} — СГЕНЕРИРОВАННЫЕ UniFFI.
           App/{main,AppDelegate(+PanelController),LoginItem} ·
           Core/{Engine(мост),ModelSelection,MemoryBreakdown,
           Migration(папка данных·UserDefaults·login item)} · Audio/* ·
           Design/{Theme,Components,Prefs} ·
           Screen/{ScreenObserver,VisionDescriber,ActivityStore,ScreenContext,
           JournalExport} — журнал дел с экрана ·
           Views/{PopoverView,RootView(3 раздела: Журнал·Модели·Настройки),
           MainWindowView(общие компоненты),JournalView,JournalFeed(чистая
           логика единой ленты),JournalFeedView,HistoryLogic,ModelsView,
           SettingsView(Основные·Журнал экрана·Дополнительно),
           DiagnosticsView(отдельное окно метрик),AboutView(окно «О Chronica»),
           SemanticSearch,LiveFeed}.
           Линкует ядро (.a + sherpa/ORT dylibs) через UniFFI Swift-биндинги.
           Resources/{Info.plist,Chronica.entitlements,AppIcon.icns} ·
           Scripts/{build-core,install-debug,package-app,sign-notarize,make-dmg,
           make-icon}.sh
/android   Kotlin + Jetpack Compose; тот же core через UniFFI Kotlin + cargo-ndk (.so).
           Экспериментальный: публичного релиза нет, в CI не собирается.
/docs      API.md (HTTP API v1) · DATA.md (схема БД, CLI, экспорт) ·
           PRIVACY.md (сеть, диск, TCC) · BUILD.md (сборка, подпись, гейты) ·
           ROADMAP.md (публичный) · openapi.json ·
           STATUS.md (живой чекпоинт — читать первым) ·
           archive/ (устаревшие внутренние документы: PRODUCT_PLAN, PROJECT_MAP,
           plan-overview.html, ROADMAP-2026-06 — НЕ отражают текущее состояние)
/scripts   check-versions.sh — три строки версии обязаны совпадать.
/.github   workflows/{ci,release}.yml
Корень      README.md (EN) · README.ru.md · CHANGELOG.md · CONTRIBUTING.md ·
           SECURITY.md · LICENSE (MIT) · THIRD_PARTY_NOTICES.md · AGENTS.md
```

Локально рядом могут лежать `/transcriber_webui_project` (старое python-приложение,
референс для портирования) и `/transcripts` (реальные записи). Оба в `.gitignore`
и **в публичный репозиторий не входят**.

## Стандарты (обязательно)

1. **Тесты — на ПОВЕДЕНИЕ/контракты, не на детали реализации.** Никаких хрупких тестов на
   приватные поля, точные строки логов или порядок вызовов. Тесты, требующие весов модели /
   устройства / нативной либы — помечать `#[ignore]` (Rust) / `@Ignore` (Kotlin) с пояснением.
2. **Документация — на русском.** Doc-комментарии (`//!`/`///`, KDoc) на публичных элементах;
   по каждому раунду обновлять `docs/STATUS.md`.
3. **Не коммитить без явной просьбы пользователя** — он стейджит сам. Изменения оставлять в
   working tree.
4. **Контракты ядра стабильны.** Не менять публичные сигнатуры/FFI-типы без необходимости;
   UI и Android кодят против них. Расширять — аддитивно.
5. **Реальный ASR (sherpa) не ломать.** Приложение собирается БЕЗ `mock-asr`
   (`--no-default-features --features store,api,download,sherpa,whispercpp,ffi`): для Parakeet
   всегда реальный движок, при сбое — честная ошибка, а не молчаливый mock.

## Модель работы (оркестрация)

- **Тех-лид** задаёт контракты/структуру и проверяет сборку+тесты как финальный гейт;
  **субагенты пишут код**. Лиды могут запускать своих субагентов по **непересекающимся файлам**.
- **Избегать гонок:** не редактировать одни и те же файлы и не пересобирать ядро параллельно.
  `core` и `apple`/`android` — разные директории; для параллельных cargo-сборок использовать
  отдельный `CARGO_TARGET_DIR`.

## Сборка и проверка

```bash
# Rust-ядро
. "$HOME/.cargo/env"
cd core && cargo test                      # дефолтные фичи
cargo check --features ffi,sherpa          # FFI + реальный ASR

# macOS (собирает ядро без mock + .app + ad-hoc подпись + запуск)
cd apple && ./Scripts/install-debug.sh     # перед: pkill -x Chronica
# гейт: swift build · swift test · otool -L .build/debug/Chronica | grep sherpa · pgrep -x Chronica

# Android
cd android && ./build-core.sh && ./gradlew assembleDebug
./gradlew testDebugUnitTest

# Релиз .app + распространение (нужны ключи Developer ID)
cd apple && ./Scripts/package-app.sh && ./Scripts/sign-notarize.sh
```

## Ключевые решения и подводные камни

- **ASR-рантаймы:** sherpa-onnx (Parakeet, кросс-платформенно) + whisper.cpp/ggml (Whisper,
  Metal на Apple). CoreML/FluidAudio — опциональный Apple fast-path. VAD — Silero (+RMS-страховка).
- **Захват аудио — на стороне платформы** (push PCM в ядро через `push_audio_frame`); ядро само
  ресемплит в 16кГц моно. macOS: микрофон (AVAudioEngine) + системный звук (Core Audio tap 14.4+ →
  ScreenCaptureKit → BlackHole). Android: AudioRecord (+ MediaProjection для системного, только медиа).
- **Hot-apply:** интервал (min/max), пауза тишины, порог VAD и язык применяются **на лету** во время
  записи (общий `RuntimeParams` под мьютексом, DSP/ASR перечитывают). **Модель — только перезапуском**
  сессии (кнопка «Применить»).
- **Дефолты конфига:** min_interval 30с (нижний предел 10), max 300с, silence 2000мс,
  audio_queue 48000 (запас против потерь сэмплов).
- **Хранилище:** SQLite (`~/Library/Application Support/Chronica/store/transcriber.sqlite`):
  таблицы `intervals`, `interval_texts`, `voice_events`. Времена — ISO-8601 с локальным смещением;
  границы запросов считать в той же локальной зоне (иначе лексикографическое сравнение в SQLite врёт).
- **macOS TCC:** репозиторий в `~/Documents` — хост-приложению (iTerm/Terminal/VS Code) нужен
  **Full Disk Access**, иначе `Operation not permitted` на чтение файлов.
- **Линковка:** варнинги `ld: object file ... built for newer 'macOS'` безвредны
  (`MACOSX_DEPLOYMENT_TARGET=14.0` в build-core.sh). sherpa/ONNX — динамические dylib (в
  `Contents/Frameworks`, rpath); whisper.cpp/ggml — статические `.a` в бинаре.

## Текущий статус (кратко; детали — `docs/STATUS.md`)

macOS-приложение доведено до публичного релиза 0.1.0: ядро транскрибирует реально
(Parakeet/sherpa-onnx, RU+EN), Silero VAD включён, база на схеме v2 с FTS5, есть
HTTP API v1 с OpenAPI и CLI `chronica`, журнал дел с экрана через Ollama
(выключен по умолчанию), окно сведено к трём разделам (Журнал · Модели ·
Настройки), настройки — к трём секциям (Основные · Журнал экрана ·
Дополнительно) с техническими метриками в отдельном окне «Диагностика»,
собрана обвязка дистрибуции — entitlements, подпись Developer ID,
нотаризация, DMG, иконка, релизный workflow по тегу — и публичная документация
(README EN/RU, PRIVACY, BUILD, API, DATA, CONTRIBUTING, SECURITY,
THIRD_PARTY_NOTICES). Android собирается на том же ядре, но остаётся
экспериментальным: публичного релиза нет, на устройстве не прогнан, в CI не
собирается. Честный остаток риска (длительные live-прогоны записи, ручные
проверки UI) — в `docs/STATUS.md`; ближайшие планы — в `docs/ROADMAP.md`.
