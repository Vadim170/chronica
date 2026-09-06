# Transcriber → Продукт: план перехода на «ядро + нативная macOS-оболочка»

> Составлен 2026-06-18 по результатам проработки 5 направлений (архитектура ядра, macOS-оболочка и аудио, стратегия ASR-моделей, карта миграции функционала, UI/UX-дизайн).
> Базовый контекст — `PROJECT_MAP.md`. Этот документ описывает **целевой продукт**, который заменяет текущее Python/Flask веб-приложение.

---

## 0. Резюме и ключевые решения

Превращаем исследовательский Python/Flask-транскрайбер в продукт: **переиспользуемое нативное ядро** + **нативная macOS-оболочка** (иконка в строке меню, тёмный стильный UI, без web). Ядро в будущем переиспользуется в iOS и Android приложениях. Модели — только **whisper** и **parakeet**.

| Вопрос | Решение | Почему |
|--------|---------|--------|
| **Язык ядра** | **Rust** (cdylib/staticlib) | Безопасность realtime-конвейера, единственный зрелый путь биндингов сразу в Swift И Kotlin (UniFFI), прозрачная линковка C/C++ ASR-либ |
| **Биндинги** | **UniFFI** (основной) + тонкий C-ABI (zero-copy PCM, fallback) | Генерит идиоматичные Swift/Kotlin обёртки с типами, enum, async, колбэками; battle-tested (Firefox, BDK) |
| **ASR-рантайм** | **sherpa-onnx** (ONNX Runtime, Apache-2.0) — единый для whisper И parakeet | Снимает проблему «Parakeet = только Apple/CoreML», один формат моделей и один менеджер на 3 платформы |
| **Apple fast-path** | Опционально: FluidAudio CoreML (parakeet) + whisper.cpp+Metal — за тем же интерфейсом бэкенда | Максимальный RTF на Apple Silicon (ANE), но не основа ядра |
| **Дефолтная модель** | **Parakeet TDT 0.6b v3 int8** (мультиязычная, вкл. русский, ~640 MB) | Быстрее/точнее whisper-turbo для RU+EN, без дорогого перебора языков |
| **Fallback-модель** | **whisper large-v3-turbo q5/q8** (~550 MB) | Языки вне 25 EU, максимальная точность RU/смешанной речи |
| **VAD** | **Silero VAD** (встроен в sherpa-onnx, MIT) + RMS-страховка 0.008 | Точнее WebRTC, идёт в комплекте с рантаймом |
| **Хранилище** | **SQLite** (в ядре) вместо `intervals.jsonl` + `voice_activity.jsonl` | Запросы по диапазону дат, агрегаты `GROUP BY`, транзакции, одно хранилище |
| **Захват аудио** | **На стороне платформы** (push PCM в ядро) | Захват глубоко платформенный; ядро = чистый DSP+ASR конвейер |
| **macOS-каркас** | **AppKit `NSStatusItem` + SwiftUI-контент** (НЕ чистый `MenuBarExtra`) | Анимированная иконка записи, нормальные доп. окна, надёжный дисмисс popover |
| **Системный звук без BlackHole** | Core Audio **process taps** (14.4+) → **ScreenCaptureKit** (13–14.3) → BlackHole (ручной fallback) | Убирает внешнюю зависимость и ручную настройку пользователя |
| **Дистрибуция** | DMG + Developer ID + notarization + **Sparkle**; App Sandbox **OFF**, Hardened Runtime ON | Надёжность process taps, свобода с крупными моделями |
| **Мин. macOS** | **14.0** (рекомендуемо 14.4 ради process taps) | `@Observable`, зрелый `SMAppService`, нативный системный звук |
| **Что выбрасываем** | Flask/SocketIO, авторизация, HTTP-роуты, Voxtral/NeMo/Qwen, runtime-quantization, рудименты `*_old` | Не нужны нативному локальному продукту |

