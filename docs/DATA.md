# Chronica — данные на диске

Всё, что собирает Chronica, остаётся на устройстве. Этот документ описывает, где
лежат данные, как устроена база, что с временами и retention, и как достать всё
это из терминала.

HTTP-доступ к тем же данным — [`API.md`](API.md).

---

## Пути (macOS)

| что                          | путь                                                                  |
|------------------------------|-----------------------------------------------------------------------|
| корень приложения            | `~/Library/Application Support/Chronica/`                           |
| **база транскрипции**        | `~/Library/Application Support/Chronica/store/transcriber.sqlite`    |
| WAL/SHM рядом с базой        | `…/transcriber.sqlite-wal`, `…/transcriber.sqlite-shm`                 |
| журнал экрана (только macOS) | `~/Library/Application Support/Chronica/store/screen.sqlite`         |
| логи ядра                    | `~/Library/Application Support/Chronica/store/logs/core.log`         |
| модели ASR                   | `~/Library/Application Support/Chronica/Models/`                     |

Каталог `store/` — это `storage_path` конфигурации ядра; на других платформах он
задаётся оболочкой, база всегда называется `transcriber.sqlite`.

---

## Схема (v3)

Версия хранится в `PRAGMA user_version`. Миграции применяются при открытии базы,
пошагово, **каждая в своей транзакции**. База, созданная до версионирования
(есть таблицы, `user_version = 0`), считается v1 и домигрируется. База **новее**
кода не открывается — приложение честно говорит об этом вместо непонятных
ошибок «нет такой колонки».

```sql
CREATE TABLE intervals (
    id          INTEGER PRIMARY KEY,
    start_at    TEXT    NOT NULL,   -- ISO-8601 с локальным смещением
    end_at      TEXT    NOT NULL,
    duration_s  REAL    NOT NULL,
    total_words INTEGER NOT NULL,
    start_ms    INTEGER,            -- v2: epoch-мс UTC
    end_ms      INTEGER             -- v2
);
CREATE INDEX idx_intervals_start_at ON intervals(start_at);
CREATE INDEX idx_intervals_start_ms ON intervals(start_ms);   -- v2
CREATE INDEX idx_intervals_end_ms   ON intervals(end_ms);     -- v2

CREATE TABLE interval_texts (
    interval_id INTEGER NOT NULL,   -- -> intervals.id
    channel_id  TEXT    NOT NULL,   -- 'mic' | 'remote' | …
    text        TEXT    NOT NULL,
    words       INTEGER NOT NULL,
    language    TEXT    NOT NULL    -- 'ru', 'en', …
);
CREATE INDEX idx_interval_texts_interval_id ON interval_texts(interval_id);

CREATE TABLE voice_events (
    id         INTEGER PRIMARY KEY,
    ts         TEXT    NOT NULL,    -- ISO-8601 с локальным смещением
    channel_id TEXT    NOT NULL,
    date       TEXT    NOT NULL,    -- 'YYYY-MM-DD' в локальной зоне
    hour       INTEGER NOT NULL,
    ts_ms      INTEGER              -- v2: epoch-мс UTC
);
CREATE INDEX idx_voice_events_ts           ON voice_events(ts);
CREATE INDEX idx_voice_events_channel_date ON voice_events(channel_id, date);
CREATE INDEX idx_voice_events_ts_ms        ON voice_events(ts_ms);   -- v2

-- v3: сессии записи — «здесь включили» / «здесь выключили»
CREATE TABLE sessions (
    id          INTEGER PRIMARY KEY,
    started_at  TEXT    NOT NULL,   -- ISO-8601 с локальным смещением
    started_ms  INTEGER NOT NULL,   -- epoch-мс UTC, по нему идут диапазоны
    ended_at    TEXT,               -- NULL = сессия не закрыта штатно
    ended_ms    INTEGER,
    stop_reason TEXT                -- 'user' | 'error' | NULL (не закрыта)
);
CREATE INDEX idx_sessions_started_ms ON sessions(started_ms);

-- v2, если сборка SQLite умеет FTS5 (в поставке — умеет):
CREATE VIRTUAL TABLE interval_texts_fts USING fts5(
    text,
    content='interval_texts',
    content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
);
-- + триггеры interval_texts_ai / _ad / _au, синхронизирующие индекс
--   при INSERT / DELETE / UPDATE в interval_texts.
```

