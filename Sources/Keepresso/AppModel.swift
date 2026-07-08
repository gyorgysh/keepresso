import AppKit
import Observation
import UserNotifications
import KeepressoCore

/// App-level glue around ``SessionController``: owns persisted settings, builds
/// the live trigger engine from saved rules, and keeps the two in sync.
///
/// The controller stays UI-free and persistence-free (it lives in
/// `KeepressoCore`); this `@Observable` model is the thin app-side layer that
/// loads/saves ``KeepressoSettings`` and re-derives the controller's
/// ``SessionController/triggerGate`` whenever the rule set changes.
@MainActor
@Observable
final class AppModel {
    let session: SessionController
    let disk: DiskKeepAliveController
    /// Controls closed-display mode (the global `pmset disablesleep` setting that
    /// keeps the Mac awake with the lid shut). Its state is read live from the
    /// system, so nothing about it is persisted in ``KeepressoSettings``.
    /// Writes route through the privileged helper daemon when it's installed
    /// (no prompt) and through the osascript admin prompt otherwise.
    let closedDisplay: ClosedDisplayController
    /// Closed-display mode's "only while brewing" automation: flips
    /// `disablesleep` on when the session starts and off when it ends. Holds
    /// go through the helper daemon when installed (never a prompt); the
    /// fallback is the session-scoped root loop (one admin prompt per app run).
    let closedDisplayAuto: ClosedDisplayAutoController
    /// Backs the headless-readiness Setup screen. Populated on demand via
    /// ``refreshReadiness()``, empty until the Setup window first appears.
    let readiness = SystemReadinessController()
    /// Experimental headless virtual display (private CoreGraphics API), off by
    /// default. Uses the real backend; `nil` config means no virtual display.
    let virtualDisplay = VirtualDisplayController(backend: CGVirtualDisplayBackend())
    /// Backs the Gaming & Streaming Setup screen's check list. Populated on
    /// demand via ``refreshStreaming()``, like ``readiness``.
    let streaming = StreamingReadinessController()
    /// The built-in AWDL jitter diagnosis (ping burst + analysis).
    let jitter = JitterTestController()
    /// The AWDL watchdog: the helper daemon when installed, else the
    /// session-scoped root loop behind one admin prompt per app run.
    let awdl: AWDLWatchdogController
    /// Registration and status of the privileged helper daemon, the one-time
    /// password alternative to the per-run osascript prompts.
    let helper: HelperManager

    private let store: SettingsStore
    private let notifier: UserNotificationReminder
    private(set) var settings: KeepressoSettings

    /// The default reminder interval used when the feature is first enabled.
    static let defaultReminderAfter: TimeInterval = 30 * 60

    init(
        store: SettingsStore = UserDefaultsSettingsStore(),
        factory: TriggerFactory = TriggerFactory()
    ) {
        self.store = store
        self.gate = TriggerGateController(factory: factory)
        let notifier = UserNotificationReminder()
        self.notifier = notifier
        // The privileged seams route through the helper daemon whenever it's
        // installed (silent XPC, no prompt) and fall back to the original
        // osascript admin prompts otherwise. The availability box is the
        // thread-safe bridge: the manager writes it, the detached-task
        // closures read it at each engage.
        let helperClient = XPCHelperClient()
        let helperManager = HelperManager(client: helperClient)
        self.helper = helperManager
        let helperInstalled: @Sendable () -> Bool = { [availability = helperManager.availability] in
            availability.isEnabled
        }
        self.closedDisplay = ClosedDisplayController(
            control: RoutedSleepControl(
                helper: helperClient,
                fallback: PMSetSleepControl(),
                helperInstalled: helperInstalled
            )
        )
        self.closedDisplayAuto = ClosedDisplayAutoController(
            launcher: RoutedSleepWatchdog(
                daemon: HelperDaemonSleepWatchdog(helper: helperClient),
                fallback: OsascriptSleepWatchdog(),
                helperInstalled: helperInstalled
            )
        )
        self.awdl = AWDLWatchdogController(
            launcher: RoutedAWDLWatchdog(
                daemon: HelperDaemonAWDLWatchdog(helper: helperClient),
                fallback: OsascriptAWDLWatchdog(),
                helperInstalled: helperInstalled
            )
        )
        var loaded = store.load()
        loaded.seedNewBuiltInPresets() // new built-ins reach existing users once
        self.settings = loaded
        self.session = SessionController(reminder: notifier)
        self.session.options = loaded.options
        self.session.reminderAfter = loaded.reminderAfter
        self.session.reminderRepeats = loaded.reminderRepeats
        self.session.reminderSound = loaded.reminderSound
        self.session.notifyOnEnd = loaded.notifyOnEnd
        self.session.endAction = loaded.endAction
        self.session.pauseBelowBatteryPercent = loaded.pauseBelowBatteryPercent
        self.disk = DiskKeepAliveController()
        self.disk.config = loaded.diskKeepAlive
        self.virtualDisplay.config = loaded.virtualDisplay
        self.awdl.autoWithGaming = loaded.awdlAutoWithGaming
        self.gamingWatcher.grace = loaded.awdlGraceSeconds
        self.closedDisplayAuto.onlyWhileBrewing = loaded.closedDisplayOnlyWhileBrewing
        // With one of the auto features on and no helper installed, this run
        // can hit a password prompt in the background (e.g. a trigger-started
        // session engaging "Only while brewing"). Its "Keepresso needs your
        // password" notification only shows if we're authorized to post it, so
        // secure that now rather than in the same instant the prompt appears.
        // A no-op once the user has decided either way.
        if !helperManager.isInstalled,
           loaded.closedDisplayOnlyWhileBrewing || loaded.awdlAutoWithGaming {
            notifier.requestAuthorization()
        }
        // Launch idle: a manual session waits for the user's toggle, a gated
        // one waits for its conditions (the ticker's reconcile activates it).
        applyTriggerGate()
        // Give the decision log the satisfied rule labels when the gate flips
        // the session on ("Triggers: Camera in use").
        session.triggerDescriber = { [weak self] in
            guard let states = self?.ruleStates() else { return nil }
            let held = states.filter(\.satisfied).map(\.rule.label)
            return held.isEmpty ? nil : held.joined(separator: ", ")
        }
    }

