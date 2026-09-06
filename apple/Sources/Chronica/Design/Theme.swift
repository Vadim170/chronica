import SwiftUI
import AppKit

/// A SwiftUI wrapper over `NSVisualEffectView` for the modern macOS "glass"
/// look (Liquid Glass on macOS 26). Used for the window sidebar and chrome so
/// surfaces read as translucent, vibrant material rather than flat fills.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = emphasized
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.isEmphasized = emphasized
    }
}

/// Dark design system tokens (from the product plan). The two audio tracks
/// are first-class: mic = teal, remote = amber, used across all surfaces.
enum Theme {
    enum Color {
        static let bgBase      = SwiftUI.Color(hex: 0x1C1C1E)
        static let bgSidebar   = SwiftUI.Color(hex: 0x161618)
        static let surface1    = SwiftUI.Color(hex: 0x252528)
        static let surface2    = SwiftUI.Color(hex: 0x2E2E32)
        static let hairline    = SwiftUI.Color.white.opacity(0.08)
        static let textPrimary = SwiftUI.Color(hex: 0xF2F2F7)
        static let textSecondary = SwiftUI.Color(hex: 0x9A9AA2)
        static let textTertiary  = SwiftUI.Color(hex: 0x6C6C72)
        static let accent      = SwiftUI.Color(hex: 0x5E5CE6)
        static let trackMic    = SwiftUI.Color(hex: 0x32D6C6)
        static let trackRemote = SwiftUI.Color(hex: 0xFFB340)
        static let semRec      = SwiftUI.Color(hex: 0xFF453A)
        static let semWarning  = SwiftUI.Color(hex: 0xFF9F0A)
        static let semSuccess  = SwiftUI.Color(hex: 0x30D158)
        static let semProcessing = SwiftUI.Color(hex: 0x64D2FF)
    }
    enum Radius { static let control: CGFloat = 8; static let card: CGFloat = 10; static let floating: CGFloat = 16; static let chip: CGFloat = 6 }
    enum Space { static let xs: CGFloat = 4; static let s: CGFloat = 8; static let m: CGFloat = 12; static let l: CGFloat = 16; static let xl: CGFloat = 24 }

    static func trackColor(_ channelId: String) -> SwiftUI.Color {
        channelId == "remote" ? Color.trackRemote : Color.trackMic
    }
}

// MARK: - Доступность: «Уменьшить прозрачность»

/// Читает системный флаг «Уменьшить прозрачность» (Универсальный доступ).
///
/// Когда флаг включён, полупрозрачное стекло заменяется СПЛОШНЫМ фоном:
/// размытие + скрим над обоями резко снижают читаемость для тех, кому этот
/// режим и нужен. Вынесено отдельной функцией, чтобы и SwiftUI-поверхности,
/// и AppKit-панель принимали решение одинаково.
enum Accessibility {
    /// Нужен ли сплошной (непрозрачный) фон вместо стекла.
    @MainActor static var prefersOpaqueSurfaces: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

/// Фон окна: стекло со скримом или сплошная заливка при «Уменьшить прозрачность».
///
/// Именно этот вью стоит за содержимым главного окна, поэтому решение о
/// прозрачности принимается в одном месте и переживает смену системной
/// настройки (перерисовка по уведомлению `accessibilityDisplayOptions…`).
struct WindowBackground: View {
    /// Затемнение скрима поверх стекла (0…1).
    var dimming: Double = 0.22
    @State private var opaque = Accessibility.prefersOpaqueSurfaces

    var body: some View {
        Group {
            if opaque {
                Theme.Color.bgBase
            } else {
                ZStack {
                    VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
                    SwiftUI.Color.black.opacity(dimming)
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            opaque = Accessibility.prefersOpaqueSurfaces
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}