**Что дала v2.** Раньше диапазоны сравнивались лексикографически по ISO-строкам —
это врёт при смене таймзоны и переходе на летнее время (`…T09:30+03:00` и
`…T06:30+00:00` — один момент, но разные строки). Теперь все `WHERE`/`ORDER BY`
по времени идут по `*_ms`, а ISO-строки остались для отображения и совместимости
публичных типов. При миграции `*_ms` заполняются из ISO-строк; нечитаемые строки
остаются `NULL` (такие записи просто не попадают в выборки по периоду).

**Что дала v3.** Таблица `sessions` — журнал самих включений записи. Одна строка
на нажатие «Запись»: `started_at` пишется в `start()`, `ended_at` + `stop_reason`
— в `stop()`. Нужна затем, чтобы единая лента журнала рисовала разделители
(«здесь запись включили / выключили / приложение закрылось») по **факту**, а не
по эвристике «пауза больше N секунд».

- `stop_reason = 'user'` — остановил пользователь;
- `stop_reason = 'error'` — авария: паника DSP-потока, потеря ASR-воркера,
  watchdog зависшего DSP, остановка, прерванная по дедлайну;
- `ended_at IS NULL` — **сессию никто не закрыл**: процесс убили или он упал.
  Это и есть «здесь приложение закрылось». У сессии, которая идёт прямо сейчас,
  конца тоже нет — она ещё не закончилась.

Причину пишет ПЕРВЫЙ, кто закрыл сессию (`UPDATE … WHERE ended_at IS NULL`):
иначе авария маскировалась бы штатным `stop()`, который оболочка зовёт после
неё. Ошибка записи сессии никогда не роняет `start()`/`stop()` — она уходит в
`logs/core.log`. Незакрытые сессии прошлых запусков ядро **не подчищает**: это
исторические факты. Миграция v2 → v3 только создаёт таблицу: до v3 факта запуска
в базе не было, восстанавливать его из интервалов было бы догадкой — поэтому
история сессий начинается с первого запуска новой версии.

**PRAGMA при открытии:** `journal_mode=WAL`, `synchronous=NORMAL`,
`journal_size_limit=8388608` (8 МБ), `busy_timeout=3000`, `temp_store=MEMORY` —
компромисс «мало записи на диск / не терять данные при падении».

### Форматы времени

- в базе: `*_at` / `ts` — ISO-8601 **с таймзоной** (RFC 3339), `*_ms` — epoch-мс UTC;
- на входе публичных методов ядра, API и CLI: ISO-8601 с таймзоной,
  `YYYY-MM-DD` (локальные сутки) или epoch-мс. Невалидное значение — понятная
  ошибка ввода, не сбой сервера;
- интервал попадает в период, если он его **пересекает**: `start_ms < to AND end_ms > from`;
- сессия попадает в период, если в него попадает её **начало или конец**
  (`started_ms` либо `ended_ms` в `[from, to)`): именно эти границы дают
  разделитель внутри показываемого периода. Незакрытая сессия видна только по
  своему началу — иначе одно старое падение приложения лезло бы во все будущие
  периоды.

---

## Retention

Данные не удаляются сами по себе, пока чистку не позвали:

- `retention_sweep(days)` — только `voice_events` старше окна (историческое поведение);
- `retention_sweep_all(days)` — `intervals` + `interval_texts` + `voice_events`
  старше окна; интервал удаляется, когда он **закончился** до отсечки
  (`end_ms < cutoff`). Возвращает число удалённых строк. Полнотекстовый индекс
  чистится триггерами автоматически.

Отсечка считается как «сейчас минус N суток» в UTC, поэтому смена зоны на неё не
влияет. Файл после большой чистки не уменьшается сам — нужен `VACUUM`
(см. `db vacuum`). Таблица `sessions` чисткой **не затрагивается**: строка на
запуск записи весит десятки байт, а разделители ленты нужны и для старых дней.

```bash
chronica db retention --days 90   # удалить всё старше 90 суток
chronica db vacuum                # сжать файл
```

---

## Формат экспорта

Один документ на период; **та же форма, что строит macOS-приложение**
(`JournalExport`), поэтому файлы взаимозаменяемы. Ключи — camelCase.

```json
{
  "product": "Chronica",
  "exportedAt": "2026-09-03T12:00:00+03:00",
  "from": "2026-09-03T00:00:00+03:00",
  "to":   "2026-09-04T00:00:00+03:00",
  "activities": [],
  "transcription": {
    "count": 1,
    "intervals": [
      {
        "id": 1,
        "startAt": "2026-09-03T10:00:00+03:00",
        "endAt":   "2026-09-03T10:01:00+03:00",
        "durationS": 60.0,
        "channels": [
          { "channelId": "mic", "text": "обсудили релиз Chronica и подписи",
            "words": 5, "language": "ru" }
        ]
      }
    ]
  }
}
```

