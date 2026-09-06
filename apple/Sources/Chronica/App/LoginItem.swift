import Foundation
import ServiceManagement

/// Controls "launch at login" for the Chronica menu-bar agent via
/// `SMAppService.mainApp`.
///
/// Регистрация привязана к bundle id: после переименования продукта старая
/// запись остаётся в Системных настройках как «Transcriber», а новая не
/// создаётся сама. Однократную перерегистрацию делает `LoginItemMigration`
/// (см. `Core/Migration.swift`).
///
/// This is a thin, self-contained wrapper around the modern
/// `ServiceManagement` API (available since macOS 13). Toggling the login
/// item registers/unregisters the *bundled main app* with the system so that
/// macOS relaunches it automatically after the user logs in.
///
/// Important caveats:
/// - `SMAppService` only takes effect for a properly **signed, bundled `.app`**
///   that lives in a stable location (e.g. `/Applications`). When running an
///   unsigned local dev build, or a loose binary, `register()` may throw an
///   error such as `Operation not permitted`. Callers should **surface that
///   error to the UI rather than crashing** — the toggle is best-effort.
/// - Reading ``isEnabled`` is always safe and never throws; it simply reports
///   the current `status`.
///
/// This type has no dependency on `Engine`, `Prefs`, or `Theme` — wire a UI
/// toggle directly to ``isEnabled`` / ``setEnabled(_:)``.
@MainActor
public final class LoginItem {

    /// Shared instance to back a single UI toggle.
    public static let shared = LoginItem()

    private let service = SMAppService.mainApp

    public init() {}

    /// `true` when the main app is currently registered to launch at login.
    ///
    /// Reads `SMAppService.mainApp.status == .enabled`. Never throws.
    public var isEnabled: Bool {
        service.status == .enabled
    }

    /// A human-readable description of the current registration status,
    /// intended for logging / debugging only.
    public var status: String {
        switch service.status {
        case .notRegistered:    return "notRegistered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown(\(service.status.rawValue))"
        }
    }

    /// Enables or disables launch-at-login.
    ///
    /// - Parameter on: `true` to `register()` the main app, `false` to
    ///   `unregister()` it.
    /// - Throws: Rethrows any error from `SMAppService`. In particular,
    ///   `register()` can fail for unsigned/dev builds — callers should catch
    ///   and present the error instead of treating it as fatal.
    ///
    /// Calling `setEnabled(true)` when already enabled (or `false` when already
    /// unregistered) is a harmless no-op.
    public func setEnabled(_ on: Bool) throws {
        if on {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