### Реконсиляция расхождений субагентов
- **Каркас macOS:** инженер рекомендовал `NSStatusItem`, дизайнер исходил из `MenuBarExtra`. → Берём **`NSStatusItem` + SwiftUI через `NSHostingView`** (контроль над анимированной иконкой и множеством окон важнее простоты). Весь UI-спек дизайнера применяется без изменений — меняется только способ хостинга.
- **Язык ядра:** карта миграции рассматривала Swift/CoreML, но это закрывало бы Android. → **Rust + sherpa-onnx** как кросс-платформенная основа; Swift/CoreML остаётся опциональным Apple-ускорителем.
- **VAD:** переход на sherpa-onnx делает **Silero** бесплатным выбором; WebRTC остаётся возможным лёгким fallback.

---

## 1. Целевая архитектура

```
┌──────────────── НАТИВНЫЕ ОБОЛОЧКИ (UI + захват аудио + разрешения + загрузка моделей) ────────────────┐
│   macOS (SwiftUI + AppKit)      │   iOS (SwiftUI) [потом]   │   Android (Compose) [потом]               │
│   AVAudioEngine + CoreAudio tap │   AVAudioSession          │   AudioRecord / Oboe                       │
└───────────────────────────────┬───────────────────────────┬───────────────────────────────────────────┘
                                 │  UniFFI (Swift)            │  UniFFI (Kotlin/JNI)
┌────────────────────────────────▼────────────────────────────▼──────────────────────────────────────────┐
│  transcriber-core  (Rust, staticlib/xcframework/.so)                                                     │
│  ┌─────────────┐  push_audio_frame(channel,pcm,sr)   ┌──────────────┐   ┌───────────────┐                │
│  │ Resampler   │ ─────────────────────────────────▶ │ Silero VAD   │─▶ │ IntervalCutter│                 │
│  │ →16k mono   │   (lock-free ring buffer per chan) │ + RMS        │   │ (min/max/sil) │                 │
│  └─────────────┘                                     └──────────────┘   └──────┬────────┘                │
│         events (RTF, lag, queue, interval, voice-activity, errors) ◀───────────│                         │
│  ┌──────────────────────────────────────────────────────────────────┐  bounded queue(64)                │
│  │ ASR layer (trait AsrBackend)                                      │◀────────┘                         │
│  │   • ParakeetSherpa (default)   • WhisperSherpa (fallback)          │                                   │
│  │   • [Apple] FluidAudio CoreML / whisper.cpp+Metal (опц. fast-path)│   LanguagePicker (whisper auto)    │
│  └──────────────────────────────────────────────────────────────────┘   GarbageFilter, TextCleaner      │
│  ┌──────────────┐   ┌──────────────────┐                                                                 │
│  │ SQLite store │   │ Config + Metrics │                                                                 │
│  └──────────────┘   └──────────────────┘                                                                 │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Граница:** ядро — чистый конвейер «PCM-кадры → события + интервалы + история». Оболочка владеет: захватом аудио, разрешениями (TCC), жизненным циклом/фоном, UI, **сетевой загрузкой моделей** (ядро лишь проверяет наличие/целостность файлов).

---

## 2. Ядро (transcriber-core, Rust)

### 2.1. Модули

| Модуль | В ядре | Источник в текущем коде |
|--------|--------|--------------------------|
| Resampler → 16k mono i16 | ✅ (заменить `np.interp` на качественный ресемплер) | `_to_mono_16k_i16` |
| VAD (Silero + RMS-страховка) | ✅ | `webrtcvad.Vad(1)` + RMS 0.008 |
| IntervalCutter (min 300 / max 600 / silence 2000ms, рез в центре паузы, sample-точный offset) | ✅ порт 1:1 | `IntervalCutCoordinator` |
| BG-очередь (64) + chunking 30с | ✅ | `_background_transcribe_worker`, `_TRANSCRIBE_CHUNK_S` |
| ASR trait + Parakeet/Whisper реализации | ✅ | `backends.py` (только whisper+parakeet) |
| LanguagePicker (скоринг ru/en, бонусы auto) — **только whisper** | ✅ порт 1:1 | `pick_best_candidate`, `score_text_for_lang` |
| GarbageFilter + TextCleaner | ✅ порт 1:1 | `GARBAGE_PATTERNS`, `clean_transcribed_text` |
| Persistence (SQLite) | ✅ (замена jsonl) | `IntervalWriter`, `VoiceActivityTracker` |
| Config (типизированный, валидация) | ✅ | `config.py` (без host/port/password) |
| Metrics + события (push ~1с) | ✅ | `MetricsStore`, фоновый SocketIO-эмиттер |
| Перечисление устройств | ❌ платформа | `list_input_devices` |
| Захват аудио | ❌ платформа | `AudioStreamWorker`/sounddevice |
| Сетевая загрузка моделей | ❌ платформа (ядро проверяет наличие) | `model_manager` (частично) |

### 2.2. Публичный API (UniFFI, псевдо-Rust)

```rust
pub struct CoreConfig {
    pub model: ModelSpec,            // Parakeet | Whisper + пути к файлам
    pub language: LanguageMode,      // Auto | Fixed("ru") | Candidates(["auto","ru","en"]) (whisper)
    pub min_interval_s: u32,         // 300
    pub max_interval_s: u32,         // 600
    pub silence_cut_ms: u32,         // 2000
    pub vad: VadConfig,              // Silero threshold + rms_fallback 0.008
    pub n_threads: u32,              // 6
    pub storage_path: String,        // даёт платформа (sandbox-aware)
}
pub struct ChannelSpec { pub id: String, pub label: String } // "mic","remote",...

