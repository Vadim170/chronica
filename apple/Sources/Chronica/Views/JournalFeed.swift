import Foundation
import TranscriberCore

// =============================================================================
// Единая лента журнала: реплики + дела + разделители сессий
// =============================================================================
//
// Раньше журнал был разрезан на «Дела» и «Транскрипцию», и это разрезало ОДНУ
// рабочую хронологию на две. Здесь всё лежит в одной ленте по времени (новое
// сверху), а моменты, где запись включали/выключали и где приложение
// закрывалось, отмечены тонкими разделителями.
//
// В этом файле — ТОЛЬКО чистая логика (без UI, без ядра, без I/O): сборка
// ленты, порядок, разделители, схлопывание и лимит. Подписи разделителей и
// рисование — в `JournalFeedView`.

/// Одна реплика ленты: текст ОДНОЙ дорожки одного интервала.
///
/// Интервал разворачивается в реплики по дорожкам (микрофон / система), чтобы
/// у каждой строки была своя метка канала — как в панели меню-бара.
struct JournalLine: Identifiable, Equatable {
    let intervalId: Int64
    /// Дорожка (`Channels.mic` / `Channels.remote`).
    let channelId: String
    /// Начало интервала (место строки в ленте).
    let at: Date
    let text: String

    var id: String { "\(intervalId)-\(channelId)" }
}

/// Разделитель ленты — граница сессии записи.
struct JournalSeparator: Identifiable, Equatable {
    /// Что произошло на этой границе.
    enum Kind: String, Equatable, CaseIterable {
        /// Запись включили.
        case started
        /// Запись остановили штатно.
        case stopped
        /// Сессия не закрыта штатно: приложение закрыли или убили.
        case appClosed
        /// Сессия оборвалась аварийно (`stopReason == "error"`).
        case failed
    }

    let sessionId: Int64
    let kind: Kind
    let at: Date

    var id: String { "session-\(sessionId)-\(kind.rawValue)" }
}

/// Элемент единой ленты журнала.
enum JournalFeedItem: Identifiable, Equatable {
    /// Заголовок дня на стыке суток.
    case day(Date)
    /// Граница сессии записи.
    case separator(JournalSeparator)
    /// Реплика (текст дорожки интервала).
    case line(JournalLine)
    /// Дело с экрана.
    case activity(Activity)

    var id: String {
        switch self {
        case .day(let date): return "day-\(Int(date.timeIntervalSinceReferenceDate))"
        case .separator(let separator): return separator.id
        case .line(let line): return "line-\(line.id)"
        case .activity(let activity): return "activity-\(activity.id)"
        }
    }

    /// Момент времени, по которому элемент стоит в ленте.
    var at: Date {
        switch self {
        case .day(let date): return date
        case .separator(let separator): return separator.at
        case .line(let line): return line.at
        case .activity(let activity): return activity.startAt
        }
    }

    /// Содержательный элемент (то, ради чего лента существует).
    var isContent: Bool {
        switch self {
        case .line, .activity: return true
        case .day, .separator: return false
        }
    }

    var isSeparator: Bool {
        if case .separator = self { return true }
        return false
    }

    var isDayHeader: Bool {
        if case .day = self { return true }
        return false
    }
}

/// Сборка единой ленты журнала — чистые функции.
///
/// Единственный источник порядка и разделителей: и окно, и панель меню-бара
/// строят ленту одним и тем же вызовом, поэтому «в панели одно, в окне другое»
/// физически невозможно.
enum JournalFeed {

    /// Порядок элементов, попавших на ОДНУ И ТУ ЖЕ секунду.
    ///
    /// Лента идёт новым-сверху, поэтому больший ранг — выше. Конец сессии
    /// стоит над содержимым той же секунды (последняя реплика уже прозвучала,
    /// когда запись остановили), а начало сессии — под ним (сначала включили
    /// запись, потом появилась первая реплика). Без этого разделитель «ровно на
    /// границе» вставал бы в произвольную сторону.
    private enum Rank: Int {
        case sessionStart = 0
        case content = 1
        case sessionEnd = 2
    }