`activities` — «дела» с экрана; их знает только приложение, поэтому экспорт из
API и CLI отдаёт пустой массив, а транскрипцию заполняет.

Markdown-вариант (`--format md`) — тот же документ для чтения:

```markdown
# Журнал Chronica

- Период: 2026-09-03T00:00:00+03:00 — 2026-09-04T00:00:00+03:00
- Экспортировано: 2026-09-03T12:00:00+03:00

## Дела (0)

_Нет записанных дел за период._

## Транскрипция (2 интервалов)

### 10:00–10:01

**mic** (`ru`): обсудили релиз Chronica и подписи

**remote** (`en`): sounds good
```

---

## CLI

Бинарь `chronica` читает ту же базу и **не требует запущенного
приложения**. Сборка — без ML-рантаймов (работа с базой это чистое чтение
SQLite), бинарь получается самодостаточным:

```bash
cd core
cargo build --release --bin chronica --no-default-features --features store
cp target/release/chronica /usr/local/bin/     # готовый файл: core/target/release/chronica
```

Подробности и вариант с ML для `transcribe` — в
[`BUILD.md`](BUILD.md) (раздел 3.1).

Общие опции: `--store PATH` (по умолчанию
`~/Library/Application Support/Chronica/store/transcriber.sqlite`),
`--json` (синоним `--format json`), `-h`/`--help`.
Ошибки печатаются в stderr, код возврата ≠ 0.

Вывод рассчитан на конвейеры: если читатель закрывает stdout
(`chronica today | head -3`, `| jq`, `| grep -m1`), CLI молча завершается с
кодом 0 — как `cat`, `grep` или `git log`. Настоящие ошибки записи (нет места
на диске при `> file`) по-прежнему видны в stderr и дают ненулевой код.

Даты `YYYY-MM-DD` — **локальные сутки**: `--from` берёт начало дня, `--to` — его
конец, поэтому `--from 2026-09-01 --to 2026-09-01` это ровно те сутки. Также
принимаются ISO-8601 с таймзоной и epoch-мс.

### `today` — что наговорено сегодня

```bash
chronica today
chronica today --channel mic --format md
chronica today --json | jq -r '.intervals[].channels[].text'
```
```
Сегодня, 2026-09-03
[10:00] mic: обсудили релиз Chronica и подписи
[10:00] remote: sounds good
[10:05] mic: дальше делаем нотаризацию
```

Реплики помечены временем `[ЧЧ:ММ]`, поэтому дату печатает заголовок.

### `transcript` — период

```bash
chronica transcript --from 2026-09-01 --to 2026-09-03
chronica transcript --from 2026-09-03T10:00:00+03:00 --to 2026-09-03T12:00:00+03:00 --format md
```

### `search` — полнотекстовый поиск

```bash
chronica search "релиз"
chronica search "нотаризация" --from 2026-09-01 --limit 5
chronica search --json "релиз" | jq -r '.items[] | "\(.start_at) \(.channel_id): \(.snippet)"'
```
```
2026-09-03T10:00:00+03:00  mic
  …в понедельник обсудили «релиз» Chronica и подписи, дальше нотаризация…
2026-09-02T18:20:11+03:00  remote
  …we should ship the «релиз» build before friday…
```

На каждое попадание печатаются **время, канал и фрагмент** (≈200 символов
вокруг совпадения) — интервалы бывают по несколько тысяч символов, целиком их
читать в терминале нечем. Совпадение выделено: `«…»` в пайпе и файле,
ANSI-жирным, если stdout — терминал. Границы фрагмента не режут слова, обрыв
текста помечен `…`; якорь ставится на целое слово, а не на первую подстроку
внутри другого слова (запрос «тест» подсветит `тест`, а не `тест`ировали, если
целое слово в тексте есть).

По умолчанию `--limit 20`; порядок — новые сверху, один результат на интервал.
Полный текст фрагмент не заменяет: в `--json` у каждого элемента есть и
`snippet`, и все `channels[].text` целиком (плюс `channel_id` — канал, в
котором нашлось совпадение).

Слова соединяются логическим И. Если сборка SQLite без FTS5 — поиск идёт по
подстроке (в `--json` это видно в поле `engine`); фрагменты в обоих случаях
считаются одинаково.

