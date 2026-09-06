import SwiftUI
import TranscriberCore

// Shared presentational components used across the window (sidebar record card,
// section headers, etc.). The window layout itself lives in `RootView`.

// MARK: - State text

enum StateText {
    static func label(_ s: SessionState) -> String {
        switch s {
        case .idle: return L("state.idle")
        case .loading: return L("state.loading")
        case .recording: return L("state.recording")
        case .stopping: return L("state.stopping")
        case .error: return L("state.error")
        }
    }

    /// Метка для ВЕРХНЕЙ строки статуса. Загрузку/остановку несёт сама кнопка
    /// записи (серая, неактивная, со спиннером), поэтому сверху для этих
    /// состояний показываем нейтральное «Подготовка…», а не дублируем текст.
    static func headerLabel(_ s: SessionState) -> String {
        switch s {
        case .loading, .stopping: return L("state.preparing")
        default: return label(s)
        }
    }
}

// MARK: - Единственный честный индикатор проблемы

/// Короткая строка состояния под статусом записи.
///
/// Раньше интерфейс показывал сразу несколько технических индикаторов
/// («Метрики: N с назад», «Событие: N с назад», глубину очереди), из которых
/// пользователь не мог понять, всё ли в порядке. Теперь остаётся ОДНА строка и
/// только тогда, когда действительно что-то не так. Логика чистая — покрыта
/// тестами без движка.
enum SessionHealth {
    /// - parameters:
    ///   - stalled: конвейер остановлен и требует перезапуска приложения;
    ///   - suspendedForSleep: сессия приостановлена на время сна компьютера;
    ///   - degraded: один из источников звука не поднялся, запись идёт на остальных;
    ///   - droppedIntervals: сколько интервалов ядро выбросило из-за перегрузки
    ///     (`MetricsSnapshot.droppedIntervals`). Запись при этом продолжается,
    ///     поэтому это самая лёгкая из проблем.
    /// - returns: текст проблемы или `nil`, если всё в порядке.
    static func note(stalled: Bool, suspendedForSleep: Bool, degraded: Bool,
                     droppedIntervals: UInt32 = 0) -> String? {
        // Порядок важен: самая тяжёлая проблема вытесняет остальные.
        if stalled { return L("health.stalled") }
        if suspendedForSleep { return L("health.sleep") }
        if degraded { return L("health.degraded") }
        if droppedIntervals > 0 { return L("health.dropped") }
        return nil
    }

    @MainActor static func note(engine: Engine) -> String? {
        note(stalled: engine.pipelineStalled,
             suspendedForSleep: engine.isSuspendedForSleep,
             degraded: engine.captureDegraded,
             droppedIntervals: engine.metrics?.droppedIntervals ?? 0)
    }
}

// MARK: - Status glyph

/// Animated status symbol mirroring the session state (idle/loading/recording/
/// error). Pulses while recording, respecting Reduce Motion.
struct StatusGlyph: View {
    let state: SessionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .opacity(state == .recording && pulse && !reduceMotion ? 0.4 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true),
                       value: pulse)
            .onAppear { if state == .recording { pulse = true } }
            .onChange(of: state) { _, new in pulse = (new == .recording) }
            // Глиф дублирует текст статуса, стоящий рядом, — для VoiceOver
            // это лишний узел.
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .recording: return "record.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .loading, .stopping: return "waveform.circle"
        case .idle: return "waveform"
        }
    }
    private var color: Color {
        switch state {
        case .recording: return Theme.Color.semRec
        case .error: return Theme.Color.semWarning
        case .loading, .stopping: return Theme.Color.semProcessing
        case .idle: return Theme.Color.textSecondary
        }
    }
}

// MARK: - Morphing record button (accent <-> red)

/// Primary record control. Morphs между «Начать запись» (accent) и
/// «Остановить» (red); во время загрузки модели / остановки становится
/// НЕАКТИВНОЙ серой и сама показывает статус («Загрузка модели…» / «Остановка…»)
/// со спиннером — поэтому дублировать этот статус сверху не нужно.
struct RecordButton: View {
    let state: SessionState
    var compact: Bool = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRecording: Bool { state == .recording }
    /// Модель грузится или сессия останавливается — кнопку блокируем.
    private var isBusy: Bool { state == .loading || state == .stopping }

    private var title: String {
        switch state {
        case .loading: return L("state.loading")
        case .stopping: return L("state.stopping")
        case .recording: return L("popover.stop")
        default: return L("popover.start") // idle / error (повтор)
        }
    }
    private var background: Color {
        if isBusy { return Theme.Color.surface2 }               // серая неактивная
        return isRecording ? Theme.Color.semRec : Theme.Color.accent
    }
    private var foreground: Color { isBusy ? Theme.Color.textTertiary : .white }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.Color.textTertiary)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "record.circle")
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 6 : 11)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(background)
            )
            .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
    }
}
