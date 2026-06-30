import SwiftUI
import KeepressoCore

/// Keepresso is a menu-bar agent (`LSUIElement`): no Dock icon, no main window.
/// The entire UI lives in a `MenuBarExtra`.
@main
struct KeepressoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: appDelegate.model, updater: appDelegate.updater)
        } label: {
            MenuBarLabel(session: appDelegate.model.session)
        }
        .menuBarExtraStyle(.window)

        // The headless-readiness Setup checklist, opened from the menu via
        // `openWindow(id: "setup")`.
        Window("Keepresso Setup", id: Self.setupWindowID) {
            SetupView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)

        Window("Preferences", id: Self.preferencesWindowID) {
            PreferencesView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)

        Window("About Keepresso", id: Self.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }

    /// Scene ids shared with the menu's window-opening buttons.
    static let setupWindowID = "setup"
    static let preferencesWindowID = "preferences"
    static let aboutWindowID = "about"
}

/// Owns the long-lived ``AppModel`` (settings + session) and the per-second
/// ticker so they outlive any transient menu UI.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// Sparkle-backed auto-updater, behind the ``Updating`` seam. Started here so
    /// it schedules background checks for the app's whole lifetime.
    let updater: any Updating = SparkleUpdater()
    private lazy var ticker = SessionTicker(session: model.session, disk: model.disk)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If launched from the DMG / Downloads, move into /Applications and
        // relaunch from there (this instance quits if it relocates).
        AppRelocator.relocateIfNeeded()
        ticker.start()
    }
}
