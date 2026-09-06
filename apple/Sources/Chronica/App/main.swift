import AppKit

// Menu-bar agent app: no Dock icon, no main menu. We create NSApplication
// manually (SwiftPM executable, no Info.plist) and run as an accessory.
// The process main thread is the main actor at launch, so assumeIsolated is
// valid here and lets us touch the @MainActor AppDelegate/Engine directly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
