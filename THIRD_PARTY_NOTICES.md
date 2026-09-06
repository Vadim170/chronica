# Сторонние компоненты и лицензии — Chronica

Chronica распространяется по лицензии MIT (см. `LICENSE`). В приложении
используются перечисленные ниже сторонние компоненты; их лицензии сохраняют
силу и приведены здесь во исполнение требований об атрибуции.

Колонка **«Как используется»** разделяет три принципиально разных случая:

| Обозначение | Что значит |
|---|---|
| **в бандле** | Код поставляется внутри `Chronica.app` (статически слинкован или лежит в `Contents/Frameworks`). |
| **скачивается пользователем** | В дистрибутив НЕ входит; загружается на компьютер пользователя по его действию. |
| **внешнее приложение** | Не входит и не скачивается нами; пользователь ставит его сам. |

Версии указаны на момент составления; актуальные — в `core/Cargo.lock` и в
скриптах сборки `apple/Scripts/`.

---

## 1. Нативные ML-рантаймы

### ONNX Runtime
- **Версия:** 1.17.1
- **Лицензия:** MIT
- **URL:** https://github.com/microsoft/onnxruntime
- **Как используется:** в бандле — динамическая библиотека
  `libonnxruntime.dylib` в `Contents/Frameworks`. Исполняет ONNX-модель
  Parakeet.

### sherpa-onnx
- **Версия:** поставляется предсобранной через крейт `sherpa-rs` 0.6.8
- **Лицензия:** Apache License 2.0
- **URL:** https://github.com/k2-fsa/sherpa-onnx
- **Как используется:** в бандле — `libsherpa-onnx-c-api.dylib`,
  `libsherpa-onnx-cxx-api.dylib` в `Contents/Frameworks`. Пайплайн
  распознавания речи поверх ONNX Runtime.
- **Примечание:** отдельного файла `NOTICE` в репозитории sherpa-onnx нет —
  проект распространяет только `LICENSE` (Apache-2.0). Условие 4(d) Apache-2.0
  о передаче NOTICE тем самым выполняется указанием лицензии и ссылки здесь.
  Требуемый Apache-2.0 текст лицензии доступен по адресу
  https://www.apache.org/licenses/LICENSE-2.0.

### whisper.cpp
- **Версия:** собирается из исходников крейтом `whisper-rs-sys` 0.15.0
- **Лицензия:** MIT (© 2023–2026 The ggml authors)
- **URL:** https://github.com/ggml-org/whisper.cpp
  (ранее `ggerganov/whisper.cpp`, старый адрес перенаправляет)
- **Как используется:** в бандле — статически слинкован в исполняемый файл
  (`libwhisper.a`). Бэкенд распознавания для моделей семейства Whisper.

### ggml
- **Версия:** вендорится внутри whisper.cpp (см. выше)
- **Лицензия:** MIT (© 2023–2026 The ggml authors)
- **URL:** https://github.com/ggml-org/ggml
- **Как используется:** в бандле — статически (`libggml.a`, `libggml-base.a`,
  `libggml-cpu.a`, `libggml-blas.a`, `libggml-metal.a`). Тензорный рантайм,
  включая Metal-бэкенд для GPU Apple.

### Silero VAD
- **Лицензия:** MIT (© 2020–present Silero Team)
- **URL:** https://github.com/snakers4/silero-vad
- **Как используется:** ONNX-модель детектора речи; исполняется через
  sherpa-onnx / ONNX Runtime.

---

## 2. Rust-крейты

Ядро `transcriber-core` собирается из крейтов ниже. Перечислены прямые
зависимости и те транзитивные, у которых лицензия нетривиальна. Полный список
транзитивных зависимостей — `core/Cargo.lock`.

**Все они попадают в бандл** (статическая линковка в исполняемый файл).

### Требуют особого внимания