pub enum CoreEvent {
    StateChanged(SessionState),
    IntervalCommitted(IntervalRecord),  // соответствует записи в SQLite
    Metrics(MetricsSnapshot),           // RTF, lag, queue, cpu/ram, per-source
    VoiceActivity { channel: String, at: String },
    Error { code: ErrorCode, message: String },
}
pub trait CoreEventListener: Send + Sync { fn on_event(&self, e: CoreEvent); }

impl TranscriberCore {
    pub fn new(cfg: CoreConfig, listener: Box<dyn CoreEventListener>) -> Result<Self, CoreError>;
    pub fn register_channel(&self, ch: ChannelSpec) -> Result<(), CoreError>;
    pub fn configure(&self, cfg: CoreConfig) -> Result<(), CoreError>;
    pub async fn load_model(&self) -> Result<(), CoreError>;       // прогресс через события
    pub fn start(&self) -> Result<(), CoreError>;
    pub fn push_audio_frame(&self, channel_id:&str, pcm:&[i16], sample_rate:u32, channels:u8); // горячий путь, не блокирует
    pub fn stop(&self) -> Result<(), CoreError>;                   // graceful flush (≥0.5с)
    // запросы для History/Dashboard:
    pub fn query_intervals(&self, from:&str, to:&str) -> Vec<IntervalRecord>;
    pub fn intervals_overview(&self) -> Vec<IntervalOverviewItem>;
    pub fn voice_activity(&self, kind: ActivityKind, from:&str, to:&str) -> Vec<ActivityBucket>;
    pub fn current_state(&self) -> MetricsSnapshot;
    // менеджмент моделей (статус/проверка; скачивание — на платформе):
    pub fn model_status(&self, id:&str) -> ModelStatus;
}
```

Swift-сторона (после UniFFI): `try await core.loadModel()`, в audio-tap `core.pushAudioFrame(channelId:"mic", pcm:buf, sampleRate:48000, channels:1)`.

### 2.3. Потоки и события
- `push_audio_frame` пишет в **lock-free ring buffer** (`rtrb`/`crossbeam`), не блокируется (realtime-контракт).
- DSP-поток: resample → VAD → cutter; ASR-поток(и) под `backend_lock` (модель не потокобезопасна).
- События → UniFFI callback → Swift `AsyncStream`/`@Observable` → UI на `@MainActor`. Метрики раз в ~1с (замена SocketIO-поллинга).

### 2.4. Хранилище (SQLite)
```
intervals(id, start_at, end_at, duration_s, mic_text, remote_text,
          mic_words, remote_words, mic_language, remote_language)   -- index(start_at)