### `stats` — сколько наговорено

```bash
chronica stats
chronica stats --from 2026-09-03 --to 2026-09-03
```
```
Период: 2026-09-03T00:00:00+03:00 — 2026-09-04T00:00:00+03:00
Интервалов: 2   слов: 12   длительность: 3.0 мин

Канал         Интервалы    Слова   Минуты речи
mic                   2        8           3.0
remote                2        4           3.0
```

Без `--from/--to` считается вся база, а в подписи периода стоят **фактические
границы данных** (`first_start_at`/`last_end_at`, те же, что показывает
`db info`):

```
Период: всё время (с 2026-06-19 по 2026-09-03)
Интервалов: 21795   слов: 167743   длительность: 8372.3 мин
```

Если задана только одна граница, вторая берётся из данных; если база пустая —
`Период: всё время (данных нет)`. В `--json` поля `from`/`to` остаются как
были: заданные границы или пустая строка.

«Минуты речи» по каналу — сумма длительностей интервалов, где на этом канале
была распознана речь (оценка сверху: в интервал попадают и паузы).

### `sessions` — когда включали и выключали запись

```bash
chronica sessions
chronica sessions --from 2026-09-03 --to 2026-09-03
chronica sessions --limit 5 --json | jq -r '.items[].stop_reason'
```
```
Начало               Конец                Причина          Длительность
2026-09-03 12:00:00  —                    — (не закрыта)              —
2026-09-03 10:00:00  2026-09-03 10:42:30  пользователь          42.5 мин
2026-09-02 18:03:11  2026-09-02 18:03:31  авария                    20 с
```

Без `--from/--to` печатаются последние `--limit` сессий (по умолчанию 50),
**новые сверху**. С периодом — сессии, у которых в него попадает начало или
конец, по возрастанию времени.

- `пользователь` — запись остановил пользователь;
- `авария` — паника DSP, потеря ASR-воркера, watchdog, остановка по дедлайну;
- `— (не закрыта)` — сессию никто не закрыл: приложение завершилось, не
  остановив запись (либо запись идёт прямо сейчас). Длительности у такой
  сессии нет.

В `--json` — форма `/api/v1/sessions` (`count` + `items` с `id`, `started_at`,
`ended_at`, `stop_reason`) плюс `duration_s` (`null` у незакрытой сессии).

### `export` — документ журнала

```bash
chronica export --from 2026-09-01 --to 2026-09-03 -o journal.json
chronica export --from 2026-09-03 --to 2026-09-03 --format md -o day.md
```

Без `-o` документ печатается в stdout. Формат идентичен `GET /api/v1/export`.

### `db` — обслуживание

```bash
chronica db info
chronica db info --json
chronica db vacuum
chronica db retention --days 90
```
```
файл:            /Users/me/Library/Application Support/Chronica/store/transcriber.sqlite
версия схемы:    3
поиск:           FTS5
размер:          60.0 КБ (+WAL 0 Б)
интервалов:      2
текстов:         4
событий речи:    2
сессий:          1
период:          2026-09-03T10:00:00+03:00 — 2026-09-03T10:07:00+03:00
```

### `transcribe` — проверка ASR

Разовая транскрипция WAV-файла (16-битный PCM, любой rate/каналы — ядро
ресемплит в 16 кГц моно). Нужны скачанные веса модели.

Единственная команда, которой нужен **ML-рантайм**: в штатной ML-free сборке
(см. выше) её нет в `--help`, а вызов печатает подсказку и выходит с кодом 2.
Собирать так:

```bash
cargo run --features sherpa --bin chronica -- transcribe speech.wav \
  [--models-path DIR] [--model ID] [--family parakeet|whisper] \
  [--lang auto|ru|en] [--accel auto|cpu|coreml|gpu]
```

---

## Прямые SQL-запросы

База — обычный SQLite, её можно читать чем угодно (лучше — копию файла, чтобы не
мешать приложению). Помните: диапазоны считайте по `*_ms`, не по строкам.

```bash
cp ~/Library/Application\ Support/Chronica/store/transcriber.sqlite /tmp/t.sqlite
sqlite3 /tmp/t.sqlite "
  SELECT iv.start_at, t.channel_id, t.text
  FROM intervals iv JOIN interval_texts t ON t.interval_id = iv.id
  WHERE iv.start_ms >= strftime('%s','2026-09-03') * 1000
  ORDER BY iv.start_ms;"
```
