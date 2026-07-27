import SwiftUI
import KeepressoCore

/// Keepresso is a menu-bar agent (`LSUIElement`): no Dock icon, no main window.
/// The entire UI lives in a `MenuBarExtra`.
@main
struct KeepressoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: appDelegate.model, updater: appDelegate.updater, bridge: appDelegate.statusItemBridge)
        } label: {
            MenuBarLabelView(model: appDelegate.model, bridge: appDelegate.statusItemBridge)
        }
        .menuBarExtraStyle(.window)

        // Every window opts out of external events (`handlesExternalEvents`
        // with an empty set): `keepresso://` URLs are fully handled by the
        // AppDelegate, and without the opt-out SwiftUI answers a URL open
        // that no scene claims (the automation doorbell, a Shortcuts
        // command) by presenting the first declared window, popping the
        // Setup checklist over whatever the user is doing.

        // The headless-readiness Setup checklist, opened from the menu via
        // `openWindow(id: "setup")`.
        Window("Keepresso Setup", id: Self.setupWindowID) {
            SetupView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Window("Gaming & Streaming", id: Self.streamingWindowID) {
            StreamingSetupView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Window("Preferences", id: Self.preferencesWindowID) {
            PreferencesView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Window("About Keepresso", id: Self.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        // Opened automatically (from `MenuBarLabelView`) when the helper
        // daemon's self-heal needs the user: approve once more, or reinstall.
        Window("Keepresso Helper", id: Self.helperWindowID) {
            HelperAttentionView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        // Shown once on first launch (see `MenuBarLabelView`) and reopenable from
        // the menu via `openWindow(id: "welcome")`.
        Window("Welcome to Keepresso", id: Self.welcomeWindowID) {
            WelcomeView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])
    }

    /// Scene ids shared with the menu's window-opening buttons.
    static let setupWindowID = "setup"
    static let streamingWindowID = "streaming"
    static let preferencesWindowID = "preferences"
    static let aboutWindowID = "about"
    static let welcomeWindowID = "welcome"
    static let helperWindowID = "helper"
}

/// The menu-bar icon, plus a one-shot trigger that opens the welcome window on
/// the very first launch. The label view is alive from launch (the icon shows
/// immediately), unlike the dropdown content, which is built lazily on first
/// click, so a launch-time open belongs here. Guarded by ``AppModel/hasOnboarded``,
/// which only the welcome's Get Started button flips: a launch that never
/// shows the window (a failed open, or the relocation hand-off below), or one
/// where the user closes it without confirming (a language-switch relaunch),
/// doesn't burn the first run.
private struct MenuBarLabelView: View {
    @Bindable var model: AppModel
    let bridge: StatusItemBridge
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabel(session: model.session, showCountdown: model.showCountdownInMenuBar)
            .task {
                // The context menu's window entries need openWindow, which
                // only exists inside SwiftUI; this is the app's one always
                // alive view, so it lends its environment to the bridge.
                bridge.openWindow = { openWindow(id: $0) }
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
            // The helper self-heal got stuck on a step only the user can do:
            // walk them through it. This view is the app's one always-alive
            // view, so the edge is caught no matter what else is open.
            .onChange(of: model.helperAttention) { _, attention in
                guard attention != nil else { return }
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: KeepressoApp.helperWindowID)
            }
    }
}

/// Owns the long-lived ``AppModel`` (settings + session) and the per-second
/// ticker so they outlive any transient menu UI.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    /// Sparkle-backed auto-updater, behind the ``Updating`` seam. Started here so
    /// it schedules background checks for the app's whole lifetime.
    let updater: any Updating = SparkleUpdater()
    /// Right-click context menu on the menu-bar icon (see ``StatusItemBridge``).
    private(set) lazy var statusItemBridge = StatusItemBridge(updater: updater)

    override init() {
        // Keep the AppleLanguages override consistent with the recorded
        // language choice (repairs a defaults edit from outside the app;
        // affects the next launch, this process already resolved its locale).
        AppLanguage.syncAtLaunch()
        // Order matters: constructing AppModel builds HelperManager, whose
        // first SMAppService status read is already a BTM contact, and BTM
        // revalidates the helper's record on contact. Any old copy of the app
        // that an update pushed into the Trash must be deleted before that
        // moment, or the record resolves into the Trash and macOS disables
        // the daemon behind our back.
        let updated = UpdateArrival.checkAndRecord()
        StaleBundleCleaner.sweepAtStartup(afterUpdate: updated)
        model = AppModel(appUpdatedSinceLastRun: updated)
        super.init()
        // After AppModel: its notifier is the notification-center delegate,
        // without which a banner posted mid-launch is silently dropped.
        StaleBundleCleaner.notifyIfSweepNeedsUser()
    }
    private lazy var ticker = SessionTicker(
        session: model.session,
        disk: model.disk,
        closedDisplay: model.closedDisplay,
        thermalGuard: model.thermalGuard,
        onThermalEffects: { [weak self] in self?.model.handleThermalEffects($0) },
        onTick: { [weak self] in
            self?.model.syncWidgetState()
            self?.model.awdlAutoTick()
            self?.model.closedDisplayAutoTick()
            self?.model.thermalAvailabilityTick()
            self?.model.fireAgentIdleHookIfNeeded()
            self?.model.automationSyncTick()
            self?.model.pulseMenuPanelIfVisible()
        }
    )
    /// Listens for the Control Center toggle's Darwin doorbell.
    private var widgetObserver: WidgetCommandObserver?
    /// Set when this launch is a duplicate handing over to an already running
    /// copy (see ``yieldIfDuplicateInstance()``). The terminate that follows
    /// must not run the usual quit chores, they belong to the copy staying up.
    private var yieldingToPeer = false

    /// macOS normally refuses to launch a second instance of a running bundle,
    /// but a click on one of our notifications can make Launch Services spawn
    /// one anyway (seen after launching from Xcode): two menu-bar cups, each
    /// with its own assertions. Detect that here, before the ticker or any
    /// assertion starts, and hand back to the original instead.
    func applicationWillFinishLaunching(_ notification: Notification) {
        yieldIfDuplicateInstance()
    }

    private func yieldIfDuplicateInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let describe: (NSRunningApplication) -> SingleInstanceGuard.Instance = {
            .init(pid: $0.processIdentifier, bundleURL: $0.bundleURL, launchDate: $0.launchDate)
        }
        let current = NSRunningApplication.current
        guard let senior = SingleInstanceGuard.peerToYieldTo(
            current: describe(current),
            peers: running.filter { $0 != current }.map(describe)
        ),
        let peer = running.first(where: { $0.processIdentifier == senior.pid })
        else { return }
        yieldingToPeer = true
        peer.activate()
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A duplicate instance is on its way out (see applicationWillFinishLaunching);
        // don't start any of the running machinery it would have to tear down.
        if yieldingToPeer { return }
        // If launched from the DMG / Downloads, move into /Applications and
        // relaunch from there (this instance quits if it relocates).
        AppRelocator.relocateIfNeeded()
        // Right-click on the menu-bar icon shows the app-entries context menu.
        statusItemBridge.install()
        // Give the Shortcuts intents their way to the live model.
        IntentContext.model = model
        // Activity history / awake stats: after the menu bar chrome is up, not
        // on AppModel.init's critical path.
        model.hydrateDecisionLog()
        // Read the closed-display (pmset disablesleep) state now: it persists
        // across reboots, and the ticker's lid handling stays inert until the
        // controller knows the mode is on, not just once a menu opens.
        model.refreshClosedDisplay(force: true)
        // Any AWDL watchdog flag surviving from a previous process is stale
        // (the loop it kept alive has already exited via its pid check).
        Task { await model.awdl.cleanupAtLaunch() }
        // Same for the closed-display sleep watchdog's flag.
        Task { await model.closedDisplayAuto.cleanupAtLaunch() }
        // The helper daemon can be "enabled" yet unlaunchable (launchd's
        // record goes stale after an app update plus a reboot); check it now,
        // and repair the registration, before the first engage fails on it.
        model.verifyHelper()
        ticker.start()
        // Register the global keep-awake toggle shortcut, if the user set one.
        model.registerHotKey()
        // Start a session right away if "Start keep-awake on launch" is on.
        model.startOnLaunchIfNeeded()
        // Re-sync wake schedules with the helper (settings survive; the system
        // schedule is the source of truth for the machine). Discover local
        // automations first so a wake persisted from a previous run is re-armed
        // in the same apply rather than dropped before the first discovery tick.
        model.primeAutomationDiscovery()
        model.applyWakeScheduleToSystem()
        model.refreshSystemWakeState()
        // Wake-and-brew: a system wake near a Keepresso schedule can start a
        // session or apply a preset.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak model] _ in
            model?.handleSystemWake()
        }
        // The Control Center toggle: consume a command that may have launched
        // us, then keep listening while running.
        widgetObserver = WidgetCommandObserver { [weak model] in model?.applyPendingWidgetCommand() }
        model.applyPendingWidgetCommand()
        model.syncWidgetState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // "Dim, don't sleep" lowers the built-in panel's brightness, a persistent
        // display setting the OS won't restore on exit the way it releases power
        // assertions. Put it back before we go, or quitting mid-dim leaves the
        // screen dark. A no-op when nothing was dimmed, so it's safe even on the
        // yield-to-peer path below (nothing is dimmed that early).
        model.session.restoreDisplayBrightness()
        // A duplicate handing over to the copy that stays up must not write
        // "stopped" into the shared widget state: that copy owns it and may be
        // keeping the Mac awake right now.
        if yieldingToPeer { return }
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
