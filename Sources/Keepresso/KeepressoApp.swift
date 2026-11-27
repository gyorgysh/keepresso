import SwiftUI
import KeepressoCore

@main
struct KeepressoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: appDelegate.model, updater: appDelegate.updater, bridge: appDelegate.statusItemBridge)
        } label: {
            MenuBarLabelView(updater: appDelegate.updater, model: appDelegate.model, bridge: appDelegate.statusItemBridge)
        }
        .menuBarExtraStyle(.window)

        // Every window opts out of external events (`handlesExternalEvents`
        // with an empty set): `keepresso://` URLs are fully handled by the
        // AppDelegate, and without the opt-out SwiftUI answers a URL open
        // that no scene claims (the automation doorbell, a Shortcuts
        // command) by presenting the first declared window, popping the
        // Setup checklist over whatever the user is doing.

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

        Window("Keyboard Cleaner", id: Self.keyboardCleanerWindowID) {
            KeyboardCleanerView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Window("Public Wi-Fi", id: Self.wifiAssistantWindowID) {
            WifiAssistantView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Window("Preferences", id: Self.preferencesWindowID) {
            PreferencesView(updater: appDelegate.updater, model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Window("Customize Menu", id: Self.menuCustomizationWindowID) {
            MenuCustomizationView(model: appDelegate.model)
        }
        .defaultSize(width: 940, height: 800)
        .handlesExternalEvents(matching: [])

        Window("About Keepresso", id: Self.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Window("Keepresso Helper", id: Self.helperWindowID) {
            HelperAttentionView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Window("Welcome to Keepresso", id: Self.welcomeWindowID) {
            WelcomeView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])
    }

    static let setupWindowID = "setup"
    static let streamingWindowID = "streaming"
    static let keyboardCleanerWindowID = "keyboard-cleaner"
    static let wifiAssistantWindowID = "wifi-assistant"
    static let preferencesWindowID = "preferences"
    static let menuCustomizationWindowID = "menu-customization"
    static let aboutWindowID = "about"
    static let welcomeWindowID = "welcome"
    static let helperWindowID = "helper"
}

private struct MenuBarLabelView: View {
    let updater: any Updating
    @Bindable var model: AppModel
    let bridge: StatusItemBridge
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            MenuBarLabel(session: model.session, showCountdown: model.showCountdownInMenuBar,
                         presentation: model.advancedMenuLayout)
            // MenuBarExtra extracts text and images from its label; a shape
            // overlay is not a reliable status-item indicator.
            if updater.updateAvailable {
                Text(verbatim: "↑").accessibilityLabel(L("Update available…"))
            }
        }
        .help(updater.updateAvailable ? L("Update available…") : "Keepresso")
        .task {
            // The context menu's window entries need openWindow, which
            // only exists inside SwiftUI; this is the app's one always
            // alive view, so it lends its environment to the bridge.
            bridge.openWindow = { openWindow(id: $0) }
            guard !model.hasOnboarded else { return }
            guard !AppRelocator.isRelocating else { return }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: KeepressoApp.welcomeWindowID)
        }
        .onChange(of: model.helperAttention) { _, attention in
            guard attention != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: KeepressoApp.helperWindowID)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let updater: any Updating = SparkleUpdater()
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
        StaleBundleCleaner.notifyIfSweepNeedsUser()
    }
    private lazy var ticker = SessionTicker(
        session: model.session,
        disk: model.disk,
        closedDisplay: model.closedDisplay,
        thermalGuard: model.thermalGuard,
        lid: model.lidState,
        gameFrontmost: { [weak self] in self?.model.gameFrontmostForActivityPoke() ?? false },
        onThermalEffects: { [weak self] in self?.model.handleThermalEffects($0) },
        onTick: { [weak self] in
            self?.model.syncWidgetState()
            self?.model.awdlAutoTick()
            self?.model.closedDisplayAutoTick()
            self?.model.syncBatteryPauseClosedDisplay()
            self?.model.thermalAvailabilityTick()
            self?.model.fireAgentIdleHookIfNeeded()
            self?.model.automationSyncTick()
            self?.model.connectivityTick()
            self?.model.speakerMuteTick()
            self?.model.pulseMenuPanelIfVisible()
        }
    )
    private var widgetObserver: WidgetCommandObserver?
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
        if yieldingToPeer { return }
        model.keyboardLock.restoreIfNeeded()
        if model.keyboardLock.isLocked {
            model.suspendHotKeyForKeyboardLock()
            model.showKeyboardLockOverlay()
        }
        AppRelocator.relocateIfNeeded()
        statusItemBridge.install()
        IntentContext.model = model
        model.hydrateDecisionLog()
        model.refreshClosedDisplay(force: true)
        Task { await model.awdl.cleanupAtLaunch() }
        Task { await model.closedDisplayAuto.cleanupAtLaunch() }
        // The helper daemon can be "enabled" yet unlaunchable (launchd's
        // record goes stale after an app update plus a reboot); check it now,
        // and repair the registration, before the first engage fails on it.
        model.verifyHelper()
        if AppModel.runsFromApplicationsFolder {
            model.refreshAgentHookStatuses()
        }
        ticker.start()
        model.registerHotKey()
        model.startOnLaunchIfNeeded()
        model.primeAutomationDiscovery()
        model.applyWakeScheduleToSystem()
        model.refreshSystemWakeState()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak model] _ in
            // `queue: .main` guarantees the main thread; assert that to the
            // compiler rather than letting the call warn as implicitly async.
            MainActor.assumeIsolated { model?.handleSystemWake() }
        }
        widgetObserver = WidgetCommandObserver { [weak model] in model?.applyPendingWidgetCommand() }
        model.applyPendingWidgetCommand()
        model.syncWidgetState()
    }

    private var quitConfirmed = false
    private var quitModal: QuitSleepModal?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !yieldingToPeer, !AppRelocator.isRelocating, !quitConfirmed else {
            return .terminateNow
        }
        if let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)),
           reason.enumCodeValue != 0 {
            return .terminateNow
        }
        if let quitModal {
            quitModal.bringToFront()
            return .terminateCancel
        }

        let coverage = model.quitSleepCoverageNow()
        let scopedLid = model.quitScopedLidMode()
        guard coverage != .none else { return .terminateNow }

        // Cancel the termination outright and ask afterwards, rather than
        // holding it open with `.terminateLater`.
        //
        // AppKit runs `.terminateLater` in `NSModalPanelRunLoopMode`, which
        // does not deliver mouse events to an ordinary window, so the buttons
        // are dead; and a nested `runModal` is no better, because quitting
        // starts in the menu bar extra and menu tracking owns the event
        // stream. Both were tried. Cancelling puts the run loop back in its
        // default mode with no tracking session, where a plain window behaves
        // like any other, and the answer re-issues `terminate` for real.
        let modal = QuitSleepModal()
        quitModal = modal
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let device = MachineIdentity.deviceName(
                modelIdentifier: MachineIdentity.currentModelIdentifier())
            let qualifier = MachineIdentity.powerQualifier(IOKitPowerSourceMonitor().current)
            modal.present(
                coverage: coverage, device: device, qualifier: qualifier, scopedLid: scopedLid
            ) { decision in
                self.quitModal = nil
                switch decision {
                case .cancel:
                    break
                case .quitAnyway, .stopBrewingAndQuit:
                    self.quitConfirmed = true
                    NSApp.terminate(nil)
                case .turnOffAndQuit:
                    Task { @MainActor in
                        guard await self.model.clearSleepOverrideForQuit() else { return }
                        self.quitConfirmed = true
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // "Dim, don't sleep" lowers the built-in panel's brightness, a persistent
        // display setting the OS won't restore on exit the way it releases power
        // assertions. Put it back before we go, or quitting mid-dim leaves the
        // screen dark. A no-op when nothing was dimmed, so it's safe even on the
        // yield-to-peer path below (nothing is dimmed that early).
        model.session.restoreDisplayBrightness()
        model.closedDisplay.restoreDisplayBrightness()
        if !AppRelocator.isRelocating { model.speakerMute.release() }
        if yieldingToPeer { return }
        // Unlock before we go so a quit mid-wipe does not leave keys dead.
        // Deliberately the synchronous prompt-free restore: termination cannot
        // await a detached task, and a password dialog during quit would be
        // unusable.
        model.keyboardLock.restoreIfNeeded()
        // A relocate handover quits into a copy that owns the shared state
        // (an already-running one, or the fresh /Applications copy syncing at
        // launch): writing "stopped" here would lie over its live state. Any
        // other quit owns the write: the session dies with this process, so
        // don't leave the widgets lying.
        guard !AppRelocator.isRelocating else { return }
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
