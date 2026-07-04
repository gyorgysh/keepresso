import AppKit
import CoreBluetooth
import CoreLocation
import EventKit
import Observation
import UserNotifications
import WidgetKit
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
    let closedDisplay = ClosedDisplayController()
    /// Backs the headless-readiness Setup screen. Populated on demand via
    /// ``refreshReadiness()`` — empty until the Setup window first appears.
    let readiness = SystemReadinessController()
    /// Experimental headless virtual display (private CoreGraphics API), off by
    /// default. Uses the real backend; `nil` config means no virtual display.
    let virtualDisplay = VirtualDisplayController(backend: CGVirtualDisplayBackend())
    /// Backs the Gaming & Streaming Setup screen's check list. Populated on
    /// demand via ``refreshStreaming()``, like ``readiness``.
    let streaming = StreamingReadinessController()
    /// The built-in AWDL jitter diagnosis (ping burst + analysis).
    let jitter = JitterTestController()
    /// The session-scoped AWDL watchdog (root loop behind one admin prompt).
    let awdl = AWDLWatchdogController()

    private let store: SettingsStore
    private let factory: TriggerFactory
    private let notifier: UserNotificationReminder
    private(set) var settings: KeepressoSettings

    /// The default reminder interval used when the feature is first enabled.
    static let defaultReminderAfter: TimeInterval = 30 * 60

    init(
        store: SettingsStore = UserDefaultsSettingsStore(),
        factory: TriggerFactory = TriggerFactory()
    ) {
        self.store = store
        self.factory = factory
        let notifier = UserNotificationReminder()
        self.notifier = notifier
        var loaded = store.load()
        loaded.seedNewBuiltInPresets() // new built-ins reach existing users once
        self.settings = loaded
        self.session = SessionController(reminder: notifier)
        self.session.options = loaded.options
        self.session.reminderAfter = loaded.reminderAfter
        self.session.reminderRepeats = loaded.reminderRepeats
        self.session.reminderSound = loaded.reminderSound
        self.session.pauseBelowBatteryPercent = loaded.pauseBelowBatteryPercent
        self.disk = DiskKeepAliveController()
        self.disk.config = loaded.diskKeepAlive
        self.virtualDisplay.config = loaded.virtualDisplay
        self.awdl.autoWithGaming = loaded.awdlAutoWithGaming
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

    // MARK: - Manual activation

    /// Flip a manual (non-gated) session, starting with the saved duration.
    func toggleManual() {
        if session.isActive {
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

    /// Suspend trigger gating and stop the session right away — pausing is
    /// meant to answer "let my Mac sleep for now", not just hand the wheel to
    /// the manual toggle while leaving it brewing. Control reverts to the
    /// manual toggle (so it can be turned back on by hand) until
    /// ``resumeTriggers()``. No-op if triggers aren't on or already paused.
    func pauseTriggers() {
        guard settings.triggersEnabled, !triggersPaused else { return }
        triggersPaused = true
        applyTriggerGate()
        session.stop()
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

    /// The live engine currently gating the session, kept so the menu can read
    /// each condition's live state for the next-trigger summary. `nil` when
    /// trigger gating is off.
    private(set) var currentEngine: TriggerEngine?

    /// The rules ``currentEngine``'s triggers were built from, index-aligned
    /// with `currentEngine.triggers`, so a rebuild can carry live triggers over
    /// for rules that didn't change.
    @ObservationIgnored private var engineRules: [TriggerRule] = []

    /// Rebuild (or tear down) the controller's gate to match current settings.
    ///
    /// Live triggers are stateful (a ``GracePeriodTrigger`` remembers when it
    /// was last satisfied), so this avoids discarding them: with the rules
    /// unchanged (pause/resume, an OR/AND flip) the engine is kept as is, and
    /// on a rule edit every unchanged rule keeps its existing trigger, so an
    /// in-flight grace window survives edits to other rules.
    private func applyTriggerGate() {
        if settings.triggersEnabled {
            if let engine = currentEngine, engineRules == settings.ruleSet.rules {
                engine.combine = settings.ruleSet.combine
            } else {
                var reusable: [TriggerRule: [Trigger]] = [:]
                if let engine = currentEngine {
                    for (rule, trigger) in zip(engineRules, engine.triggers) {
                        reusable[rule, default: []].append(trigger)
                    }
                }
                let triggers = settings.ruleSet.rules.map { rule -> Trigger in
                    if var pool = reusable[rule], !pool.isEmpty {
                        let trigger = pool.removeFirst()
                        reusable[rule] = pool
                        return trigger
                    }
                    return factory.makeTrigger(for: rule)
                }
                currentEngine = TriggerEngine(combine: settings.ruleSet.combine, triggers: triggers)
                engineRules = settings.ruleSet.rules
            }
        } else {
            currentEngine = nil
            engineRules = []
        }
        session.triggerGate = (settings.triggersEnabled && !triggersPaused) ? currentEngine : nil
        // The rules (or the engine) just changed; drop the cached states so the
        // next read re-evaluates against the new rule set immediately.
        cachedRuleStates = nil
        ruleStatesComputedAt = nil
    }

    /// Cached result of ``ruleStates()`` and when it was computed. Evaluating a
    /// rule can shell out (a process trigger spawns `ps`), and the menu asks for
    /// the states several times per render and every second, so the result is
    /// cached briefly to keep the menu responsive. `@ObservationIgnored` so the
    /// cache itself never invalidates a view. Cleared in ``applyTriggerGate()``
    /// whenever the rules change, so edits show immediately.
    @ObservationIgnored private var cachedRuleStates: [(rule: TriggerRule, satisfied: Bool)]?
    @ObservationIgnored private var ruleStatesComputedAt: Date?
    private static let ruleStatesTTL: TimeInterval = 0.9

    /// Live satisfaction of each saved rule, aligned with ``rules`` order, or
    /// `nil` when trigger gating is off. Drives the menu's next-trigger summary.
    /// Cached for ``ruleStatesTTL`` seconds (see ``cachedRuleStates``).
    func ruleStates() -> [(rule: TriggerRule, satisfied: Bool)]? {
        guard settings.triggersEnabled, let engine = currentEngine else {
            cachedRuleStates = nil
            return nil
        }
        if let computedAt = ruleStatesComputedAt, let cached = cachedRuleStates,
           Date().timeIntervalSince(computedAt) < Self.ruleStatesTTL {
            return cached
        }
        let triggers = engine.triggers
        let states = settings.ruleSet.rules.enumerated().map { index, rule in
            (rule, index < triggers.count && triggers[index].isSatisfied())
        }
        cachedRuleStates = states
        ruleStatesComputedAt = Date()
        return states
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

    // MARK: - Control Center widget bridge

    /// The App Group defaults shared with the widget extension, or `nil` when
    /// the group entitlement isn't available (unsigned dev builds).
    @ObservationIgnored private let widgetDefaults = WidgetBridge.groupDefaults()
    /// The last state written, so the per-second tick only writes on change.
    @ObservationIgnored private var lastWidgetState: SharedSessionState?

    /// Mirror the session state into the App Group and refresh the widgets.
    /// Called from the ticker every second; cheap because it no-ops until the
    /// state actually changes. `endsAt` is rounded to a whole second so the
    /// per-tick recomputation lands on the same instant and doesn't defeat the
    /// change check.
    func syncWidgetState() {
        guard let widgetDefaults else { return }
        let endsAt = session.remaining.map {
            Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate + $0).rounded())
        }
        let state = SharedSessionState(
            isActive: session.isActive,
            endsAt: endsAt,
            triggersEnabled: settings.triggersEnabled,
            triggersPaused: triggersPaused
        )
        guard state != lastWidgetState else { return }
        lastWidgetState = state
        WidgetBridge.writeState(state, to: widgetDefaults)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetBridge.statusWidgetKind)
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: WidgetBridge.controlKind)
        }
    }

    /// On quit, leave the widgets showing "off": the session's assertions die
    /// with this process, and a stale "Brewing" tile would lie until the next
    /// launch.
    func writeWidgetStateStopped() {
        guard let widgetDefaults else { return }
        let state = SharedSessionState(
            isActive: false,
            triggersEnabled: settings.triggersEnabled,
            triggersPaused: triggersPaused
        )
        lastWidgetState = state
        WidgetBridge.writeState(state, to: widgetDefaults)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetBridge.statusWidgetKind)
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: WidgetBridge.controlKind)
        }
    }

    /// Consume a pending widget command, if any, and drive the app through the
    /// same seams the menu bar uses. Called when a widget's Darwin
    /// notification arrives and once at launch (the Control Center intent
    /// opens the app, so a not-yet-running app lands here with the command
    /// waiting).
    func applyPendingWidgetCommand() {
        guard let widgetDefaults,
              let command = WidgetBridge.consumeCommand(from: widgetDefaults)
        else { return }
        switch command {
        case .start:
            if !session.isActive { handle(.start(mode: settings.defaultMode)) }
        case .stop:
            if session.isActive { handle(.stop) }
        case .pauseTriggers:
            pauseTriggers()
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
        // Capture before pausing: pauseTriggers() stops the session.
        let wasActive = session.isActive
        pauseTriggers()
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
    /// behind other windows, leaving the menu in a stuck-looking state.
    func setClosedDisplay(_ on: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        Task { await closedDisplay.set(on) }
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
        if on { NSApp.activate(ignoringOtherApps: true) }
        Task {
            if on {
                await awdl.start()
            } else {
                await awdl.stop()
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
        }
    }

    /// Once-a-second pulse for the watchdog's auto mode: "gaming is on" means
    /// the session is active and a gaming rule is among the satisfied
    /// conditions. Cheap: `ruleStates()` is cached, and the guard keeps the
    /// per-tick task from spawning while the feature is off.
    func awdlAutoTick() {
        guard settings.awdlAutoWithGaming else { return }
        let gamingActive = session.isActive && (ruleStates()?.contains {
            $0.rule == .gaming && $0.satisfied
        } ?? false)
        Task { await awdl.autoTick(gamingActive: gamingActive) }
    }

    // MARK: - Setup / headless readiness

    /// Re-probe the system for the Setup screen. The shell-outs (`pmset`,
    /// `fdesetup`, `defaults`) are quick; called on the Setup window's appear
    /// and its "Re-check" button. App-level permission checks (which need app
    /// frameworks, not the shell) are rebuilt alongside.
    func refreshReadiness() {
        Task { await readiness.refresh() }
        rebuildPermissionChecks()
    }

    /// Build the app-permission checks and hand them to the readiness controller,
    /// which appends them after the system checks. The login-item and Location
    /// statuses read synchronously; the notification status is async, so it lands
    /// a moment later.
    private func rebuildPermissionChecks() {
        var base = [loginItemCheck()]
        if usesWiFiRule { base.append(locationCheck()) }
        if usesBluetoothRule { base.append(bluetoothCheck()) }
        if usesCalendarRule { base.append(calendarCheck()) }
        readiness.permissionChecks = base
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            readiness.permissionChecks = base + [notificationCheck(settings.authorizationStatus)]
        }
    }

    /// Whether any saved rule needs the Wi-Fi SSID (and thus Location access).
    private var usesWiFiRule: Bool {
        settings.ruleSet.rules.contains { if case .wifiSSID = $0 { return true } else { return false } }
    }

    /// Whether any saved rule needs the paired-device list (and thus Bluetooth
    /// access).
    private var usesBluetoothRule: Bool {
        settings.ruleSet.rules.contains { if case .bluetoothDevice = $0 { return true } else { return false } }
    }

    /// Whether any saved rule reads calendar events (and thus needs full
    /// calendar access).
    private var usesCalendarRule: Bool {
        settings.ruleSet.rules.contains { if case .calendarEvent = $0 { return true } else { return false } }
    }

    private func loginItemCheck() -> ReadinessCheck {
        let on = LoginItem.isEnabled
        return ReadinessCheck(
            id: "perm-login-item",
            title: "Launch at login",
            status: on ? .ok : .warning,
            detail: on
                ? "Keepresso launches at login, so it returns after a reboot."
                : "Keepresso isn't set to launch at login, so it won't run after an unattended reboot.",
            remediation: on ? nil : Remediation(
                hint: "Turn on “Launch at login” in Keepresso's settings.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            )
        )
    }

    private func locationCheck() -> ReadinessCheck {
        let status = CLLocationManager().authorizationStatus
        let authorized = status == .authorizedAlways || status == .authorized
        return ReadinessCheck(
            id: "perm-location",
            title: "Location access (Wi-Fi rules)",
            status: authorized ? .ok : .warning,
            detail: authorized
                ? "Keepresso can read the current Wi-Fi network name for your Wi-Fi triggers."
                : "Without Location access Keepresso can't read the Wi-Fi network name, so Wi-Fi triggers won't match.",
            remediation: authorized ? nil : Remediation(
                hint: "Allow Location access for Keepresso.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
            )
        )
    }

    private func bluetoothCheck() -> ReadinessCheck {
        let authorized = CBManager.authorization == .allowedAlways
        return ReadinessCheck(
            id: "perm-bluetooth",
            title: "Bluetooth access (device rules)",
            status: authorized ? .ok : .warning,
            detail: authorized
                ? "Keepresso can see which paired devices are connected for your Bluetooth triggers."
                : "Without Bluetooth access Keepresso can't see paired devices, so Bluetooth triggers won't match.",
            remediation: authorized ? nil : Remediation(
                hint: "Allow Bluetooth access for Keepresso.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
            )
        )
    }

    private func calendarCheck() -> ReadinessCheck {
        let authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        return ReadinessCheck(
            id: "perm-calendar",
            title: "Calendar access (event rule)",
            status: authorized ? .ok : .warning,
            detail: authorized
                ? "Keepresso can see when a calendar event is in progress for your calendar trigger."
                : "Without full calendar access Keepresso can't see events, so the calendar trigger won't match.",
            remediation: authorized ? nil : Remediation(
                hint: "Allow full calendar access for Keepresso.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            )
        )
    }

    private func notificationCheck(_ status: UNAuthorizationStatus) -> ReadinessCheck {
        let on = status == .authorized || status == .provisional
        return ReadinessCheck(
            id: "perm-notifications",
            title: "Notifications",
            status: on ? .ok : .warning,
            detail: on
                ? "Keepresso can post the “still brewing” reminder."
                : "Notifications are off, so the “still brewing” reminder can't appear.",
            remediation: on ? nil : Remediation(
                hint: "Allow notifications for Keepresso.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
            )
        )
    }

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
