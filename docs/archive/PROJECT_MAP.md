# Карта проекта Transcriber — база знаний

> Документ собран 2026-06-18 по результатам полного разбора репозитория.
> Цель — зафиксировать, **что в проекте актуально, что устарело, что является рудиментом**,
> чтобы можно было продолжить развитие, не путаясь в двух поколениях кода.

---

## 1. Что это за проект

Локальный **двухпоточный транскрайбер речи** для macOS / Linux. Слушает одновременно
два аудио-источника и переводит речь в текст полностью **на стороне сервера** (Python),
без отправки аудио в облако:

- **`mic`** — микрофон;
- **`remote`** — системный звук (через виртуальное устройство **BlackHole** на macOS).

В репозитории сосуществуют **два поколения** проекта. Это главный источник путаницы,
поэтому начните с раздела 2.

---

## 2. Два слоя репозитория (САМОЕ ВАЖНОЕ)

```
transcriber/
├── app.py, app_dual_transcriber_v2.py        ← СЛОЙ 1: ранние CLI-скрипты   (РУДИМЕНТ)
├── app_dual_transcriber_gui.py, ..._gui_v2.py← СЛОЙ 1: ранние Tkinter-GUI    (РУДИМЕНТ)
├── dual_transcriber_webui_project.zip        ← снапшот init веб-версии       (РУДИМЕНТ)
├── README.md, requirements.txt               ← доки/зависимости СЛОЯ 1       (LEGACY)
├── transcripts/                              ← старые тестовые данные         (DATA)
│
└── transcriber_webui_project/                ← СЛОЙ 2: АКТУАЛЬНЫЙ ПРОДУКТ ✅
    └── ... (Flask + WebSocket веб-приложение)
```

| Слой | Что это | Статус | Развивать? |
|------|---------|--------|-----------|
| **Слой 1** — корневые `.py`, `README.md`, `requirements.txt`, `.zip` | Первые прототипы: CLI и Tkinter-десктоп, прямой `pywhispercpp` | 🟥 **Рудимент** | Нет, только как референс |
| **Слой 2** — `transcriber_webui_project/` | Веб-приложение с UI, метриками, несколькими ASR-бэкендами, git-историей | 🟩 **Актуальный** | **Да** |

**Вывод:** всё дальнейшее развитие идёт в `transcriber_webui_project/`. Корневые файлы
сохранены как история и для справки, но не используются актуальным кодом.

---

## 3. Хронология эволюции

### По датам файлов (Слой 1, прототипы)
Все созданы **17 марта 2026** в течение одного вечера — это исследовательские прототипы:

| Файл | Строк | Что это |
|------|------|---------|
| `app_dual_transcriber_v2.py` | 537 | CLI-версия, вариант с перезаписью `combined.jsonl` целиком |
| `app.py` | 530 | CLI-версия, вариант с отложенным flush одной «pending» фразы |
| `app_dual_transcriber_gui.py` | 981 | Tkinter-десктоп GUI, первая версия |
| `app_dual_transcriber_gui_v2.py` | 1286 | Tkinter-десктоп GUI, расширенная (метрики, psutil) |

> Разница между `app.py` и `app_dual_transcriber_v2.py` — только стратегия записи `combined.jsonl`
> (отложенный flush одной фразы vs полная перезапись файла). Это две экспериментальные ветки одной идеи.

### По git-истории (Слой 2, веб-проект)
Git только внутри `transcriber_webui_project/` (`github.com/Vadim170/transcriber_webui_project`):

| Дата | Коммит | Смысл |
|------|--------|-------|
| 2026-03-17 | `e1902ff` init | Первая веб-версия (= содержимое `.zip` в корне). **Utterance-движок** |
| 2026-03-19 | `961de1d` | config.json + опциональные бэкенды (Voxtral/Canary/Qwen) |
| 2026-03-20 | `f9eee00` | причёсывание кода |
| 2026-03-20 | **`2bec901`** | ⭐ **Смена движка: utterance → interval**. Ключевой архитектурный сдвиг |
| 2026-03-22 | `2474571` | API.md + эндпоинт получения транскрипций |
| 2026-03-31 | `9039a60` | UX-доработки |
| 2026-03-31 | `e6d1e64` | мелкие фиксы (**текущий HEAD**) |

**Признаки активности после git:** `config.json` — 21 апреля, `intervals.jsonl` дописывался
до **13 мая 2026**. То есть приложением пользовались минимум до середины мая, хотя код не коммитили после 31 марта.

---

## 4. Главный архитектурный переход: utterance → interval

Это нужно понимать, потому что **половина документации и часть кода описывают старый движок**.