voice_events(id, ts, source, date, hour)                            -- index(ts), index(source,date)
```
WAL-режим; ретеншн voice-activity 30 дней через `DELETE`; почасовые/посуточные агрегаты через `GROUP BY strftime(...)`. Экспорт в jsonl/CSV — как фича. Решает медленный полный скан текущего `_read_intervals` и O(n)-перезапись `voice_activity.jsonl`.

### 2.5. Сборка артефактов
- iOS/macOS: per-arch staticlib → **xcframework** (LTO `fat` + strip + `panic=abort` — критично для размера, практика UniFFI: 31MB→7MB). Universal (arm64 + x86_64) через `lipo`.
- Android (потом): `cargo-ndk` → `.so` (`arm64-v8a`, `x86_64`) → `jniLibs`.
- Линковка sherpa-onnx/ORT через `build.rs` (`cc`/`bindgen`), статически в один артефакт.

---

## 3. ASR-модели

### 3.1. Линейка и роли (RU+EN)
| Модель / рантайм | Диск | RAM | Языки | Прод-роль |
|---|---|---|---|---|
| **Parakeet TDT 0.6b v3 int8** (sherpa-onnx) | ~640 MB | ~1.2 GB | 25 EU вкл. **ru/uk** | **дефолт** RU+EN, авто-детект без перебора |
| Parakeet v3 (FluidAudio CoreML) | ~2.5 GB | — | те же | Apple fast-path (опц., ANE, экстремальный RTF) |
| **whisper large-v3-turbo q5/q8** | 547–830 MB | ~1.6–2 GB | мультиязык | **fallback**: языки вне 25 EU, макс. точность RU |
| whisper small q5 | ~190 MB | ~850 MB | мультиязык | лёгкий офлайн-минимум (опц. бандл) |

Дефолт прод — **Parakeet v3 int8 через sherpa-onnx**. `large-v3-turbo` — переключаемый fallback.

### 3.2. Менеджмент моделей
- **Ничего тяжёлого не бандлим.** Качаем по требованию в `~/Library/Application Support/<BundleID>/Models/` через `URLSession` (прогресс, пауза/возобновление, sha256-проверка, atomic tmp→rename).
- Источники: parakeet — k2-fsa `asr-models` releases (`sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`); whisper — `ggerganov/whisper.cpp` (GGML) или k2-fsa ONNX.
- `KNOWN_MODELS` расширить полями `url`, `sha256`, `runtime`, `platforms`. Пинить версии в манифесте.
- Опционально бандлить whisper-`small` q5 (~190 MB) как гарантированный офлайн-старт без сети.

### 3.3. Лицензии (для NOTICE / «О программе»)
- **Parakeet v3 веса — CC-BY-4.0**: коммерция OK, **обязательна атрибуция NVIDIA** → добавить в «О программе»/NOTICE.
- sherpa-onnx — Apache-2.0; ONNX Runtime — MIT; Silero VAD — MIT; whisper.cpp — MIT; веса whisper — MIT. Чисто для прода.

### 3.4. Замеры до фиксации (open questions)
- Реальный RTF parakeet-int8 на ORT (CPU/CoreML EP) на **самом слабом целевом Mac** — числа FluidAudio (M1 ~155×) к ORT неприменимы.
- A/B качества RU: parakeet v3 vs whisper-turbo на реальных `intervals.jsonl`-сценариях (диктовка/совещания/смешанная речь), пунктуация/регистр RU.
- Нужен ли низколатентный streaming (parakeet ONNX — non-streaming, «реалтайм» = simulated-streaming через VAD-нарезку, что совпадает с текущим interval-движком).

---

## 4. macOS-оболочка

### 4.1. Каркас и тип процесса
- **AppKit `NSStatusItem`** (через `NSApplicationDelegate`) + **SwiftUI-контент** в `NSHostingView`/`NSHostingController`.
- **Agent app:** `LSUIElement = YES` (нет иконки в Dock). Окна настроек при открытии: `NSApp.setActivationPolicy(.regular)` для фокуса, возврат в `.accessory`.
- Мин. таргет **macOS 14.0** (рекомендуемо 14.4).

### 4.2. Захват аудио (без BlackHole)
| Источник | Механизм |
|---|---|
| Микрофон | `AVAudioEngine` + `installTap` → `AVAudioConverter` → 16k/mono/i16 |
| Системный звук (14.4+) | **Core Audio process tap**: `CATapDescription` → `AudioHardwareCreateProcessTap` → aggregate device → `AudioDeviceIOProc` |
| Системный звук (13–14.3) | **ScreenCaptureKit**: `SCStream` c `capturesAudio=true`, `excludesCurrentProcessAudio=true` (иначе эхо!), видео 2×2 |
| Совместимость | **BlackHole** как ручной выбор устройства |

Абстракция `protocol SystemAudioSource` с реализациями `ProcessTapSource` / `ScreenCaptureSource` / `DeviceInputSource`. Микрофон **всегда отдельно** (AVAudioEngine), не микшировать в SCK (баги). Везде собственный ресемплинг — формат источника не гарантирован.

### 4.3. Связь с ядром
- Статическая universal `.a`/xcframework, заголовок через module map. Биндинги — **UniFFI** (Swift).
- Аудио-колбэки (realtime-очереди) → lock-free ring buffer → передача чанков в ядро.
- События ядра (FFI-callback) → `AsyncStream`/`@Observable` → SwiftUI, UI на `@MainActor`.

### 4.4. Разрешения / приватность
- Info.plist: `LSUIElement=YES`, `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion=14.0`.
- TCC: микрофон (`AVCaptureDevice.requestAccess`), системный звук (Screen Recording для SCK / System Audio Recording для tap). **Онбординг-экран** обязателен — объяснить, зачем «запись экрана».
- **Hardened Runtime ON, App Sandbox OFF** (надёжность process taps, крупные модели, Developer ID/DMG).

### 4.5. Дистрибуция
- Universal binary, подпись Developer ID Application (`--options runtime`), notarization (`notarytool` + `stapler`), все вложенные бинарники/Sparkle-helper'ы подписаны.
- **DMG + Sparkle** (appcast + EdDSA). MAS — опционально вторым каналом (тогда sandbox + вероятный отказ от process taps в пользу SCK).

### 4.6. Жизненный цикл
- Автозапуск: `SMAppService.mainApp.register()` + тумблер в Settings.
- Анимированная иконка записи в menu bar; аудио-колбэки только пишут в буфер; parakeet через ANE экономит CPU; метрики раз в 1с; корректное освобождение tap/aggregate device при стопе.

---

## 5. UI/UX (тёмный, стильный, функциональный)

### 5.1. Информационная архитектура (10 поверхностей)
- **L0 Menu bar иконка** (5 состояний) → **L1 Popover** (≈360×560) → **L2 окна**.
- Одно **главное окно** с сегментами **Live · История · Дашборд**; **Settings** — отдельное окно (⌘,) с 5 табами (General / Audio / Transcription / Models / about); опциональный **Floating Recording HUD**.
- Общий `@Observable` стейт между popover и окнами.

### 5.2. Menu bar иконка (база `waveform`, template image)
| Состояние | Вид | Анимация |
|---|---|---|
| Idle | `waveform` тонкий | — |
| Recording | `waveform` + красная точка | variableColor по RMS (≤10 Гц), точка мигает 1с |
| Processing | `waveform` пульс / micro-progress | мягкая пульсация |
| Error | `exclamationmark.triangle.fill` | разовый bounce |
| Paused | `waveform.slash` 40% | — |

Левый клик → popover; правый → контекст-меню (Старт/Стоп, Live, Settings, Quit).

### 5.3. Popover (Recording) — главная поверхность
```
┌──────────────────────────────────────────┐
│  ●REC  00:12:34            интервал 3/∞    │
│  ▁▂▄▆█▅▃▂  ▁▁▂▃▂▁    (mic teal)(rem amber)│
├──────────────────────────────────────────┤
│  ИСТОЧНИКИ                                 │
│  ◉ Микрофон   MacBook Mic       ru  ▁▃▅   │
│  ◉ Система    Core Audio tap    en  ▁▁▂   │
├──────────────────────────────────────────┤
│  LIVE                              ⛶ Окно │
│  12:31 mic …отправь ссылку на макет        │
│  12:31 rem  sure, I'll send it over        │
│  ⟳ обрабатываю интервал… (4 в очереди)     │
├──────────────────────────────────────────┤
│  RTF 0.4×  лаг 1.2s  CPU 38%  RAM 1.1G     │
├──────────────────────────────────────────┤
│         [ ■  Остановить запись ]           │
└──────────────────────────────────────────┘
```
**Критично:** из-за нарезки 5–10 мин фразы появляются не сразу → обязателен честный хвост «⟳ слушаю / тишина 0:04 / обрабатываю (N в очереди)», иначе UI кажется зависшим.

### 5.4. Главное окно — Live (две дорожки), История (master-detail + поиск + экспорт TXT/MD/JSON), Дашборд (KPI-карточки RTF/лаг/CPU/RAM + спарклайны, очередь n/64, график голосовой активности stacked bars mic/remote по часам/дням через Swift Charts). Settings: General (автозапуск, хоткей, тема), Audio (выбор устройств + live-метр + помощник BlackHole), Transcription (язык mic/remote, параметры интервалов), Models (Model Manager со скачиванием/прогрессом/активной моделью).

### 5.5. Дизайн-система (тёмная)
**Принцип:** «тихий инструмент мониторинга». Liquid Glass только на плавающих слоях (popover/HUD), контент-окна — матовые непрозрачные для читаемости длинного текста. Две дорожки — сквозная сущность: **mic = teal**, **remote = amber**.

| Токен | Назначение | Hex |
|---|---|---|
| `bg/base` | фон окон | `#1C1C1E` |
| `bg/sidebar` | сайдбары | `#161618` |
| `surface/1` | карточки | `#252528` |
| `surface/2` | hover/вложенные | `#2E2E32` |
| `surface/glass` | popover/HUD | `#1E1E20` @ glass |
| `stroke/hairline` | разделители | `#FFFFFF` @ 8% |
| `text/primary` | основной текст | `#F2F2F7` |
| `text/secondary` | подписи | `#9A9AA2` |
| `text/tertiary` | таймкоды/disabled | `#6C6C72` |
| `accent` | акцент | `#5E5CE6` (indigo) |
| `track/mic` | дорожка mic | `#32D6C6` (teal) |
| `track/remote` | дорожка remote | `#FFB340` (amber) |
| `sem/rec` | запись/critical | `#FF453A` |
| `sem/warning` | предупреждение | `#FF9F0A` |
| `sem/success` | успех/загружено | `#30D158` |
| `sem/processing` | обработка | `#64D2FF` |

