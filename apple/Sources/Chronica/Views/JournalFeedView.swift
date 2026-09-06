import SwiftUI
import AppKit
import TranscriberCore

// =============================================================================
// Единая лента журнала — представление
// =============================================================================
//
// Одна лента вместо двух вкладок «Дела | Транскрипция»: реплики и дела с
// экрана идут вперемешку по времени (новое сверху), а границы сессий записи
// отмечены тонкими линиями. Порядок и разделители считает `JournalFeed`
// (чистая логика), здесь — только рисование и загрузка данных.

/// Лента журнала в окне за выбранный период.
struct JournalFeedView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var observer: ScreenObserver
    /// Период задаётся снаружи (`JournalView`) — общий с графиком и экспортом.
    let from: Date
    let to: Date
    /// Поисковый запрос из панели инструментов Журнала.
    @Binding var search: String

    /// Движок семантического поиска (кэш эмбеддингов по interval id).
    @StateObject private var semantic = SemanticSearchEngine()

    @State private var records: [IntervalRecord] = []
    @State private var entries: [HistoryEntry] = []
    @State private var activities: [Activity] = []
    @State private var sessions: [SessionRecord] = []
    @State private var items: [JournalFeedItem] = []
    @State private var loading = true
    @State private var expanded: Set<Int64> = []
    /// Загруженные расшифровки по id дела. Отсутствие ключа = «ещё грузим»,
    /// пустая строка = «речи в этот интервал не было».
    @State private var transcripts: [Int64: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine
            searchingLine
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Один источник перезагрузки: период + ревизия закоммиченных интервалов.
        .task(id: reloadKey) { await reload() }
        // Запрос изменился → пересчитать сразу (быстрая фаза поиска синхронна),
        // не дожидаясь фоновой семантики: фильтр по делам мог измениться даже
        // тогда, когда набор реплик остался прежним.
        .onChange(of: search) { _, _ in
            semantic.rankedEntries(entries, query: search)
            rebuild()
        }
        // Семантика досчитывается в фоне и переписывает `results` — лента
        // пересобирается по готовому набору, а не по каждому нажатию клавиши.
        .onChange(of: semantic.results.map(\.id)) { _, _ in rebuild() }
        .onChange(of: observer.todayActivities) { _, _ in reloadActivities() }
    }

    /// Ключ перезагрузки: период + ревизия закоммиченных интервалов.
    private var reloadKey: String {
        "\(from.timeIntervalSinceReferenceDate)-\(to.timeIntervalSinceReferenceDate)"
            + "-\(engine.intervalRevision)"
    }

    // MARK: строка состояния наблюдателя экрана

    @ViewBuilder private var statusLine: some View {
        switch observer.status {
        case .off, .running:
            EmptyView()
        case .noPermission(let hint), .backendUnavailable(let hint):
            Label(hint, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.Color.semWarning)
                .lineLimit(3)
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.m)
        }
    }

    // MARK: содержимое

    /// Индикатор фоновой семантической фазы поиска (exact+fuzzy уже показаны).
    @ViewBuilder private var searchingLine: some View {
        if searchActive, semantic.isSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("history.searching"))
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.s)
        }
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(items) { row($0) }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if searchActive {
            ContentUnavailableView(L("history.noResults.title"),
                                   systemImage: "text.magnifyingglass",
                                   description: Text(L("history.noResults.description")))
        } else {
            ContentUnavailableView(L("journal.feed.empty.title"),
                                   systemImage: "tray",
                                   description: Text(L("journal.feed.empty.description")))
        }
    }

    @ViewBuilder private func row(_ item: JournalFeedItem) -> some View {
        switch item {
        case .day(let date):
            JournalDayHeader(date: date)
        case .separator(let separator):
            JournalSeparatorRow(separator: separator)
        case .line(let line):
            JournalLineRow(line: line, query: search)
        case .activity(let activity):
            let isExpanded = expanded.contains(activity.id)
            JournalActivityRow(
                activity: activity,
                expanded: isExpanded,
                transcript: isExpanded ? transcripts[activity.id] : "",
                toggle: { toggle(activity) }
            )
            // Запрос уходит только при раскрытии дела и живёт ровно столько,
            // сколько строка раскрыта.
            .task(id: isExpanded) {
                guard isExpanded else { return }
                await loadTranscript(activity)
            }
        }
    }

    // MARK: данные

    /// Активен ли поиск (после обрезки пробелов запрос непустой).
    private var searchActive: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Асинхронная перезагрузка с гашением всплесков: задача пересоздаётся по
    /// `reloadKey`, поэтому предыдущая отменяется, а пауза схлопывает череду
    /// коммитов во время записи в один запрос.
    private func reload() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        loading = items.isEmpty
        let bounds = JournalPeriod.bounds(from: from, to: to)
        let start = Fmt.queryBound(bounds.start), end = Fmt.queryBound(bounds.end)

        let loadedRecords = await engine.intervalsAsync(from: start, to: end)
        guard !Task.isCancelled else { return }
        let loadedSessions = await engine.sessionsAsync(from: start, to: end)
        guard !Task.isCancelled else { return }

        let loadedEntries = HistoryLogic.nonEmpty(HistoryLogic.entries(from: loadedRecords))
        let loadedActivities = observer.activities(from: bounds.start,
                                                   to: min(bounds.end, Date()))
        records = loadedRecords
        sessions = loadedSessions
        entries = loadedEntries
        activities = loadedActivities
        // Смена периода меняет и набор дел: id из прошлого периода к новым
        // делам отношения не имеют.
        transcripts = [:]
        // Выставляет `semantic.results` синхронно (быстрая фаза exact+fuzzy);
        // семантика досчитается в фоне и пересоберёт ленту через `onChange`.
        let ranked = semantic.rankedEntries(loadedEntries, query: search)
        items = assemble(records: loadedRecords, activities: loadedActivities,
                         sessions: loadedSessions, relevant: ranked.map(\.id))
        loading = false
    }

    /// Пересобрать ленту из уже загруженных данных (смена запроса/результатов).
    ///
    /// Реплики фильтрует движок поиска: при пустом запросе `results` — это весь
    /// набор, при непустом — только релевантные (включая найденные ПО СМЫСЛУ).
    /// Дела фильтруются по приложению, заголовку окна и описанию.
    private func rebuild() {
        items = assemble(records: records, activities: activities, sessions: sessions,
                         relevant: semantic.results.map(\.id))
    }

    /// Сборка ленты из явных данных — чтобы порядок присваиваний `@State`
    /// не влиял на то, что увидит пользователь.
    private func assemble(records: [IntervalRecord], activities: [Activity],
                          sessions: [SessionRecord],
                          relevant: [Int64]) -> [JournalFeedItem] {
        let ids = Set(relevant)
        return JournalFeed.build(
            intervals: records.filter { ids.contains($0.id) },
            activities: activities.filter { JournalFeed.matches($0, query: search) },
            sessions: sessions,
            now: Date())
    }

    private func reloadActivities() {
        let bounds = JournalPeriod.bounds(from: from, to: to)
        let loaded = observer.activities(from: bounds.start, to: min(bounds.end, Date()))
        activities = loaded
        items = assemble(records: records, activities: loaded, sessions: sessions,
                         relevant: semantic.results.map(\.id))
    }

    private func toggle(_ activity: Activity) {
        if expanded.contains(activity.id) {
            expanded.remove(activity.id)
        } else {
            expanded.insert(activity.id)
        }
    }

    /// Речь, перекрывающаяся с делом по времени, одной строкой по дорожкам.
    private func loadTranscript(_ activity: Activity) async {
        let records = await engine.intervalsAsync(
            from: Fmt.queryBound(activity.startAt), to: Fmt.queryBound(activity.endAt)
        )
        guard !Task.isCancelled else { return }
        let texts = records.flatMap { record in
            record.channels.compactMap { $0.text.isEmpty ? nil : $0.text }
        }
        transcripts[activity.id] = texts.joined(separator: " ")
    }
}

