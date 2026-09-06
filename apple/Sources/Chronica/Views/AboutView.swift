import SwiftUI
import AppKit

/// Окно «О Chronica».
///
/// Раньше это был `NSAlert`: модальное окно с кнопкой «Закрыть», в котором
/// нельзя было ни нажать ссылку, ни открыть список сторонних компонентов —
/// а обязательная атрибуция модели (CC-BY-4.0) там читалась как текст ошибки.
/// Теперь это обычное небольшое окно: иконка, имя, версия, авторство, ссылки.
struct AboutView: View {
    /// Действие «открыть уведомления о сторонних компонентах».
    var onOpenNotices: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            icon
            VStack(spacing: Theme.Space.xs) {
                Text(AppInfo.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(AppInfo.versionLine)
                    .font(.callout)
                    .foregroundStyle(Theme.Color.textSecondary)
                Text(AppInfo.author)
                    .font(.callout)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .multilineTextAlignment(.center)

            Link(destination: AppInfo.repositoryURL) {
                Text(L("about.github", AppInfo.repositoryLabel))
                    .font(.callout)
            }
            .buttonStyle(.link)

            Divider().overlay(Theme.Color.hairline)

            VStack(spacing: Theme.Space.s) {
                Text(L("about.local"))
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.textSecondary)
                Text(L("about.license"))
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.textSecondary)
                // Атрибуция обязательна по CC-BY-4.0, поэтому стоит в окне
                // «О приложении», а не только в THIRD_PARTY_NOTICES.md.
                Text(L("about.modelAttribution"))
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button(L("about.notices"), action: onOpenNotices)
                .controlSize(.regular)
        }
        .padding(Theme.Space.xl)
        .frame(width: 360)
        .background(Theme.Color.bgBase)
        .preferredColorScheme(.dark)
        .tint(Theme.Color.accent)
    }

    /// Иконка приложения, ровно та же, что в Dock/Finder.
    ///
    /// `applicationIconImage` в dev-сборке без бандла отдаёт системную
    /// «пустую» иконку, а не nil — специальной ветки на этот случай не нужно.
    private var icon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
    }
}

/// Окно, которое закрывается по Esc.
///
/// Обычное `NSWindow` в accessory-приложении без главного меню на Esc не
/// реагирует, а для окна «О приложении» это ожидаемый жест. `⌘W` работает
/// штатно (окно `.closable`), `⌘Q` остаётся выходом из приложения.
final class EscapeClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
