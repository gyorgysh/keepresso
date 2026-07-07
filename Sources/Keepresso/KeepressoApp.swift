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
            MenuBarLabelView(model: appDelegate.model)
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

        // Shown once on first launch (see `MenuBarLabelView`) and reopenable from
        // the menu via `openWindow(id: "welcome")`.
        Window("Welcome to Keepresso", id: Self.welcomeWindowID) {
            WelcomeView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
    }

    /// Scene ids shared with the menu's window-opening buttons.
    static let setupWindowID = "setup"
    static let streamingWindowID = "streaming"
    static let preferencesWindowID = "preferences"
    static let aboutWindowID = "about"
    static let welcomeWindowID = "welcome"
}

/// The menu-bar icon, plus a one-shot trigger that opens the welcome window on
/// the very first launch. The label view is alive from launch (the icon shows
/// immediately), unlike the dropdown content, which is built lazily on first
/// click, so a launch-time open belongs here. Guarded by ``AppModel/hasOnboarded``,
/// which `WelcomeView.onAppear` flips: consuming the one-shot only once the
/// window is really on screen means a launch that never shows it (a failed
/// open, or the relocation hand-off below) doesn't burn the first run.
private struct MenuBarLabelView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabel(session: model.session, showCountdown: model.showCountdownInMenuBar)
            .task {
                guard !model.hasOnboarded else { return }
                // First launch from a DMG: this instance is about to copy
                // itself to /Applications and quit. Flashing the welcome here
                // would persist hasOnboarded into the shared defaults and the
                // relaunched copy, the one fresh installs actually keep,
                // would never show it.
                guard !AppRelocator.isRelocating else { return }
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: KeepressoApp.welcomeWindowID)
            }
    }
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
            self?.model.closedDisplayAutoTick()
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
        // Same for the closed-display sleep watchdog's flag.
        Task { await model.closedDisplayAuto.cleanupAtLaunch() }
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