    // MARK: - Awake explainer

    /// Reads the system-wide power assertion list for the Activity pane.
    @ObservationIgnored private let assertionLister: AssertionListing = IOPMAssertionLister()

    /// Every power assertion currently held by any process (why the Mac is
    /// awake right now, whoever's doing it). Read on demand by the UI.
    func currentAssertions() -> [PowerAssertionInfo] {
        assertionLister.current()
    }

    /// The most relevant power assertion held by some *other* process, for the
    /// dropdown's "who else is keeping the Mac awake" line. `nil` when only
    /// Keepresso (or nothing) is holding one. Lets the menu explain a Mac that
    /// won't sleep even while Keepresso is idle.
    func topExternalAssertion() -> PowerAssertionInfo? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        return currentAssertions().first { $0.effect != nil && $0.pid != myPID }
    }

    // MARK: - Manual activation

    /// Flip keep-awake by hand (the global hotkey and the menu switch), starting
    /// with the saved duration.
    ///
    /// If triggers are actively gating the session, pause them first, the same
    /// in-memory pause the menu's Pause Triggers uses and that ``handle(_:)``
    /// applies to URL and widget commands. Without it a bare start/stop here
    /// would be undone by the gate on the very next reconcile (once a second),
    /// so a hotkey press would appear to spring back. After pausing, the menu
    /// shows "Triggers paused / Resume Triggers" and control stays manual until
    /// the user resumes or relaunches (the pause isn't persisted). The pause is
    /// a no-op when triggers are off or already paused, so the menu switch (only
    /// reachable in those states) behaves exactly as before.
    func toggleManual() {
        let wasActive = session.isActive
        pauseTriggers()
        if wasActive {
            session.stop()
        } else {
            session.start(mode: settings.defaultMode)
        }
    }

    /// Start (or restart) a session running until the next occurrence of a
    /// wall-clock time. The duration is computed here, at start, so it always
    /// lands on the chosen time; the choice is deliberately not persisted as
    /// the default mode (a saved "until 18:00" would go stale by tomorrow).
    func startUntil(hour: Int, minute: Int) {
        guard let mode = SessionMode.until(hour: hour, minute: minute) else { return }
        session.start(mode: mode)
    }

    // MARK: - Keep-awake options

    /// Whether the session also reports user activity to the OS, defeating
    /// app-level and enterprise idle detection (remote desktop, meeting
    /// presence, corporate idle-logout). Off by default.
    var simulateUserActivity: Bool {
        get { session.options.simulateUserActivity }
        set { updateOptions { $0.simulateUserActivity = newValue } }
    }

    /// Mutate the keep-awake options, mirror into settings, and persist.
    func updateOptions(_ mutate: (inout SleepPreventionOptions) -> Void) {
        var options = session.options
        mutate(&options)
        session.options = options
        settings.options = options
        persist()
    }

    // MARK: - Session mode (manual sessions)

    /// The chosen duration. While idle it reflects the saved default (so the
    /// picker shows it before activating); while active it restarts the session.
    var mode: SessionMode {
        get { session.isActive ? session.mode : settings.defaultMode }
        set {
            settings.defaultMode = newValue
            if session.isActive { session.start(mode: newValue) }
            persist()
        }
    }

    // MARK: - Triggers

    var triggersEnabled: Bool {
        get { settings.triggersEnabled }
        set {
            settings.triggersEnabled = newValue
            triggersPaused = false // always starts unpaused
            // Stop on both transitions: turning gating on hands activation to
            // the gate; turning it off would otherwise leave a gate-held
            // session running as a "manual" one with a stale duration.
            session.stop()
            applyTriggerGate()
            persist()
        }
    }

    /// Whether trigger gating is temporarily suspended in favor of the manual
    /// toggle. In-memory only (not part of ``KeepressoSettings``): quitting and
    /// relaunching Keepresso always comes back unpaused.
    private(set) var triggersPaused = false

    /// Suspend trigger gating and stop the session right away: pausing is
    /// meant to answer "let my Mac sleep for now", not just hand the wheel to
    /// the manual toggle while leaving it brewing. Control reverts to the
    /// manual toggle (so it can be turned back on by hand) until
    /// ``resumeTriggers()``. No-op if triggers aren't on or already paused.
    ///
    /// `cause` labels the stop in the decision log. It defaults to `.manual`
    /// (the menu's Pause Triggers button); ``handle(_:)`` passes `.command` so a
    /// URL / Shortcuts / widget stop that has to pause a trigger-held session
    /// first isn't misattributed as a manual stop.
    func pauseTriggers(cause: SessionCause = .manual) {
        guard settings.triggersEnabled, !triggersPaused else { return }
        triggersPaused = true
        applyTriggerGate()
        session.stop(cause: cause)
    }

    /// Hand activation back to the trigger engine. No-op if not currently paused.
    func resumeTriggers() {
        guard triggersPaused else { return }
        triggersPaused = false
        applyTriggerGate()
    }

    var combine: CombineMode {
        get { settings.ruleSet.combine }
        set { settings.ruleSet.combine = newValue; applyTriggerGate(); persist() }
    }

    var rules: [TriggerRule] { settings.ruleSet.rules }

    func addRule(_ rule: TriggerRule) {
        guard !settings.ruleSet.rules.contains(rule) else { return }
        settings.ruleSet.rules.append(rule)
        applyTriggerGate()
        persist()
    }

    func removeRule(at index: Int) {
        guard settings.ruleSet.rules.indices.contains(index) else { return }
        settings.ruleSet.rules.remove(at: index)
        applyTriggerGate()
        persist()
    }

    func updateRule(at index: Int, to rule: TriggerRule) {
        guard settings.ruleSet.rules.indices.contains(index) else { return }
        settings.ruleSet.rules[index] = rule
        applyTriggerGate()
        persist()
    }

    /// Prompt for a folder to watch for in-progress downloads and add a rule for
    /// it (defaults to ~/Downloads). The panel only opens on this explicit click,
    /// never on window open; picking a folder grants access with no permission
    /// prompt (the app is unsandboxed, so the plain URL persists). Cancelling
    /// adds nothing.
    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Watch"
        panel.message = "Keep awake while downloads are in progress in this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addRule(.downloadInFolder(url))
    }

    /// Owns the live engine gating the session and the menu's rule-state cache.
    @ObservationIgnored private let gate: TriggerGateController

    /// Rebuild (or tear down) the controller's gate to match current settings,
    /// then wire it to the session (nil while paused, so the manual toggle owns
    /// activation). The reuse of live triggers across rebuilds lives in
    /// ``TriggerGateController``.
    private func applyTriggerGate() {
        gate.rebuild(
            rules: settings.ruleSet.rules,
            combine: settings.ruleSet.combine,
            enabled: settings.triggersEnabled
        )
        session.triggerGate = (settings.triggersEnabled && !triggersPaused) ? gate.engine : nil
    }

    /// Live satisfaction of each saved rule, aligned with ``rules`` order, or
    /// `nil` when trigger gating is off. Drives the menu's next-trigger summary.
    func ruleStates() -> [RuleState]? {
        gate.ruleStates()
    }

    /// One-line summary of trigger state for the menu header: what's holding the
    /// session on, or what it's waiting for. `nil` when not gated or no rules.
    func triggerSummary() -> String? {
        guard let states = ruleStates(), !states.isEmpty else { return nil }
        func conditions(_ count: Int) -> String { "\(count) condition\(count == 1 ? "" : "s")" }
        if session.isActive {
            // The per-condition list is shown right below, so summarize by count
            // instead of repeating each label.
            let held = states.filter(\.satisfied).count
            return held == 0 ? "Active" : "Held by \(conditions(held))"
        }
        switch settings.ruleSet.combine {
        case .any:
            return "Waiting for any condition"
        case .all:
            let pending = states.filter { !$0.satisfied }.count
            return "Waiting on \(conditions(pending))"
        }
    }

    // MARK: - Reminder

    /// Whether the "still brewing" reminder is on. Enabling it requests
    /// notification permission and seeds a default interval.
    var reminderEnabled: Bool {
        get { settings.reminderAfter != nil }
        set {
            settings.reminderAfter = newValue
                ? (settings.reminderAfter ?? Self.defaultReminderAfter)
                : nil
            if newValue { notifier.requestAuthorization() }
            session.reminderAfter = settings.reminderAfter
            persist()
        }
    }

    /// The reminder interval shown in the picker. Reads the default while the
    /// feature is off so the picker has a sensible selection before enabling.
    var reminderAfter: TimeInterval {
        get { settings.reminderAfter ?? Self.defaultReminderAfter }
        set {
            settings.reminderAfter = newValue
            session.reminderAfter = newValue
            persist()
        }
    }

    /// Whether the reminder repeats every interval (vs. firing once).
    var reminderRepeats: Bool {
        get { settings.reminderRepeats }
        set {
            settings.reminderRepeats = newValue
            session.reminderRepeats = newValue
            persist()
        }
    }

    /// Whether the reminder also plays a sound.
    var reminderSound: Bool {
        get { settings.reminderSound }
        set {
            settings.reminderSound = newValue
            session.reminderSound = newValue
            persist()
        }
    }

    /// Whether a notification fires when a session ends on its own. Enabling it
    /// requests notification permission (same as the reminder).
    var notifyOnEnd: Bool {
        get { settings.notifyOnEnd }
        set {
            settings.notifyOnEnd = newValue
            session.notifyOnEnd = newValue
            if newValue { notifier.requestAuthorization() }
            persist()
        }
    }

    /// What Keepresso does to the Mac when a session ends on its own.
    var endAction: SessionEndAction {
        get { settings.endAction }
        set {
            settings.endAction = newValue
            session.endAction = newValue
            persist()
        }
    }

    // MARK: - Battery-aware auto-pause

    /// The default cutoff used when the feature is first enabled.
    static let defaultPauseBelowBatteryPercent = 20

    /// Whether an active session force-stops (letting the Mac sleep) once
    /// battery charge drops below ``pauseBelowBatteryPercent``.
    var batteryAutoPauseEnabled: Bool {
        get { settings.pauseBelowBatteryPercent != nil }
        set {
            settings.pauseBelowBatteryPercent = newValue
                ? (settings.pauseBelowBatteryPercent ?? Self.defaultPauseBelowBatteryPercent)
                : nil
            session.pauseBelowBatteryPercent = settings.pauseBelowBatteryPercent
            persist()
        }
    }

    /// The cutoff percentage shown in the picker (the default while off).
    var pauseBelowBatteryPercent: Int {
        get { settings.pauseBelowBatteryPercent ?? Self.defaultPauseBelowBatteryPercent }
        set {
            settings.pauseBelowBatteryPercent = newValue
            session.pauseBelowBatteryPercent = newValue
            persist()
        }
    }

    // MARK: - Global hotkey

    /// Registers the system-wide keep-awake toggle shortcut.
    @ObservationIgnored private let hotKeyManager = GlobalHotKeyManager()

    /// The system-wide shortcut that toggles keep-awake, or `nil` for none.
    /// Setting it re-registers the live hotkey and persists.
    var hotKey: HotKeyShortcut? {
        get { settings.hotKey }
        set {
            settings.hotKey = newValue
            persist()
            registerHotKey()
        }
    }

    /// (Re)register the global hotkey from the saved shortcut. Called at launch
    /// and whenever the shortcut changes.
    func registerHotKey() {
        hotKeyManager.update(to: settings.hotKey) { [weak self] in self?.toggleManual() }
    }

    // MARK: - Start on launch

    /// Whether a manual session starts as soon as the app launches (when
    /// triggers aren't gating activation).
    var startOnLaunch: Bool {
        get { settings.startOnLaunch }
        set { settings.startOnLaunch = newValue; persist() }
    }

    /// Start a manual session at launch if the user asked for it. Skipped when
    /// triggers own activation (the gate would fight it) or a session is already
    /// running. Called once from the app delegate after relocation.
    func startOnLaunchIfNeeded() {
        guard settings.startOnLaunch, !settings.triggersEnabled, !session.isActive else { return }
        session.start(mode: settings.defaultMode)
    }

    // MARK: - First-run onboarding

    /// Whether the first-run welcome window has been shown. Set `true` the first
    /// time it opens so it appears exactly once; the menu can reopen it anytime.
    var hasOnboarded: Bool {
        get { settings.hasOnboarded }
        set { settings.hasOnboarded = newValue; persist() }
    }

    /// The current notification authorization status, so the welcome window can
    /// show whether notifications are already granted, not yet asked, or denied,
    /// rather than blindly offering "Enable".
    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Request notification permission and report the resulting status. Prompts
    /// only on this explicit call (never on window open) and no-ops once decided;
    /// the welcome window uses the returned status to reflect the real outcome.
    @discardableResult
    func requestNotificationAuthorization() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await center.notificationSettings().authorizationStatus
    }

    // MARK: - Menu-bar countdown

    /// Whether the menu-bar icon shows a live countdown for timed sessions.
    var showCountdownInMenuBar: Bool {
        get { settings.showCountdownInMenuBar }
        set {
            settings.showCountdownInMenuBar = newValue
            persist()
        }
    }

    // MARK: - Presets

    /// Saved trigger-rule bundles, in display order.
    var presets: [Preset] { settings.presets }

    /// Replace the current rule set with a preset's, turn on trigger gating,
    /// and rebuild the live engine.
    func applyPreset(_ preset: Preset) {
        settings.ruleSet = preset.ruleSet
        settings.triggersEnabled = true
        triggersPaused = false
        applyTriggerGate()
        persist()
    }

    /// Save the current rule set under a new name.
    func saveCurrentRulesAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.presets.append(Preset(name: trimmed, ruleSet: settings.ruleSet))
        persist()
    }

    /// Remove a saved preset (built-in or user-created).
    func removePreset(_ preset: Preset) {
        settings.presets.removeAll { $0.id == preset.id }
        persist()
    }

    /// Built-in presets the user has deleted, which ``restoreDefaultPresets()``
    /// can bring back. Empty when every built-in is present.
    var missingBuiltInPresets: [Preset] { settings.missingBuiltInPresets }

    /// Re-add any deleted built-in presets, leaving user-created and renamed
    /// presets untouched.
    func restoreDefaultPresets() {
        settings.restoreMissingBuiltInPresets()
        persist()
    }

    // MARK: - Settings export / import

    /// Encode the current configuration (options, triggers, reminder, presets,
    /// everything in ``KeepressoSettings``) as a portable, version-stamped JSON
    /// export the user can back up or move to another Mac.
    func exportSettingsData() throws -> Data {
        try SettingsTransfer.exportData(settings, appVersion: AppInfo.version)
    }

    /// Replace the entire live configuration with an imported settings file,
    /// then re-derive everything that hangs off settings. Throws a
    /// ``SettingsTransferError`` if `data` isn't a valid Keepresso export,
    /// leaving the current configuration untouched.
    func importSettings(from data: Data) throws {
        var imported = try SettingsTransfer.importSettings(from: data)
        // An export from an older build can predate built-ins added since; seed
        // them the same way launch does so the import isn't missing new defaults.
        imported.seedNewBuiltInPresets()
        apply(imported)
    }

    /// Adopt a wholesale-new settings value and push every derived piece of
    /// state into the controller/backends that own it, mirroring ``init``. The
    /// piecemeal setters elsewhere each re-derive only their own slice; this is
    /// the one path that swaps the lot at once (import).
    ///
    /// Ends any running session first: the new config takes over cleanly, the
    /// same reason the ``triggersEnabled`` setter stops (a gate-held session
    /// must not linger as a manual one with a stale duration once the rules
    /// that were holding it are gone).
    private func apply(_ newSettings: KeepressoSettings) {
        session.stop()
        settings = newSettings
        session.options = newSettings.options
        session.reminderAfter = newSettings.reminderAfter
        session.reminderRepeats = newSettings.reminderRepeats
        session.reminderSound = newSettings.reminderSound
        session.notifyOnEnd = newSettings.notifyOnEnd
        session.endAction = newSettings.endAction
        session.pauseBelowBatteryPercent = newSettings.pauseBelowBatteryPercent
        disk.config = newSettings.diskKeepAlive
        virtualDisplay.config = newSettings.virtualDisplay
        awdl.autoWithGaming = newSettings.awdlAutoWithGaming
        closedDisplayAuto.onlyWhileBrewing = newSettings.closedDisplayOnlyWhileBrewing
        if !newSettings.closedDisplayOnlyWhileBrewing {
            // An import that turns the automation off must also release any
            // hold it had (autoTick won't, it early-returns once it's off).
            Task { await closedDisplayAuto.stopIfHolding() }
        }
        triggersPaused = false // a fresh config always comes in unpaused, like launch
        applyTriggerGate()
        registerHotKey()
        persist()
    }

    // MARK: - Control Center widget bridge

    /// Writes session state to the App Group and reloads the widgets.
    @ObservationIgnored private let widgetSync = WidgetStateSync()

    /// Mirror the session state into the App Group and refresh the widgets.
    /// Called from the ticker every second; cheap because it no-ops until the
    /// state actually changes. `endsAt` is rounded to a whole second so the
    /// per-tick recomputation lands on the same instant and doesn't defeat the
    /// change check.
    func syncWidgetState() {
        let endsAt = session.remaining.map {
            Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate + $0).rounded())
        }
        widgetSync.write(SharedSessionState(
            isActive: session.isActive,
            endsAt: endsAt,
            triggersEnabled: settings.triggersEnabled,
            triggersPaused: triggersPaused
        ))
    }

    /// On quit, leave the widgets showing "off": the session's assertions die
    /// with this process, and a stale "Brewing" tile would lie until the next
    /// launch.
    func writeWidgetStateStopped() {
        widgetSync.write(SharedSessionState(
            isActive: false,
            triggersEnabled: settings.triggersEnabled,
            triggersPaused: triggersPaused
        ))
    }

    /// Consume a pending widget command, if any, and drive the app through the
    /// same seams the menu bar uses. Called when a widget's Darwin
    /// notification arrives and once at launch (the Control Center intent
    /// opens the app, so a not-yet-running app lands here with the command
    /// waiting).
    func applyPendingWidgetCommand() {
        guard let command = widgetSync.consumeCommand() else { return }
        switch command {
        case .start:
            if !session.isActive { handle(.start(mode: settings.defaultMode)) }
        case .stop:
            if session.isActive { handle(.stop) }
        case .pauseTriggers:
            // .command, not the default .manual: the decision log should say
            // a widget did it, matching the start/stop cases above.
            pauseTriggers(cause: .command)
        case .resumeTriggers:
            resumeTriggers()
        }
        syncWidgetState()
    }

    // MARK: - URL scheme commands

    /// Handle a `keepresso://` command from ``URLCommand/parse(_:)``. Acts like
    /// the manual toggle/duration picker. When trigger gating is on it pauses
    /// triggers first (the same in-memory pause as the menu's Pause Triggers,
    /// nothing persisted): otherwise the gate would silently override the
    /// command on the next once-a-second reconcile, turning it into a no-op
    /// with no feedback to the script that fired it.
    func handle(_ command: URLCommand) {
        // Capture before pausing: pauseTriggers() stops the session. Pass
        // .command so pausing a trigger-held session logs the stop as the
        // command that caused it, not "Stopped manually".
        let wasActive = session.isActive
        pauseTriggers(cause: .command)
        switch command {
        case .start(let mode):
            session.start(mode: mode, cause: .command)
        case .stop:
            session.stop(cause: .command)
        case .toggle:
            // Mirror toggleManual(), using the saved default duration rather
            // than the controller's in-memory mode (never seeded after launch).
            if wasActive {
                session.stop(cause: .command)
            } else {
                session.start(mode: settings.defaultMode, cause: .command)
            }
        }
    }

    // MARK: - Disk keep-alive

    /// Whether a disk is being kept spun up.
    var diskKeepAliveEnabled: Bool { settings.diskKeepAlive != nil }

    /// The folder being touched, or `nil` when off.
    var diskKeepAliveDirectory: URL? { settings.diskKeepAlive?.directory }

    /// The touch cadence shown in the picker (default while off).
    var diskKeepAliveInterval: TimeInterval {
        get { settings.diskKeepAlive?.interval ?? DiskKeepAliveConfig.defaultInterval }
        set {
            guard var config = settings.diskKeepAlive else { return }
            config.interval = newValue
            setDiskConfig(config)
        }
    }

    /// Prompt for a folder and start keeping its volume spun up. Keeps the
    /// current interval; cancelling leaves the feature unchanged.
    func chooseDiskFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Keep Awake"
        panel.message = "Choose a folder on the disk you want to keep spun up."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDiskConfig(DiskKeepAliveConfig(directory: url, interval: diskKeepAliveInterval))
    }

    /// Turn the feature off.
    func disableDiskKeepAlive() { setDiskConfig(nil) }

    private func setDiskConfig(_ config: DiskKeepAliveConfig?) {
        settings.diskKeepAlive = config
        disk.config = config
        persist()
    }

    private func persist() { store.save(settings) }

    // MARK: - Closed-display mode

    /// Re-read the system sleep setting that backs the closed-display toggle.
    /// Non-blocking: the underlying `pmset` read runs off the main thread.
    func refreshClosedDisplay() { Task { await closedDisplay.refresh() } }

    // MARK: - Privileged helper

    /// Whether the helper daemon is installed and approved, so the privileged
    /// toggles are prompt-free.
    var helperInstalled: Bool { helper.isInstalled }

    /// Register the helper daemon (opens System Settings for the one-time
    /// approval when macOS wants it).
    func installHelper() {
        helper.install()
    }

    /// Unregister the helper daemon. Any live holds are released first, so
    /// nothing stays held by a service that's going away; the osascript
    /// fallback takes over from the next engage.
    func removeHelper() {
        Task {
            await closedDisplayAuto.stopIfHolding()
            await awdl.stop()
            await helper.uninstall()
        }
    }

    /// Why the helper attention window is up: the automatic repair got stuck
    /// on something only the user can do.
    enum HelperAttention: Equatable {
        /// macOS wants the one-time approval again (Login Items switch).
        case needsApproval
        /// The daemon stayed unresponsive after a repair; offer a reinstall.
        case broken
    }

    /// Set when the helper self-heal needs the user (approve again, or
    /// reinstall); the always-alive menu bar label opens the attention window
    /// on this edge. Cleared once a check comes back healthy or the user
    /// dismisses the window.
    private(set) var helperAttention: HelperAttention?

    /// Check that the installed helper daemon actually responds, repairing a
    /// stale registration when it doesn't (see
    /// ``HelperManager/verifyAndRepairIfNeeded()``). Called at launch, where
    /// the breakage typically surfaces (it follows an app update plus a
    /// reboot), and again from the failure edges of the privileged features.
    func verifyHelper() {
        Task { await verifyHelperAndFollowUp() }
    }

    private func verifyHelperAndFollowUp() async {
        switch await helper.verifyAndRepairIfNeeded() {
        case .healthy:
            helperAttention = nil
        case .notApplicable:
            // Mid-reinstall the status parks at requiresApproval; keep the
            // window on the approval step rather than declaring success.
            helperAttention = helper.awaitingApproval ? .needsApproval : nil
        case .repaired:
            // Healed silently; let features a failed engage put on hold try
            // again on their next tick instead of waiting out the session.
            helperAttention = nil
            closedDisplayAuto.retryEngage()
            awdl.retryEngage()
        case .needsApproval:
            helperAttention = .needsApproval
            // Also say so in a notification: the attention window can land
            // behind whatever the user is doing at login.
            notifier.notify(
                title: "Keepresso needs a new approval",
                body: "macOS lost the helper's registration. Turn Keepresso back on under Login Items in System Settings to keep the password-free helper.",
                sound: true
            )
        case .broken:
            helperAttention = .broken
        }
    }

    /// The user closed the attention window; stop pointing at it. The helper's
    /// state itself stays visible in Preferences.
    func dismissHelperAttention() {
        helperAttention = nil
    }

    /// A fresh start for a helper the automatic repair couldn't revive:
    /// release any holds, unregister, and register again. May land in
    /// `requiresApproval`, which the attention window walks the user through.
    func reinstallHelper() {
        Task {
            await closedDisplayAuto.stopIfHolding()
            await awdl.stop()
            await helper.uninstall()
            helper.install()
            await verifyHelperAndFollowUp()
        }
    }

    // MARK: - Closed-display mode

    /// Whether the Mac is currently kept awake with the lid closed.
    var closedDisplayEnabled: Bool { closedDisplay.isEnabled ?? false }

    /// Any error message from the last attempt to change the setting.
    var closedDisplayError: String? { closedDisplay.lastError }

    /// True while the administrator prompt is on screen.
    var closedDisplayBusy: Bool { closedDisplay.isBusy }

    /// Turn closed-display mode on or off. Prompts for administrator rights
    /// (it flips the global `pmset disablesleep` setting); the live state is
    /// re-read once the prompt is answered.
    ///
    /// Keepresso is a background agent (`LSUIElement`), so it must become the
    /// active app first or the system password dialog can appear unfocused
    /// behind other windows, leaving the menu in a stuck-looking state. With
    /// the helper installed there is no dialog, so no focus grab either.
    func setClosedDisplay(_ on: Bool) {
        if !helperInstalled {
            NSApp.activate(ignoringOtherApps: true)
        }
        Task {
            await closedDisplay.set(on)
            // A failure through the installed helper points at a stale daemon
            // registration: check and repair it (dedupes, once per run).
            if closedDisplay.lastError != nil, helperInstalled {
                verifyHelper()
            }
        }
    }

    /// Whether closed-display mode follows the session instead of staying on
    /// until manually turned off (see
    /// ``ClosedDisplayAutoController/onlyWhileBrewing``). Persisted. Turning it
    /// on pre-authorizes the root helper now, in this window, so the next
    /// session start doesn't pop a password dialog out of nowhere. One prompt
    /// here, prompt-free automation afterward. No-op if already authorized.
    var closedDisplayOnlyWhileBrewing: Bool {
        get { settings.closedDisplayOnlyWhileBrewing }
        set {
            settings.closedDisplayOnlyWhileBrewing = newValue
            closedDisplayAuto.onlyWhileBrewing = newValue
            persist()
            // Priming exists to front-load the fallback's password prompt into
            // this window; with the helper installed no engage ever prompts,
            // so there is nothing to pre-authorize (and priming through the
            // daemon would flip the real setting on and off for nothing).
            if newValue && !closedDisplayAuto.isAuthorized && !helperInstalled {
                // A fallback engage may later need a password mid-session; be
                // able to say so even behind other windows.
                notifier.requestAuthorization()
                NSApp.activate(ignoringOtherApps: true)
                let window = NSApp.keyWindow
                Task {
                    await closedDisplayAuto.prime()
                    NSApp.activate(ignoringOtherApps: true)
                    window?.makeKeyAndOrderFront(nil)
                }
            } else if !newValue {
                // Turning it off mid-session: release the hold (autoTick won't,
                // it early-returns once the feature's off), then re-read the
                // system setting once the helper has had a cycle to apply it.
                Task {
                    await closedDisplayAuto.stopIfHolding()
                    try? await Task.sleep(for: .seconds(3))
                    await closedDisplay.refresh()
                }
            }
        }
    }

    /// Any error message from the automation's last engage attempt.
    var closedDisplayAutoError: String? { closedDisplayAuto.lastError }

    /// True while the automation's administrator prompt is on screen.
    var closedDisplayAutoBusy: Bool { closedDisplayAuto.isBusy }

    @ObservationIgnored private var wasBrewingForClosedDisplay = false
    @ObservationIgnored private var wasClosedDisplayHolding = false
    @ObservationIgnored private var sawClosedDisplayAutoError = false

    /// Once-a-second pulse for closed-display mode's "only while brewing"
    /// automation. The guard keeps the per-tick task from spawning while the
    /// feature is off.
    func closedDisplayAutoTick() {
        guard settings.closedDisplayOnlyWhileBrewing else { return }
        let brewing = session.isActive
        // Without the helper, the first engage of an app run prompts for the
        // password (e.g. auto mode was enabled in a previous run): become the
        // active app on the session-start edge so the dialog is focused (same
        // reason as ``setClosedDisplay(_:)``), and say what's happening in a
        // notification, since the dialog itself is easy to miss and names
        // "osascript", not Keepresso. Edge-only, so a cancelled prompt isn't
        // followed by a focus steal every second for the rest of the session.
        if brewing, !wasBrewingForClosedDisplay, !closedDisplayAuto.isAuthorized, !helperInstalled {
            NSApp.activate(ignoringOtherApps: true)
            notifier.notify(
                title: "Keepresso needs your password",
                body: "Enter your administrator password to switch closed-display mode on for this session.",
                sound: true
            )
        }
        wasBrewingForClosedDisplay = brewing
        // With the helper installed an engage should never fail; when one
        // does, suspect a stale daemon registration and check it (edge-only,
        // and the check dedupes and repairs at most once per run).
        let autoFailed = closedDisplayAuto.lastError != nil
        if autoFailed, !sawClosedDisplayAutoError, helperInstalled {
            verifyHelper()
        }
        sawClosedDisplayAutoError = autoFailed
        Task { await closedDisplayAuto.autoTick(brewing: brewing) }
        // Mirror an engage or release into the closed-display toggle's live
        // state (and the ticker's lid handling, which keys off it) once the
        // helper has had a cycle to apply the change.
        let holding = closedDisplayAuto.isHolding
        if holding != wasClosedDisplayHolding {
            wasClosedDisplayHolding = holding
            Task {
                try? await Task.sleep(for: .seconds(3))
                await closedDisplay.refresh()
            }
        }
    }

    // MARK: - Virtual display (experimental)

    /// Whether the private virtual-display API exists on this macOS.
    var virtualDisplaySupported: Bool { virtualDisplay.isSupported }

    /// Whether a virtual display is configured.
    var virtualDisplayEnabled: Bool { settings.virtualDisplay != nil }

    /// The current virtual-display configuration, or `nil` when off.
    var virtualDisplayConfig: VirtualDisplayConfig? { settings.virtualDisplay }

    /// Any error from the last attempt to create the virtual display.
    var virtualDisplayError: String? { virtualDisplay.lastError }

    /// Set (or clear, with `nil`) the virtual display and persist the choice.
    func setVirtualDisplay(_ config: VirtualDisplayConfig?) {
        settings.virtualDisplay = config
        virtualDisplay.config = config
        persist()
    }

    // MARK: - Gaming & Streaming

    /// Re-probe the streaming checks and the AWDL watchdog state for the
    /// Gaming & Streaming Setup window (on appear and its Re-check button).
    func refreshStreaming() {
        Task { await streaming.refresh() }
        refreshAWDLState()
        // The window shows the helper's install state alongside the watchdog.
        helper.refresh()
    }

    /// Re-read just the AWDL flag and interface state; cheap enough for the
    /// streaming window's periodic pulse (one `ifconfig` per call).
    func refreshAWDLState() {
        Task { await awdl.refresh() }
    }

    /// Start or stop the AWDL watchdog. Starting prompts for administrator
    /// rights, so the app becomes active first (same reason as
    /// ``setClosedDisplay(_:)``: an unfocused password dialog looks stuck).
    func setAWDLWatchdog(_ on: Bool) {
        if !on {
            // Manual override during an auto-gaming grace: clear the grace so the
            // countdown stops now, and hold auto off so the next tick doesn't
            // immediately re-pause while the game (or its grace) is still around.
            gamingWatcher.resetGrace()
            awdl.holdAutoOff()
        }
        // The admin prompt steals focus and can bury the window the toggle lives
        // in (the Gaming & Streaming window). Capture it now, while it's key, and
        // bring it back once the prompt is answered. No prompt can appear when
        // the helper daemon is installed (or the fallback loop is already
        // authorized this run), so skip the dance there.
        let dance = on && !helperInstalled && !awdl.isAuthorized
        let window = dance ? NSApp.keyWindow : nil
        if dance { NSApp.activate(ignoringOtherApps: true) }
        Task {
            if on {
                await awdl.start()
                // Same stale-registration suspicion as ``setClosedDisplay(_:)``.
                if awdl.lastError != nil, helperInstalled {
                    verifyHelper()
                }
            } else {
                await awdl.stop()
            }
            if dance {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Whether the watchdog follows a gaming trigger (see
    /// ``AWDLWatchdogController/autoWithGaming``). Persisted.
    var awdlAutoWithGaming: Bool {
        get { settings.awdlAutoWithGaming }
        set {
            settings.awdlAutoWithGaming = newValue
            awdl.autoWithGaming = newValue
            persist()
            // Pre-authorize the fallback's root loop now, in this window, so
            // the first game later doesn't pop a password dialog mid-play. One
            // prompt here, prompt-free auto pausing afterward. No-op if
            // already authorized; pointless with the helper daemon installed
            // (no engage ever prompts, and priming through the daemon would
            // blip awdl0 down and up for nothing).
            if newValue && !awdl.isAuthorized && !helperInstalled {
                NSApp.activate(ignoringOtherApps: true)
                let window = NSApp.keyWindow
                Task {
                    await awdl.prime()
                    NSApp.activate(ignoringOtherApps: true)
                    window?.makeKeyAndOrderFront(nil)
                }
            } else if !newValue {
                // Turning auto off mid-bout: clear the grace and lift any pause it
                // started (autoTick won't, it early-returns once the feature's off).
                gamingWatcher.resetGrace()
                Task { await awdl.stopIfAuto() }
            }
        }
    }

    /// Watches for a frontmost game on its own, independent of the trigger
    /// config, so AWDL auto-pause just works without the user first enabling
    /// triggers and adding a "Playing a game" rule. Wrapped in a grace so
    /// alt-tabbing out of a game doesn't immediately drop the pause; the
    /// window length is the user's ``awdlGraceSeconds`` (init overwrites this
    /// placeholder with the persisted value).
    @ObservationIgnored private let gamingWatcher = GracePeriodTrigger(
        wrapping: GamingTrigger(),
        grace: 60
    )

    /// How long the auto pause lingers after the game leaves the front, in
    /// seconds. Persisted; applies immediately, including to a linger that is
    /// already counting down.
    var awdlGraceSeconds: TimeInterval {
        get { settings.awdlGraceSeconds }
        set {
            settings.awdlGraceSeconds = newValue
            gamingWatcher.grace = newValue
            persist()
        }
    }

    /// Whether auto mode posts a notification when it pauses (a game is detected)
    /// and resumes AWDL. A password-required notice is always sent regardless.
    var awdlNotifications: Bool {
        get { settings.awdlNotifications }
        set {
            settings.awdlNotifications = newValue
            if newValue { notifier.requestAuthorization() }
            persist()
        }
    }

    @ObservationIgnored private var wasGameInFront = false
    @ObservationIgnored private var wasGamingActive = false
    @ObservationIgnored private var sawAWDLError = false

    /// Once-a-second pulse for the watchdog's auto mode. Detects a game directly
    /// via ``gamingWatcher`` (no trigger or active session required). The guard
    /// keeps the per-tick task from spawning while the feature is off.
    func awdlAutoTick() {
        guard settings.awdlAutoWithGaming else { return }
        gamingWatcher.tick() // advance the grace window once per pulse
        let gamingActive = gamingWatcher.isSatisfied()
        notifyAWDLEdges(gameInFront: gamingWatcher.wrappedIsSatisfied, gamingActive: gamingActive)
        // Same stale-registration suspicion as ``closedDisplayAutoTick()``.
        let awdlFailed = awdl.lastError != nil
        if awdlFailed, !sawAWDLError, helperInstalled {
            verifyHelper()
        }
        sawAWDLError = awdlFailed
        Task { await awdl.autoTick(gamingActive: gamingActive) }
    }

    /// Fire AWDL notifications on the game-detected and game-ended edges. The
    /// password-required notice always fires (it may land behind a fullscreen
    /// game, where the in-window explanation can't be seen); the pause/resume
    /// notices are gated by ``awdlNotifications``.
    private func notifyAWDLEdges(gameInFront: Bool, gamingActive: Bool) {
        defer { wasGameInFront = gameInFront; wasGamingActive = gamingActive }
        if gameInFront, !wasGameInFront {
            if !awdl.isAuthorized, !awdl.isRunning, !helperInstalled {
                notifier.notify(
                    title: "Keepresso needs your password",
                    body: "Enter your administrator password to pause AWDL for this game.",
                    sound: true
                )
            }
            if settings.awdlNotifications {
                notifier.notify(
                    title: "Game detected",
                    body: "Pausing AWDL to steady your connection.",
                    sound: false
                )
            }
        }
        if !gamingActive, wasGamingActive, settings.awdlNotifications {
            notifier.notify(
                title: "AWDL resumed",
                body: "The game closed; AirDrop, Handoff and Continuity are back.",
                sound: false
            )
        }
    }

    /// Why the AWDL watchdog is (or isn't) currently pausing Wi-Fi discovery,
    /// for the menu and the Gaming & Streaming window. Lets the user see the
    /// auto-gaming grace window instead of wondering why AWDL is still paused
    /// after they quit the game.
    enum AWDLStatus: Equatable {
        /// The watchdog isn't running and auto mode is off; AWDL is normal.
        case off
        /// Auto mode is on but no game is in front yet: armed and watching.
        case watchingForGame
        /// Running because the user turned it on by hand.
        case pausedManually
        /// Running because a game (or cloud-gaming app) is in the foreground.
        case pausedForGame
        /// The game closed; AWDL stays paused for a short grace, resuming in
        /// this many seconds.
        case resumingAfterGame(seconds: Int)

        /// Whether AWDL is actively paused right now (vs off or merely watching).
        /// The menu shows only these; the streaming window shows watching too.
        var isPausing: Bool {
            switch self {
            case .pausedManually, .pausedForGame, .resumingAfterGame: return true
            case .off, .watchingForGame: return false
            }
        }
    }

    /// The live AWDL watchdog status. Reads ``gamingWatcher`` as of the last
    /// ``awdlAutoTick()``, so the grace countdown is current within a second.
    var awdlStatus: AWDLStatus {
        guard awdl.isRunning else {
            // Not paused. Say we're armed and watching when auto mode is on, so
            // the user knows it's waiting for a game rather than doing nothing.
            return settings.awdlAutoWithGaming ? .watchingForGame : .off
        }
        if settings.awdlAutoWithGaming {
            if gamingWatcher.wrappedIsSatisfied { return .pausedForGame }
            if let remaining = gamingWatcher.graceRemaining {
                return .resumingAfterGame(seconds: Int(remaining.rounded(.up)))
            }
        }
        return .pausedManually
    }

    // MARK: - Setup / headless readiness

    /// Re-probe the system for the Setup screen. The shell-outs (`pmset`,
    /// `fdesetup`, `defaults`) are quick; called on the Setup window's appear
    /// and its "Re-check" button. App-level permission checks (which need app
    /// frameworks, not the shell) are rebuilt alongside.
    func refreshReadiness() {
        Task { await readiness.refresh() }
        permissionChecks.rebuild(for: settings.ruleSet.rules)
    }

    /// Builds the app-permission rows and appends them after the system checks.
    @ObservationIgnored private lazy var permissionChecks = PermissionChecksBuilder(readiness: readiness)

    // MARK: - Live system info for the "add condition" menu

    /// The SSID currently joined, for the "add current Wi-Fi" shortcut.
    func currentSSID() -> String? { CoreWLANNetworkMonitor().current.ssid }

    /// Currently mounted volumes (boot volume excluded), for the
    /// "add mounted volume" menu.
    func mountedVolumes() -> [String] {
        FileManagerVolumeMonitor().current.volumeNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Paired Bluetooth device names, for the "add Bluetooth device" menu.
    func pairedBluetoothDevices() -> [String] {
        IOBluetoothDeviceMonitor().current.pairedDeviceNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Regular (Dock-visible) running apps, for the "add running app" menu.
    func runningApps() -> [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