    /// Собрать ленту.
    ///
    /// - Parameters:
    ///   - intervals: интервалы с текстами (в любом порядке). Пустые
    ///     отбрасываются по правилу `HistoryLogic.isNonEmpty`.
    ///   - activities: дела с экрана (в любом порядке).
    ///   - sessions: сессии записи — из них получаются разделители.
    ///   - now: «сейчас». Самая свежая НЕЗАКРЫТАЯ сессия считается открытой в
    ///     этот момент, поэтому конца у неё нет: идущая прямо сейчас запись не
    ///     должна подписываться «приложение закрылось».
    ///   - calendar: календарь для заголовков дня (тесты фиксируют зону).
    /// - Returns: элементы НОВЫЕ СВЕРХУ. Пустой массив, если содержимого нет:
    ///   разделители — это границы МЕЖДУ записями, сами по себе они не лента.
    static func build(intervals: [IntervalRecord],
                      activities: [Activity],
                      sessions: [SessionRecord],
                      now: Date,
                      calendar: Calendar = .current) -> [JournalFeedItem] {
        var ordered: [Entry] = []

        // Реплики: интервал → строки по непустым дорожкам.
        let meaningful = Set(HistoryLogic
            .nonEmpty(HistoryLogic.entries(from: intervals))
            .map(\.id))
        for record in intervals where meaningful.contains(record.id) {
            guard let at = Fmt.date(record.startAt) else { continue }
            for channel in record.channels {
                let text = channel.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let line = JournalLine(intervalId: record.id,
                                       channelId: channel.channelId,
                                       at: at,
                                       text: text)
                ordered.append(Entry(at: at, rank: .content, tie: line.id, item: .line(line)))
            }
        }

        // Дела с экрана.
        for activity in activities {
            ordered.append(Entry(at: activity.startAt, rank: .content,
                                 tie: "activity-\(activity.id)", item: .activity(activity)))
        }

        // Пустая лента: без содержимого показывать нечего, и одинокие
        // разделители только мешают пустому состоянию.
        guard !ordered.isEmpty else { return [] }

        // Разделители сессий.
        let contentDates = ordered.map(\.at)
        for separator in separators(sessions: sessions, contentDates: contentDates, now: now) {
            let rank: Rank = separator.kind == .started ? .sessionStart : .sessionEnd
            ordered.append(Entry(at: separator.at, rank: rank, tie: separator.id,
                                 item: .separator(separator)))
        }

        // Полный порядок (время → ранг → идентификатор): элементы с одинаковой
        // секундой не схлопываются и не переставляются от прогона к прогону.
        ordered.sort { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at > rhs.at }
            if lhs.rank != rhs.rank { return lhs.rank.rawValue > rhs.rank.rawValue }
            return lhs.tie > rhs.tie
        }