### 4.1. Старый движок (utterance-based) — РУДИМЕНТ
- Резал речь на **отдельные фразы** по VAD (короткие паузы).
- Писал три файла: `mic.jsonl`, `remote.jsonl`, `combined.jsonl` — по одной записи `type:"utterance"` на фразу.
- Имел **архив полного аудио** (`FullAudioWriter`, ключи `full_audio_enabled/dir/retention_days`) — сохранял WAV по дням, ретеншн в сутках.
- Поддерживал скачивание аудио-клипов и **ретранскрибацию интервала** в History.

### 4.2. Новый движок (interval-based) — АКТУАЛЬНО ✅
- Накапливает аудио и режет на **крупные интервалы** (по умолчанию 5–10 мин) по длинным паузам тишины.
- Пишет **только** `intervals.jsonl` (одна запись `type:"interval"` с агрегированным `mic_text`/`remote_text`) + `voice_activity.jsonl` (статистика срабатываний).
- **Архив полного аудио удалён.** Миграция в `config.py` (`_OLD_KEYS_TO_REMOVE`) вычищает `full_audio_*` и старые VAD-ключи из конфига.
- Логика подробно и **корректно** описана в `transcriber_webui_project/TRANSCRIPTION_LOGIC.md`.

### 4.3. Последствия (важно при доработке)
- Файлы `transcripts/combined.jsonl`, `mic.jsonl`, `remote.jsonl` — это **старые данные** (Mar 20), новый движок их не создаёт.
- Эндпоинт **`GET /api/transcriptions` читает `combined.jsonl`**, которого для новых сессий нет → фактически **мёртвый** эндпоинт.
- `README.md` (внутри webui) и `API.md` описывают функции старого движка (полное аудио, ретранскрибация, utterance-формат), **которых в текущем коде нет**. См. раздел 8.

---

## 5. Архитектура актуального продукта (`transcriber_webui_project/`)

```
Устройство (mic / remote)
   │  sounddevice InputStream (блоки ~30 мс)
   ▼
AudioStreamWorker (поток на каждый источник)
   │  ресемплинг → 16 кГц / моно / int16
   │  WebRTC VAD (агрессивность 1) + RMS-фоллбэк (порог 0.008) каждые 30 мс
   │  накопление фреймов в буфер, отчёт о тишине
   ▼
IntervalCutCoordinator
   │  решает момент нарезки: тишина ≥2 с (после min) ИЛИ принудительно по max
   ▼
BG-очередь (64 слота)
   ▼
_background_transcribe_worker
   │  режет интервал на куски по 30 с
   │  вызывает ASR-бэкенд (для auto-языка — кандидаты auto/ru/en, выбор лучшего)
   ▼
intervals.jsonl   +   voice_activity.jsonl
   │
   ▼
Flask + Flask-SocketIO  →  каждую 1 с шлёт state_update / overview_update в браузер
```

- **Транскрипция полностью серверная.** Браузер только логинится, запускает/останавливает, опрашивает состояние.
- **Состояние в памяти процесса** (`TranscriberController`) → запускать строго в **одном** воркере (`gunicorn -w 1`).
- **Авторизация** — один пароль (сравнение `secrets.compare_digest`), сессия в cookie, rate-limit `10/min` на логин.

### 5.1. Карта файлов актуального проекта

| Файл | Строк | Статус | Назначение |
|------|------|--------|-----------|
| `run.py` | 14 | ✅ | Точка входа: `create_app()` + `socketio.run()` |
| `app/__init__.py` | 402 | ✅ | Flask-фабрика, все HTTP-роуты, SocketIO, фоновый эмиттер состояния |
| `app/transcriber.py` | 1026 | ✅ | **Ядро**: захват аудио, VAD, нарезка интервалов, фоновая транскрипция, метрики |
| `app/backends.py` | 543 | ✅ | Абстракция ASR-бэкендов + 5 реализаций + preflight + фабрика |
| `app/config.py` | 91 | ✅ | Загрузка/создание `config.json`, миграция старых ключей, список whisper-моделей |
| `app/model_manager.py` | 220 | ✅ | Статус/preload/удаление моделей, расчёт занятого места на диске |
| `app/voice_activity_tracker.py` | 241 | ✅ | Статистика голосовой активности (почасовая/посуточная), ретеншн 30 дней |
| `app/controller.py` | 7 | ✅ | Просто реэкспорт `TranscriberController` для обратной совместимости импортов |
| `app/templates/index.html` | 164 | ✅ | Главная страница (панель управления) |
| `app/templates/history.html` | 94 | ✅ | Страница истории |
| `app/templates/login.html` | 31 | ✅ | Страница входа |
| `app/static/app.js` | 744 | ✅ | Логика главной страницы |
| `app/static/history.js` | 668 | ✅ | Логика страницы истории |
| `app/static/app.css` | — | ✅ | Стили |
| `scripts/setup_macos.py` | — | ✅ | Установщик: venv, зависимости, опц. бэкенды, сборка FluidAudio CLI |
| `vendor/FluidAudio/` | — | ✅ (внешн.) | Swift-пакет FluidAudio для CoreML-бэкенда (не в git) |
| **`app/transcriber_old.py`** | 1540 | 🟥 **Рудимент** | Старый utterance-движок (`JsonlWriter`, `FullAudioWriter`). **Нигде не импортируется** |
| **`app/static/app_old.js`** | 401 | 🟥 **Рудимент** | Старый фронт главной. Не подключён ни одним шаблоном |
| **`app/static/history_old.js`** | 534 | 🟥 **Рудимент** | Старый фронт истории. Не подключён |
| **`app/templates/history_old.html`** | 116 | 🟥 **Рудимент** | Старый шаблон истории. Не рендерится ни одним роутом |
| `config.json` | — | ⚙️ DATA | Реальный конфиг с секретами (в `.gitignore`) |
| `config.json.example` | — | ✅ | Шаблон конфига |
| `transcripts/` | — | ⚙️ DATA | Выходные данные (см. 7) |
| `output/` | — | ⚙️ DATA | Случайно созданный `voice_activity.jsonl` (видимо, запуск из другого cwd) |