| Крейт | Версия | Лицензия | Почему отдельно |
|---|---|---|---|
| [uniffi](https://github.com/mozilla/uniffi-rs) | 0.28.3 | **MPL-2.0** | Единственная copyleft-лицензия в дереве. MPL-2.0 — пофайловый copyleft: она обязывает раскрывать изменения **в исходниках самого uniffi**, но не затрагивает наш код, который его лишь использует. Мы uniffi не модифицируем; исходники доступны по ссылке. |
| [ring](https://github.com/briansmith/ring) | 0.17.14 | **Apache-2.0 AND ISC** (составная, пофайлово) | Единого SPDX-тега нет: новый код ring — под ISC, унаследованный из BoringSSL — под Apache-2.0 (файл `LICENSE-BoringSSL` в репозитории), встроенный polyfill `once_cell` — под MIT/Apache-2.0. Тянется транзитивно через `rustls` (TLS для загрузки моделей). |
| [whisper-rs](https://github.com/tazz4843/whisper-rs) | 0.16.0 | **Unlicense** (public domain) | Не MIT, как можно ожидать. Канонический репозиторий переехал на https://codeberg.org/tazz4843/whisper-rs. |
| [whisper-rs-sys](https://github.com/tazz4843/whisper-rs) | 0.15.0 | **Unlicense** | То же. Собирает нативный whisper.cpp (лицензия самого whisper.cpp — MIT, см. выше). |
| [libsqlite3-sys](https://github.com/rusqlite/rusqlite) | 0.28.0 | MIT (крейт-обёртка) | Собирает **SQLite amalgamation**, который сам находится в **public domain**: авторы SQLite явно отказались от копирайта (https://www.sqlite.org/copyright.html). Атрибуция не требуется, указано для полноты. |

### Прямые зависимости

| Крейт | Версия | Лицензия | Назначение |
|---|---|---|---|
| [serde](https://github.com/serde-rs/serde) | 1.0.228 | MIT OR Apache-2.0 | Сериализация конфигов и событий |
| [serde_json](https://github.com/serde-rs/json) | 1.0.150 | MIT OR Apache-2.0 | JSON |
| [thiserror](https://github.com/dtolnay/thiserror) | 1.0.69 | MIT OR Apache-2.0 | Типы ошибок |
| [log](https://github.com/rust-lang/log) | 0.4 | MIT OR Apache-2.0 | Фасад логирования |
| [parking_lot](https://github.com/Amanieu/parking_lot) | 0.12 | MIT OR Apache-2.0 | Мьютексы `RuntimeParams` |
| [crossbeam-channel](https://github.com/crossbeam-rs/crossbeam) | 0.5 | MIT OR Apache-2.0 | Каналы между DSP- и ASR-потоками |
| [rtrb](https://github.com/mgeier/rtrb) | 0.3 | MIT OR Apache-2.0 | Lock-free кольцевой буфер аудио |
| [regex](https://github.com/rust-lang/regex) | 1.12 | MIT OR Apache-2.0 | Постобработка текста |
| [once_cell](https://github.com/matklad/once_cell) | 1.21 | MIT OR Apache-2.0 | Ленивая инициализация |
| [chrono](https://github.com/chronotope/chrono) | 0.4 | MIT OR Apache-2.0 | Время в ISO-8601 |
| [libc](https://github.com/rust-lang/libc) | 0.2 | MIT OR Apache-2.0 | Перехват stderr для диагностики |
| [rusqlite](https://github.com/rusqlite/rusqlite) | 0.31 | MIT | SQLite-хранилище |
| [tiny_http](https://github.com/tiny-http/tiny-http) | 0.12 | MIT OR Apache-2.0 | Локальный HTTP API |
| [ureq](https://github.com/algesten/ureq) | 2.12.1 | MIT OR Apache-2.0 | Загрузка моделей с HuggingFace |
| [sha2](https://github.com/RustCrypto/hashes) | 0.10 | MIT OR Apache-2.0 | Проверка целостности загрузок |
| [hex](https://github.com/KokaKiwi/rust-hex) | 0.4 | MIT OR Apache-2.0 | Hex-кодирование |
| [sherpa-rs](https://github.com/thewh1teagle/sherpa-rs) | 0.6.8 | MIT | Rust-биндинги к sherpa-onnx |
| [webrtc-vad](https://github.com/kaegi/webrtc-vad) | 0.4 | MIT | Альтернативный VAD (фича `webrtc-vad`, по умолчанию выключена) |
| [rustls](https://github.com/rustls/rustls) | 0.23.40 | Apache-2.0 OR ISC OR MIT | TLS для `ureq` (транзитивно) |
| [tempfile](https://github.com/Stebalien/tempfile) | 3 | MIT OR Apache-2.0 | Только тесты, в бандл не попадает |

---

## 3. Модели

Никакие веса моделей **не входят** в дистрибутив Chronica. Их скачивает сам
пользователь: ASR-модели — встроенным менеджером моделей, vision-модель — через
Ollama. Лицензии моделей действуют для пользователя напрямую.

### Parakeet TDT 0.6b v3 (ASR по умолчанию)
- **Правообладатель:** NVIDIA
- **Лицензия:** **CC-BY-4.0** — требует указания авторства при использовании
  и распространении производных
  (https://creativecommons.org/licenses/by/4.0/)
- **Оригинал:** https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- **Зеркало, откуда качает приложение (int8 ONNX-экспорт для sherpa-onnx):**
  https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8
- **Как используется:** скачивается пользователем в
  `~/Library/Application Support/Chronica/Models/`.
- **Примечание:** репозиторий-зеркало собственной лицензии не декларирует
  (карточка модели пуста), поэтому применяются условия оригинала NVIDIA
  (CC-BY-4.0). Атрибуция: «Parakeet TDT 0.6b v3, © NVIDIA, CC-BY-4.0».

### Whisper (ggml-веса)
- **Правообладатель весов:** OpenAI; конвертация в формат ggml — авторы
  whisper.cpp
- **Лицензия:** MIT (и оригинальные веса OpenAI Whisper, и ggml-конвертации)
- **URL:** https://huggingface.co/ggerganov/whisper.cpp ·
  https://github.com/openai/whisper
- **Как используется:** скачивается пользователем (файлы `ggml-<id>.bin`).

### Qwen3-VL 2B Instruct (журнал дел, опционально)
- **Правообладатель:** Alibaba Cloud / команда Qwen
- **Лицензия:** **Apache-2.0** — пермиссивная open-source лицензия
  (https://www.apache.org/licenses/LICENSE-2.0)
- **URL:** https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct ·
  https://ollama.com/library/qwen3-vl
- **Как используется:** **не распространяется с приложением и не скачивается
  им.** Chronica лишь обращается по HTTP к локальному серверу Ollama
  (`http://127.0.0.1:11434`), если пользователь включил «Журнал дел». Модель
  пользователь ставит сам (`ollama pull qwen3-vl:2b`), принимая её лицензию.
- **Другие модели:** имя модели — настраиваемый параметр, подойдёт любая
  vision-модель Ollama. Если пользователь выберет другую модель, действует
  **её собственная лицензия**, а не Apache-2.0; условия нужно смотреть на
  карточке выбранной модели.

### Silero VAD (веса)
- **Лицензия:** MIT — см. раздел 1.
- **Как используется:** поставляется вместе с sherpa-onnx / скачивается
  вместе с ASR-моделью.

---

## 4. Внешние приложения

### Ollama
- **Лицензия:** MIT
- **URL:** https://ollama.com · https://github.com/ollama/ollama
- **Как используется:** внешнее приложение. Chronica не поставляет и не
  устанавливает Ollama; при включённом «Журнале дел» она обращается к уже
  запущенному пользователем локальному серверу по HTTP.

### BlackHole
- **Лицензия:** MIT
- **URL:** https://github.com/ExistentialAudio/BlackHole
- **Как используется:** никак — упомянут только как пример стороннего
  виртуального аудиоустройства; Chronica его не поставляет, не устанавливает
  и не предлагает.

---

## 5. Платформенные фреймворки Apple

AVFoundation, ScreenCaptureKit, Core Audio, CoreML, Metal / MetalKit,
Accelerate, AppKit, SwiftUI, Foundation, Security, SystemConfiguration —
поставляются с macOS и используются по условиям лицензионного соглашения
Apple на программное обеспечение. Отдельной атрибуции не требуют.

---

*Нашли неточность в лицензии или отсутствующий компонент —
[заведите issue](https://github.com/) с пометкой `licensing`.*
