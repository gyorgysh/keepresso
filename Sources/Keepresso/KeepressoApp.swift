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
            MenuBarLabel(session: appDelegate.model.session, showCountdown: appDelegate.model.showCountdownInMenuBar)
        }
        .menuBarExtraStyle(.window)

        // The headless-readiness Setup checklist, opened from the menu via
        // `openWindow(id: "setup")`.
        Window("Keepresso Setup", id: Self.setupWindowID) {
            SetupView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)

        Window("Gaming & Streaming", id: Self.streamingWindowID) {
            StreamingSetupView(model: appDelegate.model)
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
    static let streamingWindowID = "streaming"
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
    private lazy var ticker = SessionTicker(
        session: model.session,
        disk: model.disk,
        closedDisplay: model.closedDisplay,
        onTick: { [weak self] in
            self?.model.syncWidgetState()
            self?.model.awdlAutoTick()
        }
    )
    /// Listens for the Control Center toggle's Darwin doorbell.
    private var widgetObserver: WidgetCommandObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If launched from the DMG / Downloads, move into /Applications and
        // relaunch from there (this instance quits if it relocates).
        AppRelocator.relocateIfNeeded()
        // Give the Shortcuts intents their way to the live model.
        IntentContext.model = model
        // Read the closed-display (pmset disablesleep) state now: it persists
        // across reboots, and the ticker's lid handling stays inert until the
        // controller knows the mode is on, not just once a menu opens.
        model.refreshClosedDisplay()
        // Any AWDL watchdog flag surviving from a previous process is stale
        // (the loop it kept alive has already exited via its pid check).
        Task { await model.awdl.cleanupAtLaunch() }
        ticker.start()
        // Register the global keep-awake toggle shortcut, if the user set one.
        model.registerHotKey()
        // Start a session right away if "Start keep-awake on launch" is on.
        model.startOnLaunchIfNeeded()
        // The Control Center toggle: consume a command that may have launched
        // us, then keep listening while running.
        widgetObserver = WidgetCommandObserver { [weak model] in model?.applyPendingWidgetCommand() }
        model.applyPendingWidgetCommand()
        model.syncWidgetState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The session dies with this process; don't leave the widgets lying.
        model.writeWidgetStateStopped()
    }

    /// Handles `keepresso://` URLs (registered via `CFBundleURLTypes` in
    /// project.yml), e.g. from Shortcuts, Raycast, or a shell script. AppKit
    /// calls this for a background agent even with no window open, which
    /// `.onOpenURL` (Scene/View-scoped) can't guarantee for a `MenuBarExtra`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = URLCommand.parse(url) else { continue }
            model.handle(command)
        }
    }
}