> **Проверено:** строки `transcriber_old`, `app_old`, `history_old` не встречаются ни в одном
> рабочем шаблоне/скрипте/роуте — это безопасно удаляемый мёртвый код (оставлен как бэкап старого движка).

---

## 6. ASR-бэкенды (`app/backends.py`)

Единый интерфейс `ASRBackend` (`load` + `transcribe_once`). Бэкенд выбирается по строке модели:

| Ключ бэкенда | Класс | Когда выбирается | Зависимости |
|--------------|-------|------------------|-------------|
| `macos_parakeet` | `MacOSParakeetBackend` | model id из `KNOWN_MODELS` (Parakeet CoreML) | macOS arm64, swift, `vendor/FluidAudio` |
| `whisper_cpp` | `WhisperCppBackend` | путь к `.bin` или имя не из `KNOWN_MODELS` (дефолт) | `pywhispercpp` (в requirements) |
| `voxtral` | `VoxtralBackend` | спец. model id | `torch transformers accelerate` |
| `nemo_asr` | `NemoASRBackend` | model id `nvidia/canary…`/parakeet | `torch nemo_toolkit[asr]` |
| `qwen_asr` | `QwenASRBackend` | спец. model id | `torch qwen-asr` |

- **Дефолтная модель** (config.py): `FluidInference/parakeet-tdt-0.6b-v3-coreml` (macOS fast path).
- `whisper_cpp` — единственный, поддерживающий **мультиязычные кандидаты** (`supports_multi_candidate`): при `language=auto` гоняет auto/ru/en и выбирает лучший по эвристике (`pick_best_candidate`, скоринг кириллица/латиница, фильтр «мусора» вроде `[BLANK_AUDIO]`).
- Квантование 4bit/8bit — только Voxtral/Qwen на CUDA/Linux через `bitsandbytes`.
- `KNOWN_MODELS` сейчас содержит **только** Parakeet CoreML; whisper-модели задаются списком в `config.py` (`WHISPER_CPP_MODELS`).

---

## 7. Данные и форматы

### Файлы в `transcripts/` (актуальный `out_dir`)

| Файл | Формат | Кто пишет | Статус |
|------|--------|-----------|--------|
| `intervals.jsonl` | `type:"interval"` (агрег. текст за интервал) | новый движок | ✅ актуальный (рос до 13 мая) |
| `voice_activity.jsonl` | JSON-массив событий срабатываний | `voice_activity_tracker` | ✅ актуальный |
| `combined.jsonl` | `type:"utterance"` (по фразам) | старый движок | 🟥 устаревшие данные (Mar 20) |
| `mic.jsonl`, `remote.jsonl` | `type:"utterance"` по источнику | старый движок | 🟥 устаревшие данные (Mar 20) |

### Формат интервала (актуальный)
```json
{
  "type": "interval",
  "start_at": "2026-03-20T09:00:00+03:00",
  "end_at": "2026-03-20T09:10:00+03:00",
  "duration_s": 600.0,
  "mic_text": "...", "remote_text": "...",
  "mic_words": 42, "remote_words": 17,
  "mic_language": "ru", "remote_language": "en"
}
```

### Ключевые константы (из `TRANSCRIPTION_LOGIC.md`)
| Константа | Значение |
|-----------|----------|
| Целевой sample rate | 16 000 Гц, моно, int16 |
| Фрейм VAD | 30 мс / 480 сэмплов |
| `min_interval_s` / `max_interval_s` | 300 / 600 с |
| `silence_cut_ms` | 2000 мс |
| `audio_queue_size` | 2048 |
| BG-очередь | 64 интервала |
| WebRTC VAD агрессивность | 1 |
| RMS-порог фоллбэка | 0.008 |
| Ретеншн voice_activity | 30 дней |