**Типографика (SF Pro):** Title 17 Semibold; Headline 13 Semibold (секции, caps tracking +0.5); Body 13 Regular (транскрипция, line-height 1.4, max ~64em); Caption 11; **Метрики/таймкоды — SF Mono 12**; KPI-числа — SF Pro Display 28 Semibold.
**Spacing:** 4/8/12/16/20/24/32. **Радиусы:** контролы 8, карточки 10, плавающие 16, чипы 6. **Иконки:** SF Symbols 7 (variableColor для уровня звука/обработки, bounce для ошибок). Все анимации уважают **Reduce Motion**.
**Состояния:** Empty (приглушённый символ 48pt + заголовок + действие), Loading (скелетоны-shimmer / детерминированный бар скачивания), Error (инлайн-баннер + действие «Повторить»/«Как настроить BlackHole»).

### 5.6. Референсы
Superwhisper (live-waveform, floating HUD, «тихое» присутствие), Pindrop (нативный SwiftUI, streaming, выбор движка), Overwhisper (Parakeet v2/v3 через FluidAudio — наш стек), Fluid (<100ms ощущение отзывчивости). macOS 26 Tahoe Liquid Glass — только на плавающих слоях.

---

## 6. Карта миграции (сжатая)

| Текущее (Python) | → Куда | Примечание |
|---|---|---|
| sounddevice захват, ресемпл, 2 источника | оболочка (захват) + ядро (ресемпл) | нативный AVAudioEngine/tap; ресемпл качественный вместо `np.interp` |
| WebRTC VAD(1) + RMS 0.008 | ядро | заменить на Silero + RMS-страховка |
| IntervalCutCoordinator (300/600/2000) | ядро | порт 1:1 |
| BG-очередь 64 + chunk 30с | ядро | порт 1:1 |
| pick_best_candidate / скоринг ru-en | ядро (только whisper) | parakeet авто-детект → не нужен |
| GARBAGE_PATTERNS / clean_text | ядро | порт 1:1 |
| MetricsStore (RTF/лаг/CPU/RAM/очереди) | ядро (сбор) + оболочка (показ) | `server_error`→`engine_error` |
| intervals.jsonl + voice_activity.jsonl | ядро → **SQLite** | + ретеншн 30д, агрегаты |
| config.py (+миграция) | ядро (engine cfg) + оболочка (UserDefaults) | без host/port/password |
| model_manager | ядро (статус) + оболочка (скачивание UI) | только whisper+parakeet |
| **Flask/SocketIO/auth/HTTP/шаблоны** | **ВЫБРОСИТЬ** | нативный UI напрямую с ядром |
| **Voxtral/NeMo/Qwen бэкенды, 4/8bit quant** | **ВЫБРОСИТЬ** | только whisper+parakeet |
| **`*_old.py/js/html`, `combined/mic/remote.jsonl`** | **ВЫБРОСИТЬ** | рудименты |