        return withDayHeaders(collapsingSeparators(ordered), calendar: calendar)
    }

    /// Обрезать ленту до `limit` элементов, СОХРАНЯЯ ГОЛОВУ.
    ///
    /// Панель меню-бара показывает хвост истории, но не должна расти
    /// бесконечно. Режем именно хвост (старое), а не голову: свежие реплики —
    /// то, ради чего панель открывают. Повисший в конце заголовок дня убираем:
    /// день без единой записи под ним — мусор.
    static func capped(_ items: [JournalFeedItem], limit: Int) -> [JournalFeedItem] {
        guard limit > 0 else { return [] }
        guard items.count > limit else { return items }
        var out = Array(items.prefix(limit))
        while let last = out.last, last.isDayHeader { out.removeLast() }
        return out
    }

    /// Хвост истории из хранилища + живые события текущей сессии, без дублей.
    ///
    /// Закоммиченный интервал попадает И в живую ленту, И в хранилище, поэтому
    /// объединение обязано выкидывать повторы по id. Живая версия побеждает:
    /// она свежее (и приходит без похода в SQLite).
    static func mergedIntervals(stored: [IntervalRecord],
                                live: [IntervalRecord]) -> [IntervalRecord] {
        var seen = Set<Int64>()
        var out: [IntervalRecord] = []
        out.reserveCapacity(stored.count + live.count)
        for record in live + stored where seen.insert(record.id).inserted {
            out.append(record)
        }
        return out
    }

    /// Подходит ли дело под поисковый запрос: приложение, заголовок окна или
    /// описание. Пустой запрос (после обрезки пробелов) подходит всему —
    /// так же, как `HistoryLogic.matches` для реплик.
    static func matches(_ activity: Activity, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return activity.app.localizedCaseInsensitiveContains(q)
            || activity.title.localizedCaseInsensitiveContains(q)
            || activity.summary.localizedCaseInsensitiveContains(q)
    }

    // MARK: - внутреннее

    private struct Entry {
        let at: Date
        let rank: Rank
        let tie: String
        let item: JournalFeedItem
    }

    /// Разделители по сессиям записи.
    ///
    /// Штатно закрытая сессия даёт «остановлена» (или «сбой», если
    /// `stopReason == "error"`). Незакрытая — «приложение закрылось», и
    /// ставится оно по ПОСЛЕДНЕЙ записи этой сессии: когда именно процесс
    /// умер, никто не записал. Самая свежая незакрытая сессия исключение: она
    /// либо идёт прямо сейчас, либо под ней всё равно ничего нет.
    private static func separators(sessions: [SessionRecord],
                                   contentDates: [Date],
                                   now: Date) -> [JournalSeparator] {
        let parsed = sessions
            .compactMap { session -> (session: SessionRecord, start: Date)? in
                guard let start = Fmt.date(session.startedAt) else { return nil }
                return (session, start)
            }
            .sorted { $0.start < $1.start }

        var out: [JournalSeparator] = []
        for (index, item) in parsed.enumerated() {
            out.append(JournalSeparator(sessionId: item.session.id, kind: .started,
                                        at: item.start))

            if !item.session.endedAt.isEmpty, let end = Fmt.date(item.session.endedAt) {
                out.append(JournalSeparator(
                    sessionId: item.session.id,
                    kind: item.session.stopReason == SessionStopReason.error ? .failed : .stopped,
                    at: end))
                continue
            }

            // Сессия не закрыта штатно.
            guard index + 1 < parsed.count else { continue }
            let nextStart = parsed[index + 1].start
            let lastOwn = contentDates
                .filter { $0 >= item.start && $0 < nextStart }
                .max()
            out.append(JournalSeparator(sessionId: item.session.id, kind: .appClosed,
                                        at: min(lastOwn ?? item.start, now)))
        }
        return out
    }

    /// Схлопнуть каждую цепочку идущих подряд разделителей в ОДИН.
    ///
    /// Две линии подряд без содержимого между ними — визуальный мусор. Из
    /// цепочки остаётся самая говорящая граница: сбой и «приложение закрылось»
    /// объясняют ПРОПУСК в ленте, ради которого линия и рисуется; «запись
    /// включена» важнее «запись остановлена», потому что содержимое НАД линией
    /// принадлежит уже новой сессии. При равных видах остаётся самый свежий.
    private static func collapsingSeparators(_ ordered: [Entry]) -> [JournalFeedItem] {
        var out: [JournalFeedItem] = []
        out.reserveCapacity(ordered.count)
        var run: [JournalSeparator] = []

        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard let best = run.enumerated().min(by: { lhs, rhs in
                let lp = tellingRank(lhs.element.kind), rp = tellingRank(rhs.element.kind)
                return lp != rp ? lp < rp : lhs.offset < rhs.offset
            })?.element else { return }
            out.append(.separator(best))
        }

        for entry in ordered {
            if case .separator(let separator) = entry.item {
                run.append(separator)
                continue
            }
            flush()
            out.append(entry.item)
        }
        flush()
        return out
    }

    /// Насколько разделитель важен при схлопывании (меньше — важнее).
    private static func tellingRank(_ kind: JournalSeparator.Kind) -> Int {
        switch kind {
        case .failed: return 0
        case .appClosed: return 1
        case .started: return 2
        case .stopped: return 3
        }
    }

    /// Вставить заголовки дней перед первым элементом каждых суток.
    private static func withDayHeaders(_ items: [JournalFeedItem],
                                       calendar: Calendar) -> [JournalFeedItem] {
        var out: [JournalFeedItem] = []
        out.reserveCapacity(items.count + 2)
        var currentDay: Date?
        for item in items {
            let day = calendar.startOfDay(for: item.at)
            if day != currentDay {
                out.append(.day(day))
                currentDay = day
            }
            out.append(item)
        }
        return out
    }
}

/// Значения `SessionRecord.stopReason`, как их пишет ядро.
///
/// Строки приходят по FFI и локализации не подлежат — это контракт, а не текст
/// интерфейса.
enum SessionStopReason {
    /// Остановлено пользователем.
    static let user = "user"
    /// Авария: паника DSP, потеря ASR-воркера, watchdog.
    static let error = "error"
}