---

## 8. HTTP / WebSocket API (фактическое состояние кода)

Все роуты определены в `app/__init__.py`. Кроме `/api/login` всё требует сессию.

| Метод + путь | Статус | Назначение |
|--------------|--------|-----------|
| `GET /` | ✅ | Главная (редирект на /login если не залогинен) |
| `GET /login`, `POST /api/login`, `POST /api/logout` | ✅ | Авторизация по паролю (rate-limit 10/min) |
| `GET /api/devices` | ✅ | Список аудио-устройств ввода |
| `GET /api/models/status` | ✅ | Статус/доступность моделей по группам |
| `POST /api/models/preload` | ✅ | Предзагрузка модели |
| `POST /api/models/delete` | ✅ | Удаление локальных файлов модели |
| `GET /api/config`, `POST /api/config` | ✅ | Чтение/запись настроек |
| `POST /api/start`, `POST /api/stop` | ✅ | Управление транскрибацией |
| `GET /api/state` | ✅ | Состояние + метрики (RTF, лаг, CPU/RAM, очереди) |
| `GET /history` | ✅ | Страница истории |
| `GET /api/intervals?from&to` | ✅ | Интервалы, пересекающие диапазон |
| `GET /api/intervals/overview` | ✅ | Лёгкий обзор всех интервалов |
| `GET /api/voice-activity?type&from&to` | ✅ | Статистика активности (hourly/daily) — **в API.md не описан** |
| `GET /api/transcriptions?from&to` | ⚠️ **Мёртвый** | Читает `combined.jsonl`, который новый движок не пишет → всегда пусто для новых сессий |
| WS `state_update` / `overview_update` | ✅ | Пуш состояния и обзора раз в секунду |

> ⚠️ В `API.md` форма ответа `/api/devices` указана как `channels`/`sample_rate`, а код отдаёт
> `max_input_channels`/`default_samplerate`. Доку нужно поправить (см. 9).

---

## 9. Расхождения «код ↔ документация» (чинить при доработке)

| Документ | Проблема |
|----------|----------|
| `transcriber_webui_project/README.md` | Описывает **старый движок**: utterance-формат `combined.jsonl`, архив полного аудио, скачивание аудио-клипов, ретранскрибацию интервала, ключи `full_audio_*`. Этих функций в текущем коде **нет** |
| `transcriber_webui_project/API.md` | `/api/transcriptions` подан как рабочий (читает `combined.jsonl`) — фактически мёртвый. Форма `/api/devices` не совпадает с кодом. Не описан `/api/voice-activity` |
| `transcriber_webui_project/TRANSCRIPTION_LOGIC.md` | ✅ Актуален и точен. Мелочь: на схеме указано «intervals.jsonl + combined.jsonl», но пишется только `intervals.jsonl` |
| Корневой `README.md` | Относится к Слою 1 (CLI `app.py`), к веб-проекту неприменим |

---

## 10. Безопасность и эксплуатация

- **`config.json` хранит `password` и `secret_key` в открытом виде.** Файл в `.gitignore`, но лежит локально. При шаринге репо/машины — ротировать.
- Встроенный Flask-сервер — **только локально**. Для сети: `gunicorn -w 1 "run:app"` (строго один воркер — состояние в памяти).
- `host` по умолчанию `127.0.0.1` — наружу не торчит без явной смены.

---

## 11. Рекомендации для продолжения развития

**Сначала навести порядок (низкий риск):**
1. Удалить рудименты: `app/transcriber_old.py`, `app/static/app_old.js`, `app/static/history_old.js`, `app/templates/history_old.html` (нигде не используются).
2. Удалить/заархивировать старые данные `transcripts/combined.jsonl|mic.jsonl|remote.jsonl` и лишний каталог `output/`.
3. Решить судьбу корневого Слоя 1 — перенести в `legacy/` или удалить (оставив заметку в этом файле).
4. Привести `README.md` и `API.md` (внутри webui) в соответствие с interval-движком; либо починить `/api/transcriptions`, либо убрать его.

**Возможные направления развития (по следам старого функционала):**
- Вернуть, если нужно, точечные utterance-данные внутри интервала (старый движок умел) — но уже на базе нового пайплайна.
- Закрыть расхождения API и покрыть эндпоинты тестами (сейчас `tests/` нет).
- Рассмотреть вынос секретов из `config.json` в переменные окружения.

> История проекта и статусы файлов также сохранены в долговременной памяти Claude
> (`transcriber-architecture`), чтобы не путать поколения кода в будущих сессиях.