**Технический долг к исправлению при переносе:** линейная интерполяция ресемплинга (aliasing); voice_activity полная перезапись на каждое событие; пер-фреймовые списки флагов (→ счётчики); `processing_history` deque(8000) избыточен; WAV через temp-файлы + subprocess для FluidAudio (→ in-process); мёртвый `import atexit`.

---

## 7. Дорожная карта (фазы)

### Фаза 0 — Решения и замеры (1–2 нед)
- Бенчмарк parakeet-int8 (sherpa-onnx ORT) vs FluidAudio CoreML на целевом Mac; A/B качества RU vs whisper-turbo на реальных интервалах.
- Юридический чек лицензий (CC-BY атрибуция, NOTICE).
- Скелет monorepo: `core/` (Rust) + `apple/` (Xcode) + позже `android/`. CI на сборку xcframework.
- Зафиксировать ABI: формат PCM (i16 interleaved), модель колбэков (UniFFI), потокобезопасность.

### Фаза 1 — Ядро MVP (Rust) (3–5 нед)
- cargo-проект, интеграция sherpa-onnx (FFI), ParakeetSherpa + WhisperSherpa.
- Конвейер: `push_audio_frame` → ring buffer → resample → Silero VAD → IntervalCutter → BG-очередь → ASR → SQLite → события.
- Порт логики из Python с **golden-тестами** (interval cutter, language picker, garbage filter — сверка с текущими выходами).
- UniFFI-экспорт; desktop CLI-харнесс для прогона ядра без UI (кормить WAV-файлами).

