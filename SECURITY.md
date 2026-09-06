# Security Policy

**Please report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/Vadim170/chronica/security/advisories/new)**
("Report a vulnerability" on the Security tab) — not in a public issue, pull
request or discussion. Reports in English or Russian are equally welcome.

Response is **best effort**: this is a small project maintained in spare time.
Expect an acknowledgement within about a week, and a fix timeline agreed with
you once the report is confirmed. Please give the fix a chance to ship before
disclosing publicly. Credit in the advisory and in `CHANGELOG.md` if you want it.

## Supported versions

Only the latest release gets fixes. There is no in-app updater — new versions
come from [Releases](https://github.com/Vadim170/chronica/releases).

---

# Политика безопасности

**Сообщайте об уязвимостях приватно через
[GitHub Security Advisories](https://github.com/Vadim170/chronica/security/advisories/new)**
(вкладка Security → «Report a vulnerability»), а не через публичный issue,
пул-реквест или обсуждение.

Сроки — **best effort**: проект небольшой и делается в свободное время.
Подтверждение получения — ориентировочно в течение недели, сроки исправления
согласуем после подтверждения проблемы. Пожалуйста, дайте фиксу выйти прежде,
чем раскрывать детали публично. Упоминание в advisory и в `CHANGELOG.md` — по
вашему желанию.

## Что входит в скоуп

- **Локальный HTTP API** (`core/src/api.rs`, `core/src/api_v1.rs`): обход
  авторизации по Bearer-токену, обход правила «непетлевой адрес без токена не
  стартует», утечка данных через CORS, path traversal, отказ в обслуживании
  запросом. Подробности поведения — [`docs/API.md`](docs/API.md).
- **Обработка недоверенного ввода:** параметры HTTP-запросов и аргументы CLI
  (разбор времени, `limit`, `cursor`, запрос FTS5), содержимое базы данных,
  ответы Ollama и Hugging Face, аудиоданные и WAV-файлы на входе ASR.
  Разбор ввода не должен приводить к панике, порче базы или выходу за пределы
  каталога данных.
- **Транспорт до Ollama:** утечка данных за пределы указанного пользователем
  адреса, отправка чего-либо, кроме кадра и промпта, отправка данных при
  выключенном журнале дел.
- **Загрузка моделей:** обход проверки sha256, запись файлов вне
  `Models/`, выполнение чего-либо из скачанного, кроме загрузки весов.
- **Права и подпись:** ослабление Hardened Runtime, лишние entitlements,
  локальное повышение привилегий, запись за пределы каталога приложения.
- **Приватность как безопасность:** любой сетевой запрос, не описанный в
  [`docs/PRIVACY.md`](docs/PRIVACY.md), или попадание расшифровок, скриншотов
  либо содержимого экрана туда, где их быть не должно (включая `core.log`).

## Что вне скоупа

- Уязвимости сторонних компонентов как таковых (ONNX Runtime, sherpa-onnx,
  whisper.cpp, SQLite, Ollama) — сообщайте их апстриму; здесь уместен отчёт,
  если Chronica использует компонент небезопасным образом.
- Риски, вытекающие из осознанной настройки пользователем: указанный вручную
  удалённый адрес Ollama, API, открытый наружу вместе с токеном.
  Это задокументированное поведение, а не дефект — см.
  [`docs/PRIVACY.md`](docs/PRIVACY.md).
- Атаки, требующие физического доступа к разблокированной машине или уже
  полученных прав администратора.
- Отсутствие защиты базы данных от пользователя, который её и так владеет:
  SQLite-файл лежит в домашнем каталоге и не шифруется — это by design.
- Содержимое `docs/archive/` — исторические документы, не отражающие текущее
  состояние.
