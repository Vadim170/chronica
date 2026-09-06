import SwiftUI
import AppKit
import Charts
import TranscriberCore
import UniformTypeIdentifiers

/// Раздел «Журнал» — ЕДИНАЯ лента работы по времени.
///
/// Дела (что происходило на экране) и реплики транскрипции (что говорилось) —
/// две грани одной хронологии, поэтому идут ОДНОЙ лентой вперемешку, новое
/// сверху. Места, где запись включали и выключали и где приложение
/// закрывалось, отмечены тонкими разделителями (см. `JournalFeed`).
/// Переключателя «Дела / Транскрипция» больше нет.
///
/// Экспорт выгружает ВЕСЬ период одним структурированным документом: дела +
/// открытые окна (наблюдения экрана) + транскрипция ПОКАНАЛЬНО (как HTTP API).
struct JournalView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var observer: ScreenObserver

    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var to = Date()
    @State private var search = ""
    @State private var exportError = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.Color.hairline)
            content
        }
        .background(Theme.Color.bgBase)
    }

    // MARK: панель инструментов

    private var toolbar: some View {
        VStack(spacing: Theme.Space.s) {
            HStack {
                Text(AppSection.journal.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                exportMenu
            }
            HStack(spacing: Theme.Space.m) {
                searchField
                Spacer(minLength: 0)
                periodSelector
            }
            if !exportError.isEmpty {
                Text(exportError).font(.caption).foregroundStyle(Theme.Color.semWarning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Space.l)
        .background(VisualEffectView(material: .headerView, blending: .withinWindow))
    }

    /// Поиск по ленте: фильтрует и реплики (в т.ч. по смыслу), и описания дел.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Color.textTertiary)
                .accessibilityHidden(true)
            TextField(L("history.search.placeholder"), text: $search)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
        .frame(maxWidth: 280)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Color.surface1))
    }

    private var periodSelector: some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                DatePicker("", selection: $from, in: ...to, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).frame(minWidth: 96)
                    .fixedSize()
                    .accessibilityLabel(L("journal.period.from.a11y"))
                Image(systemName: "arrow.right").font(.caption2)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .accessibilityHidden(true)
                DatePicker("", selection: $to, in: from...Date(), displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).frame(minWidth: 96)
                    .fixedSize()
                    .accessibilityLabel(L("journal.period.to.a11y"))
            }
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Color.surface1))

            Button(L("journal.today")) {
                from = Calendar.current.startOfDay(for: Date())
                to = Date()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(Theme.Color.accent)
            .help(L("journal.today.help"))
        }
    }

    private var exportMenu: some View {
        Menu {
            Button("JSON…") { export(.json) }
            Button("Markdown…") { export(.markdown) }
        } label: {
            Label(L("journal.export"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L("journal.export.a11y"))
        .help(L("journal.export.help"))
    }

    // MARK: содержимое

    private var content: some View {
        VStack(spacing: 0) {
            VoiceActivityStrip(engine: engine, from: from, to: to)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
            Divider().overlay(Theme.Color.hairline)
            JournalFeedView(engine: engine, observer: observer,
                            from: from, to: to, search: $search)
        }
    }

    // MARK: экспорт

    /// Границы периода как локальный ISO (совместимо с лексикографикой
    /// хранилища — см. `JournalPeriod`/`Fmt.queryBound`).
    private var period: (start: Date, end: Date) { JournalPeriod.bounds(from: from, to: to) }

    private func export(_ format: JournalExport.Format) {
        exportError = ""
        let bounds = period
        let intervals = engine.intervals(
            from: Fmt.queryBound(bounds.start), to: Fmt.queryBound(bounds.end)
        )
        let activities = observer.activities(from: bounds.start, to: bounds.end)
        let withObs = activities.map {
            ActivityWithObservations(activity: $0, observations: observer.observations(of: $0))
        }
        let doc = JournalExport.build(
            from: bounds.start, to: bounds.end, exportedAt: Date(),
            activities: withObs, intervals: intervals
        )
        let content = format == .json ? JournalExport.json(doc) : JournalExport.markdown(doc)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = JournalExport.suggestedFilename(from: from, format: format)
        panel.allowedContentTypes = format == .json
            ? [.json]
            : [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = L("journal.export.failed", error.localizedDescription)
        }
    }
}

// MARK: - Полоска голосовой активности за период

/// Компактный график «когда говорили» за выбранный период.
///
/// Раньше жил в Дашборде с легендой и собственным выбором шкалы. Здесь шкала
/// выводится из периода (`JournalPeriod.isHourly`), легенды нет — цвета
/// дорожек одни и те же во всём приложении. Запрос к хранилищу асинхронный:
/// длинный период больше не подвешивает главный поток.
private struct VoiceActivityStrip: View {
    @ObservedObject var engine: Engine
    let from: Date
    let to: Date

    @State private var buckets: [ActivityBucket] = []

    private var hourly: Bool { JournalPeriod.isHourly(from: from, to: to) }
    private var kind: ActivityKind { hourly ? .hourly : .daily }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                SectionLabel(L("journal.voiceActivity"))
                Spacer()
                Text(hourly ? L("journal.scale.hourly") : L("journal.scale.daily"))
                    .font(.metricSmall).foregroundStyle(Theme.Color.textTertiary)
            }
            if rows.isEmpty {
                Text(L("journal.voiceActivity.empty"))
                    .font(.caption).foregroundStyle(Theme.Color.textTertiary)
                    .frame(height: 64, alignment: .center)
            } else {
                Chart(rows) { row in
                    BarMark(x: .value(L("chart.time"), row.label),
                            y: .value(L("chart.words"), row.count))
                        .foregroundStyle(Theme.trackColor(row.channelId))
                        .position(by: .value(L("chart.track"), row.channelId))
                }
                .chartLegend(.hidden)
                .chartXAxis { AxisMarks(values: visibleLabels) { _ in
                    AxisValueLabel().font(.metricSmall).foregroundStyle(Theme.Color.textTertiary)
                } }
                .chartYAxis { AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.Color.hairline)
                    AxisValueLabel().font(.metricSmall).foregroundStyle(Theme.Color.textTertiary)
                } }
                .frame(height: 64)
                .accessibilityLabel(L("journal.voiceActivity.a11y"))
            }
        }
        // Перезагружаем при смене периода и при новых голосовых событиях.
        .task(id: reloadKey) { await reload() }
    }

    /// Ключ перезагрузки: период + ревизия активности ядра.
    private var reloadKey: String {
        "\(from.timeIntervalSinceReferenceDate)-\(to.timeIntervalSinceReferenceDate)-\(engine.activityRevision)"
    }

    private func reload() async {
        // Схлопываем соседние события: во время записи ревизия растёт часто.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        let iso = JournalPeriod.isoBounds(from: from, to: to)
        let next = await engine.voiceActivityAsync(kind: kind, from: iso.start, to: iso.end)
        guard !Task.isCancelled else { return }
        buckets = next
    }

    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let channelId: String
        let count: Int
    }

    private var rows: [Row] {
        buckets.flatMap { b in
            b.counts.map { c in
                Row(label: Fmt.bucketLabel(b.ts, hourly: hourly),
                    channelId: c.channelId, count: Int(c.count))
            }
        }
    }

    /// Подписи оси X, прорежённые до ~8 видимых, чтобы не накладывались.
    private var visibleLabels: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for b in buckets {
            let l = Fmt.bucketLabel(b.ts, hourly: hourly)
            if seen.insert(l).inserted { ordered.append(l) }
        }
        return ChartLabels.thinned(ordered, maxVisible: 8)
    }
}

/// Прореживание подписей оси — чистая функция (используется и в Диагностике).
enum ChartLabels {
    /// Берём каждую k-ю подпись, где k = ceil(count / maxVisible). Первая
    /// попадает всегда; последняя добавляется, чтобы правый край был подписан.
    static func thinned(_ labels: [String], maxVisible: Int) -> [String] {
        guard labels.count > maxVisible, maxVisible > 0 else { return labels }
        let k = max(1, Int((Double(labels.count) / Double(maxVisible)).rounded(.up)))
        var out = stride(from: 0, to: labels.count, by: k).map { labels[$0] }
        if let last = labels.last, out.last != last { out.append(last) }
        return out
    }
}
