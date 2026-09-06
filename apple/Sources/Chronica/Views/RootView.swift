import SwiftUI
import TranscriberCore

/// Разделы главного окна.
///
/// `id` — СТАБИЛЬНЫЙ английский ключ (используется как `Identifiable.id` и в
/// коде навигации), `title` — подпись для человека. Раньше и то, и другое было
/// одним `rawValue`: переименование раздела в интерфейсе меняло его
/// идентификатор, а любой сохранённый выбор молча ломался.
enum AppSection: String, CaseIterable, Identifiable {
    case journal
    case models
    case settings

    var id: String { rawValue }

    /// Подпись раздела в боковой панели и в меню.
    var title: String {
        switch self {
        case .journal: return L("section.journal")
        case .models: return L("section.models")
        case .settings: return L("section.settings")
        }
    }

    var icon: String {
        switch self {
        case .journal: return "book.pages"
        case .models: return "cube.box"
        case .settings: return "gearshape"
        }
    }
}

/// Корень единственного окна приложения.
///
/// Слева — несворачиваемая панель фиксированной ширины (карточка записи +
/// три раздела), справа — контент выбранного раздела. Разделы Live и Дашборд
/// убраны: живая лента живёт в панели меню-бара, а технические метрики — в
/// отдельном окне «Диагностика» (Настройки → Дополнительно).
struct RootView: View {
    @ObservedObject var engine: Engine
    /// Наблюдатель экрана (Chronica) — «Дела» в Журнале и настройки экрана.
    @ObservedObject var observer: ScreenObserver
    /// Управляется извне (меню-бар), чтобы «Открыть окно» открывало раздел.
    @ObservedObject var nav: Navigation
    /// Открыть окно диагностики (Настройки → Дополнительно). Реализация — в
    /// AppDelegate, который владеет окнами.
    var openDiagnostics: () -> Void = {}

    /// Фиксированная ширина боковой панели: панель не сворачивается и не
    /// масштабируется, поэтому подписи разделов всегда видны.
    private let sidebarWidth: CGFloat = 220

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            Divider().overlay(Theme.Color.hairline)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 540)
        .preferredColorScheme(.dark)
        .tint(Theme.Color.accent)
        // Стекло на весь фон окна; при «Уменьшить прозрачность» — сплошная
        // заливка (решение принимает WindowBackground).
        .background(WindowBackground().ignoresSafeArea())
    }

    // MARK: боковая панель

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Отступ под кнопки-светофор прозрачного титлбара.
            Color.clear.frame(height: 28)
            recordCard
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.m)
            Divider().overlay(Theme.Color.hairline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(AppSection.allCases) { section in
                    SidebarItem(section: section,
                                isSelected: (nav.section ?? .journal) == section) {
                        nav.section = section
                    }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, Theme.Space.s)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffectView(material: .sidebar, blending: .behindWindow))
    }

    /// Компактное управление записью в шапке панели: состояние, таймер и одна
    /// кнопка — они нужны в любом разделе.
    private var recordCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                StatusGlyph(state: engine.state)
                Text(StateText.headerLabel(engine.state))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if engine.state == .recording, let m = engine.metrics {
                Text(Fmt.clock(m.currentIntervalElapsedS))
                    .font(.metric).foregroundStyle(Theme.Color.semRec)
            }
            if let note = SessionHealth.note(engine: engine) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.Color.semWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RecordButton(state: engine.state, compact: true) {
                if engine.pipelineStalled { engine.restartApplication() }
                else if engine.state == .recording { engine.stop() } else { engine.loadModelAndStart() }
            }
            if !engine.lastError.isEmpty {
                ErrorBanner(message: engine.lastError,
                            retry: { engine.pipelineStalled ? engine.restartApplication() : engine.loadModelAndStart() },
                            actionTitle: engine.pipelineStalled ? L("popover.restartApp") : L("popover.retry"))
            }
        }
    }

    // MARK: контент

    @ViewBuilder private var detail: some View {
        Group {
            switch nav.section ?? .journal {
            case .journal: JournalView(engine: engine, observer: observer)
            case .models: ModelsView(engine: engine)
            case .settings: SettingsPane(engine: engine, observer: observer,
                                        openDiagnostics: openDiagnostics)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bgBase.opacity(0.92))
    }
}

/// Пункт боковой панели: иконка + подпись раздела, подсветка выбранного.
private struct SidebarItem: View {
    let section: AppSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, alignment: .center)
                Text(section.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.Color.textPrimary : Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Color.accent.opacity(0.22))
        } else if hovering {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Color.white.opacity(0.06))
        }
    }
}

/// Состояние навигации, общее для меню-бара и окна.
@MainActor
final class Navigation: ObservableObject {
    @Published var section: AppSection? = .journal
}