### Фаза 2 — Каркас macOS-оболочки (3–4 нед)
- `NSStatusItem` agent app, линковка ядра (xcframework), UniFFI Swift.
- Захват mic (AVAudioEngine) + системный звук (process tap 14.4+ / SCK fallback), прокачка PCM в ядро.
- Базовый popover (старт/стоп, источники, live-лента), события через AsyncStream, анимированная иконка.

### Фаза 3 — Полный UI (4–6 нед)
- Popover полный; главное окно Live (две дорожки) / История (поиск + экспорт) / Дашборд (Charts); Settings (5 табов); Model Manager (скачивание/прогресс/sha256).
- Дизайн-система (токены, типографика, состояния empty/loading/error), Reduce Motion.

### Фаза 4 — Прод-готовность (2–3 нед)
- Code signing + notarization + Sparkle; онбординг разрешений (TCC) + помощник BlackHole; `SMAppService` автозапуск; энергопрофиль; edge cases (нет устройства, модель не загружена, отвал tap).
- Бета-DMG.

### Фаза 5 — Кросс-платформа (позже)
- Android: `cargo-ndk`, Kotlin/UniFFI, AudioRecord/Oboe, Compose UI. iOS: переиспользование xcframework, AVAudioSession. Подтверждение переиспользуемости ядра.