// MARK: - Разделитель сессии

extension JournalSeparator {
    /// Подпись разделителя. Включение и остановка называют время: по ним
    /// пользователь узнаёт границу, даже если рядом нет соседней записи.
    var title: String {
        switch kind {
        case .started: return L("journal.session.started", Fmt.shortTime(at))
        case .stopped: return L("journal.session.stopped", Fmt.shortTime(at))
        case .appClosed: return L("journal.session.appClosed")
        case .failed: return L("journal.session.failed")
        }
    }

    /// Цвет линии и подписи: авария выделяется, остальное остаётся фоном.
    var tint: Color {
        switch kind {
        case .started: return Theme.Color.semSuccess
        case .stopped, .appClosed: return Theme.Color.textTertiary
        case .failed: return Theme.Color.semWarning
        }
    }
}

/// Тонкая линия с подписью — граница сессии записи в ленте.
struct JournalSeparatorRow: View {
    let separator: JournalSeparator
    /// Компактный вариант для панели меню-бара.
    var compact = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            rule
            Text(separator.title)
                .font(compact ? .metricSmall : .caption)
                .foregroundStyle(separator.tint)
                .lineLimit(1)
                .fixedSize()
            rule
        }
        .padding(.vertical, compact ? 2 : Theme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(separator.title)
    }

    private var rule: some View {
        Rectangle()
            .fill(separator.tint.opacity(0.3))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// Заголовок дня на стыке суток.
struct JournalDayHeader: View {
    let date: Date

    var body: some View {
        Text(Fmt.dayTitle(date))
            .font(.sectionHeadline)
            .tracking(0.5)
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.top, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Реплика

/// Строка реплики: дорожка, время и текст.
struct JournalLineRow: View {
    let line: JournalLine
    /// Компактный вариант для панели меню-бара (текст в две строки).
    var compact = false
    /// Поисковый запрос — для подсветки совпадений.
    var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                TrackDot(channelId: line.channelId, size: compact ? 5 : 6)
                Text(Fmt.time(line.at))
                    .font(.metricSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                if !compact {
                    Text(Channels.label(line.channelId))
                        .font(.metricSmall)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            Text(highlighted)
                .font(.system(size: compact ? 12 : 13))
                .lineSpacing(compact ? 2 : 4)
                .lineLimit(compact ? 2 : nil)
                .foregroundStyle(Theme.Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(L("history.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
            }
        }
    }

    /// Текст с подсветкой совпадения (если запрос непустой и нашёлся).
    private var highlighted: AttributedString {
        var attributed = AttributedString(line.text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              let range = attributed.range(of: q, options: .caseInsensitive) else {
            return attributed
        }
        attributed[range].foregroundColor = Theme.Color.accent
        return attributed
    }
}

// MARK: - Дело с экрана

/// Блок дела: приложение, заголовок окна, описание и вложенная речь.
struct JournalActivityRow: View {
    let activity: Activity
    let expanded: Bool
    /// `nil` — расшифровка ещё загружается (блок просто не рисуется, чтобы не
    /// мигать текстом «речи не записано» до ответа хранилища).
    let transcript: String?
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Text(timeRange)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Theme.Color.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Space.s) {
                            Text(activity.app).font(.callout.bold())
                                .foregroundStyle(Theme.Color.textPrimary)
                            if !activity.title.isEmpty {
                                Text(activity.title).font(.callout)
                                    .foregroundStyle(Theme.Color.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        if !activity.summary.isEmpty {
                            Text(activity.summary).font(.callout)
                                .foregroundStyle(Theme.Color.textSecondary)
                                .lineLimit(expanded ? nil : 2)
                        }
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(Theme.Color.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let transcript {
                if transcript.isEmpty {
                    Text(L("activities.noSpeech"))
                        .font(.callout).foregroundStyle(Theme.Color.textTertiary)
                } else {
                    Text(transcript)
                        .font(.callout)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .textSelection(.enabled)
                        .padding(Theme.Space.m)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Color.surface2)
                        )
                }
            }
        }
        .padding(Theme.Space.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Color.surface1)
        )
    }

    /// Переиспользуемый форматтер из `Fmt`: создание `DateFormatter` на каждую
    /// строку списка заметно дороже самого форматирования.
    private var timeRange: String {
        "\(Fmt.shortTime(activity.startAt))–\(Fmt.shortTime(activity.endAt))"
    }
}

/// Компактная строка дела — для панели меню-бара.
///
/// В панели у дела нет ни разворота, ни вложенной расшифровки: там живёт
/// хронология, а подробности смотрят в окне. Поэтому строка сделана «по весу»
/// реплики рядом (`JournalLineRow(compact:)`) — без карточки и кнопки, с теми
/// же общими форматтерами.
struct JournalActivityCompactRow: View {
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "macwindow")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .accessibilityHidden(true)
                Text(Fmt.shortTime(activity.startAt))
                    .font(.metricSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                Text(activity.app)
                    .font(.metricSmall)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Описание от vision-LLM, а без него — заголовок окна: строка дела без
    /// единого слова о работе в ленте бесполезна.
    private var detail: String {
        activity.summary.isEmpty ? activity.title : activity.summary
    }
}
