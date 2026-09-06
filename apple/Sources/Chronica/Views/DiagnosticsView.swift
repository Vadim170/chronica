import SwiftUI
import TranscriberCore

/// Окно «Диагностика»: технические показатели работы движка.
///
/// Раньше это был раздел «Дашборд» в главном окне, из-за чего повседневный
/// интерфейс был забит числами, которые пользователю не нужны. Теперь всё
/// техническое живёт в отдельном небольшом окне, открываемом из
/// Настройки → Дополнительно → «Диагностика…».
struct DiagnosticsView: View {
    @ObservedObject var engine: Engine

    private var m: MetricsSnapshot? { engine.metrics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if m == nil {
                    Text(L("diag.empty"))
                        .font(.callout)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                loadCard
                speedCard
                queueCard
                memoryCard
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.Color.bgBase)
        .preferredColorScheme(.dark)
        .tint(Theme.Color.accent)
    }

    // MARK: нагрузка (CPU/RAM со спарклайнами)

    private var loadCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(L("diag.load"))
                metricWithSparkline(
                    title: L("diag.cpu"),
                    value: m.map { Fmt.cpuLine(current: $0.cpuPercent, p50: $0.cpuP50, p90: $0.cpuP90) } ?? "—",
                    series: engine.metricHistory.map { Double($0.cpu) },
                    color: Theme.Color.accent,
                    note: L("diag.cpu.note")
                )
                metricWithSparkline(
                    title: L("diag.memory"),
                    value: m.map { Fmt.ramLine(current: $0.memoryRssBytes, peak: $0.memoryRssPeakBytes) } ?? "—",
                    series: engine.metricHistory.map { Double($0.ramBytes) / 1_048_576 },
                    color: Theme.Color.trackMic,
                    note: L("diag.memory.note")
                )
            }
        }
    }

    private func metricWithSparkline(title: String, value: String, series: [Double],
                                     color: Color, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Text(value).font(.metric).foregroundStyle(Theme.Color.textPrimary)
            }
            Sparkline(values: series, color: color)
                .frame(height: 28)
            Text(note).font(.caption).foregroundStyle(Theme.Color.textTertiary)
        }
    }

    // MARK: скорость обработки

    private var speedCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel(L("diag.speed"))
                valueRow(L("diag.rtf"), rtfStr, L("diag.rtf.note"))
                valueRow(L("diag.lag"), lagStr + " " + L("unit.seconds.short"),
                         L("diag.lag.note"))
            }
        }
    }

    private func valueRow(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout).foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Text(value).font(.metric).foregroundStyle(Theme.Color.textPrimary)
            }
            Text(note).font(.caption).foregroundStyle(Theme.Color.textTertiary)
        }
    }

    private var rtfStr: String { m.map { String(format: "%.2f", $0.sources.map(\.lastRtf).max() ?? 0) } ?? "—" }
    private var lagStr: String { m.map { String(format: "%.1f", $0.sources.map(\.lagEstimateS).max() ?? 0) } ?? "—" }

    // MARK: очередь и потери

    private var queueCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel(L("diag.queue"))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(m?.bgQueueDepth ?? 0)")
                        .font(.kpiNumber).foregroundStyle(Theme.Color.textPrimary)
                    Text("/ \(m?.bgQueueCapacity ?? 0)")
                        .font(.metric).foregroundStyle(Theme.Color.textTertiary)
                }
                GeometryReader { geo in
                    let cap = max(1, Int(m?.bgQueueCapacity ?? 1))
                    let frac = Double(m?.bgQueueDepth ?? 0) / Double(cap)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surface2)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(frac > 0.8 ? Theme.Color.semWarning : Theme.Color.accent)
                            .frame(width: geo.size.width * min(1, frac))
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                Text(L("diag.queue.note"))
                    .font(.caption).foregroundStyle(Theme.Color.textTertiary)

                // Потери показываем ТОЛЬКО при ненулевых потерях.
                if let droppedLine = Fmt.droppedAudioLine(totalDropped) {
                    Text(droppedLine)
                        .font(.metricSmall).foregroundStyle(Theme.Color.semWarning)
                    Text(L("diag.droppedAudio.note"))
                        .font(.caption).foregroundStyle(Theme.Color.textTertiary)
                }
                // Выброшенные интервалы — отдельная потеря: звук был нарезан,
                // но ASR его не увидел (переполнение очереди или прерванная
                // остановка). Тоже только при N > 0.
                if let intervalsLine = Fmt.droppedIntervalsLine(m?.droppedIntervals ?? 0) {
                    Text(intervalsLine)
                        .font(.metricSmall).foregroundStyle(Theme.Color.semWarning)
                    Text(L("diag.droppedIntervals.note"))
                        .font(.caption).foregroundStyle(Theme.Color.textTertiary)
                }
            }
        }
    }

    /// Сумма потерянных сэмплов по всем источникам.
    private var totalDropped: UInt64 {
        (m?.sources ?? []).reduce(0) { $0 + $1.droppedChunks }
    }

    // MARK: разбор памяти

    private var memoryCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel(L("diag.memoryBreakdown"))
                Text(engine.memoryBreakdownText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