---

## 8. Риски и open questions (сводно)

**Архитектура/ядро:** UniFFI не 1.0 (закрепить версию, держать C-ABI fallback); zero-copy `push_audio_frame` (иначе дропы); память долгих сессий (интервал до ~19 MB/канал — резать/стримить); диаризация/word-timings — влияет на схему `IntervalRecord` (решить).
**Модели:** RTF parakeet-int8 на ORT не измерен; RAM ~1.2 GB — риск на слабых устройствах (дефолтить на whisper-small по бюджету памяти); parakeet ONNX non-streaming (если нужен низколатентный live — отдельный streaming-трансдьюсер); качество пунктуации RU.
**macOS:** баги ScreenCaptureKit (`-3805`, обязательный видео-конфиг, конфликт с микрофоном); process taps в sandbox под вопросом (влияет на MAS); TCC-онбординг «зачем запись экрана»; эхо без `excludesCurrentProcessAudio`; размер моделей (только докачка); Sparkle+notarization подпись helper'ов.
**Продукт:** «системный звук» недоступен на iOS, ограничен на Android — дизайн «N каналов» это терпит, но выровнять ожидания заранее.

---

## 9. Стек (итог)

| Слой | Технология |
|---|---|
| Ядро | Rust, sherpa-onnx (ONNX Runtime), Silero VAD, SQLite, UniFFI |
| Apple fast-path (опц.) | FluidAudio CoreML, whisper.cpp + Metal |
| macOS UI | Swift, AppKit (`NSStatusItem`) + SwiftUI, Swift Charts, AVAudioEngine, ScreenCaptureKit / Core Audio taps, SMAppService, Sparkle |
| Модели | Parakeet TDT 0.6b v3 int8 (дефолт), whisper large-v3-turbo q5/q8 (fallback) |
| Дистрибуция | Developer ID, notarization, DMG, Sparkle |
| Будущее | Android (cargo-ndk, Kotlin, Compose), iOS (xcframework, SwiftUI) |

---

## 10. Источники
- Ядро/биндинги: [UniFFI](https://github.com/mozilla/uniffi-rs), [UniFFI async](https://mozilla.github.io/uniffi-rs/next/futures.html)
- ASR: [sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/index.html), [parakeet-tdt-0.6b-v3 (HF, CC-BY-4.0)](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [Silero VAD](https://github.com/snakers4/silero-vad)
- macOS аудио: [Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps), [AudioCap](https://github.com/insidegui/AudioCap), [SCK excludesCurrentProcessAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio)
- macOS оболочка: [NSStatusItem best practices](https://multi.app/blog/pushing-the-limits-nsstatusitem), [SMAppService](https://theevilbit.github.io/posts/smappservice/), [signing+notarization+Sparkle](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- UI-референсы: [Superwhisper](https://superwhisper.com/voice-to-text-mac), [Pindrop](https://github.com/watzon/pindrop), [Overwhisper](https://github.com/OverseedAI/overwhisper)
