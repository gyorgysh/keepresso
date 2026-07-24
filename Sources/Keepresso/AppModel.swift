import AppKit
import Darwin
import Observation
import UniformTypeIdentifiers
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
    /// Built-in display brightness control (private DisplayServices API), for
    /// dim-don't-sleep. Reports unsupported when unavailable; the UI hides the
    /// option then. Held here so the controller and the Preferences gate share
    /// one instance.
    let brightnessBackend = DisplayServicesBrightnessBackend()
    /// Whether dim-don't-sleep can run on this Mac (private brightness API
    /// available and a built-in display present). The Preferences option is
    /// hidden when false, never shown as a dead toggle.
    var brightnessSupported: Bool { brightnessBackend.isSupported }
    /// Backs the Gaming & Streaming Setup screen's check list. Populated on
    /// demand via ``refreshStreaming()``, like ``readiness``.
    let streaming = StreamingReadinessController()
    /// The built-in AWDL jitter diagnosis (ping burst + analysis).
    let jitter = JitterTestController()
    /// The AWDL watchdog: the helper daemon when installed, else the
    /// session-scoped root loop behind one admin prompt per app run.
    let awdl: AWDLWatchdogController
    /// The thermal safety net: watches the configured heat signal, applies the
    /// dwell/hysteresis, and hands escalation effects to
    /// ``handleThermalEffects(_:)`` via the ticker. Off while its config is nil.
    let thermalGuard = ThermalGuardController(
        pressure: SystemThermalPressure(),
        sensors: MachineThermalSensors()
    )
    /// Registration and status of the privileged helper daemon, the one-time
    /// password alternative to the per-run osascript prompts.
    let helper: HelperManager
    /// Outbound event hooks ("on session end, run a Shortcut").
    let hookDispatcher: EventHookDispatcher
    /// Decision log on disk (JSONL under Application Support).
    let logPersister: DecisionLogPersister
    /// Live `pmset -g sched` view for Preferences.
    @ObservationIgnored private let wakeReader: WakeScheduleReading
    /// Cached system wake schedule for the Automation tab.
    private(set) var systemWakeState: SystemWakeState = .empty
    /// Seven-day awake stats from the persisted log.
    private(set) var awakeStats: AwakeStats = .empty
    /// Discovers local AI automations (Claude Desktop, Codex) to wake for.
    let automationSyncController = AutomationSyncController()
    /// The next automation-sync wake currently armed into the system schedule,
    /// so a re-arm only touches `pmset` when the wake actually moves.
    @ObservationIgnored private var automationNextWake: Date?
    /// Throttles the slow-cadence discovery driven off the one-second ticker.
    @ObservationIgnored private var lastAutomationRefreshAt: Date?
    /// Avoids opening a second hold window for one system wake.
    @ObservationIgnored private var lastAutomationHoldAt: Date?

    private let store: SettingsStore
    private let notifier: UserNotificationReminder
    /// Direct line to the helper daemon for the thermal fan boost (the other
    /// privileged features go through their Routed* controllers).
    @ObservationIgnored private let helperClient: PrivilegedHelperCalling
    private(set) var settings: KeepressoSettings
    /// Avoid double-starting on a single system wake.
    @ObservationIgnored private var lastWakeBrewAt: Date?

    /// The default reminder interval used when the feature is first enabled.
    static let defaultReminderAfter: TimeInterval = 30 * 60

    /// The default "ending soon" lead time used when the feature is first enabled.
    static let defaultEndingSoonNotice: TimeInterval = 5 * 60

    init(
        store: SettingsStore = UserDefaultsSettingsStore(),
        factory: TriggerFactory = TriggerFactory(),
        appUpdatedSinceLastRun: Bool = false
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
        self.helperClient = helperClient
        let helperManager = HelperManager(
            client: helperClient,
            appUpdatedSinceLastRun: appUpdatedSinceLastRun
        )
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
        loaded.refreshBuiltInPresets() // and changed ones stay current
        self.settings = loaded
        // Session-end sleep prefers the helper's root `pmset sleepnow` when
        // the daemon is up, then IOKit, then System Events.
        let systemSleeper = CompositeSystemSleeper(preferred: { [helperClient, helperInstalled] in
            guard helperInstalled() else { return false }
            return helperClient.sleepNow()
        })
        let endActor = SystemEndActionPerformer(systemSleeper: systemSleeper)
        self.session = SessionController(reminder: notifier, endActor: endActor, brightness: brightnessBackend)
        self.session.options = loaded.options
        self.session.reminderAfter = loaded.reminderAfter
        self.session.reminderRepeats = loaded.reminderRepeats
        self.session.reminderSound = loaded.reminderSound
        self.session.notifyOnEnd = loaded.notifyOnEnd
        self.session.endingSoonNotice = loaded.endingSoonNoticeSeconds
        self.session.endAction = loaded.endAction
        self.session.pauseBelowBatteryPercent = loaded.pauseBelowBatteryPercent
        self.session.pauseWhenHot = loaded.thermalSafety?.stopBrewing ?? false
        // Leases surviving a relaunch are picked up by the first tick's
        // directory scan; no launch-time special case.
        self.session.leases = loaded.automationLeasesEnabled ? leaseEngine : nil
        let hooks = EventHookDispatcher(runner: SystemHookRunner())
        hooks.hooks = loaded.eventHooks
        self.hookDispatcher = hooks
        let logPersister = DecisionLogPersister()
        self.logPersister = logPersister
        self.wakeReader = PMSetWakeScheduleReader()
        // Rehydrate Activity from disk before any new events land: one read
        // feeds both the in-memory log and the stats mirror.
        let history = logPersister.loadAll()
        self.statsHistory = history
        self.session.log.load(Array(history.suffix(DecisionLogPersister.loadLimit)))
        self.awakeStats = AwakeStatsAggregator.summarize(events: history)
        // Raw config here (self isn't fully initialized yet for the
        // availability derivation); the first thermalAvailabilityTick one
        // second later nils an unavailable boost stage out.
        self.thermalGuard.config = loaded.thermalSafety
        GlassClarity.shared.value = Double(loaded.glassClarity) / 100
        self.disk = DiskKeepAliveController()
        self.disk.config = loaded.diskKeepAlive
        self.virtualDisplay.config = loaded.virtualDisplay
        self.awdl.autoWithGaming = loaded.awdlAutoWithGaming
        self.gamingWatcher.grace = loaded.awdlGraceSeconds
        self.closedDisplayAuto.onlyWhileBrewing = loaded.closedDisplayOnlyWhileBrewing
        self.controllerPoker.enabled = loaded.controllerPokeWhileGaming
        self.gamePriority.autoWithGaming = loaded.gamePriorityBoost
        // Decision log → outbound hooks + disk. After every stored property
        // is initialized so weak self is legal.
        self.session.log.onRecord = { [weak hooks, weak logPersister, weak self] event in
            hooks?.handle(sessionEvent: event)
            let persisted = PersistedSessionEvent(event, batteryPercent: event.batteryPercent)
            logPersister?.append(persisted)
            self?.recordForStats(persisted)
        }
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
        // The thermal pause always announces itself in a notification (an
        // otherwise silent stop just looks like the app quit), helper or not.
        if loaded.thermalSafety != nil {
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
            revokeLeases()
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
        // Take manual ownership first, exactly like `toggleManual` and the URL
        // command path. Without this, starting while trigger gating is active
        // but unsatisfied makes `start()`'s synchronous reconcile immediately
        // release the session (triggers not met) and fire the end action, so
        // asking to "keep awake until 18:00" could instead sleep or lock the Mac.
        pauseTriggers()
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
            // session running as a "manual" one with a stale duration. Leases
            // are their own demand source, though: a lease-held session
            // survives the flip untouched, and turning gating off while
            // leases are live hands the session to them instead of stopping
            // it out from under the agent's work.
            if !session.isLeaseHeld {
                if !newValue, session.isActive, !session.liveLeases.isEmpty {
                    session.handOffToLeases()
                } else {
                    session.stop()
                }
            }
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
        // Live leases are their own demand source with their own explicit
        // end control (the menu offers "End Automation Leases" before this
        // while any are live): hand the session to them instead of a stop
        // that lease demand would flap right back on the next tick.
        if session.isActive, !session.liveLeases.isEmpty {
            session.handOffToLeases()
            session.reconcile()
        } else {
            session.stop(cause: cause)
        }
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
        panel.prompt = L("Watch")
        panel.message = L("Keep awake while downloads are in progress in this folder.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addRule(.downloadInFolder(url))
    }

    /// Prompt for an application to scope a microphone rule to, returning its
    /// display name and bundle id (read from the chosen bundle, so it is always
    /// the real id, never a guess). Opens on an explicit click only. Restricted
    /// to `.app` bundles, starting in /Applications. Returns `nil` if cancelled
    /// or the pick has no bundle id.
    func pickApplication() -> (name: String, bundleID: String)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Choose")
        panel.message = L("Keep awake while this app is using the microphone (on a call).")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier
        else { return nil }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (name, id)
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
        func conditions(_ count: Int) -> String {
            L(count == 1 ? "%d condition" : "%d conditions", count)
        }
        if session.isActive {
            // The per-condition list is shown right below, so summarize by count
            // instead of repeating each label.
            let held = states.filter(\.satisfied).count
            return held == 0 ? L("Active") : L("Held by %@", conditions(held))
        }
        switch settings.ruleSet.combine {
        case .any:
            return L("Waiting for any condition")
        case .all:
            let pending = states.filter { !$0.satisfied }.count
            return L("Waiting on %@", conditions(pending))
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

    /// Outbound event hooks. Writing replaces the live dispatcher list too.
    var eventHooks: [EventHook] {
        get { settings.eventHooks }
        set {
            settings.eventHooks = newValue
            hookDispatcher.hooks = newValue
            persist()
        }
    }

    /// Suspend hook execution while the Automation tab is mid-edit so a
    /// half-written command never runs against a live event.
    var hooksEditing: Bool {
        get { hookDispatcher.isSuspended }
        set { hookDispatcher.isSuspended = newValue }
    }

    /// Fire the agent-idle hook when a live agent trigger just flipped. Called
    /// from the ticker after reconcile (the trigger's tick runs inside it).
    func fireAgentIdleHookIfNeeded() {
        if gate.agentJustWentIdle() {
            hookDispatcher.fire(.agentWentIdle)
        }
    }

    // MARK: - Wake schedules

    /// Why scheduled-wake controls are locked or live. Same idea as
    /// ``FanTestGate``: never grey a toggle silently.
    enum WakeHelperGate: Equatable {
        case ready
        case needsHelper
        case awaitingApproval
        case helperUpdating
    }

    var wakeHelperGate: WakeHelperGate {
        if helper.awaitingApproval { return .awaitingApproval }
        if !helperInstalled { return .needsHelper }
        if helper.daemonOutdated { return .helperUpdating }
        return .ready
    }

    var canEditWakeSchedule: Bool { wakeHelperGate == .ready }

    /// Desired wake schedule (nil = off / clear system schedules). Enabling
    /// without a ready helper is refused so Preferences never looks live
    /// when the system cannot install the schedule.
    var wakeSchedule: WakeScheduleConfig? {
        get { settings.wakeSchedule }
        set {
            // When the helper is not ready, only clearing (nil) is allowed so
            // a saved-but-inactive plan can be discarded. Enabling or editing
            // is refused; the UI already hides those controls.
            if newValue != nil, !canEditWakeSchedule { return }
            settings.wakeSchedule = newValue
            persist()
            applyWakeScheduleToSystem()
        }
    }

    // MARK: - Automation wake sync

    /// Settings for syncing wake schedules from local AI automations (Claude
    /// Desktop, Codex). Toggling on requests notification permission (the hold
    /// posts a heads-up), refreshes discovery, and arms the next wake; off drops
    /// the automation wake.
    var automationSyncConfig: AutomationSyncConfig {
        get { settings.automationSync }
        set {
            let turnedOn = newValue.enabled && !settings.automationSync.enabled
            settings.automationSync = newValue
            persist()
            if turnedOn { notifier.requestAuthorization() }
            refreshAndArmAutomationWakes()
        }
    }

    /// Discovered automations, most recent discovery, for the Automations UI.
    var syncedAutomations: [ScheduledAutomation] { automationSyncController.automations }

    /// The next automation wake currently armed, for the UI.
    var automationNextWakeTime: Date? { automationNextWake }

    /// Whether a discovered automation is muted (opted out of syncing).
    func isAutomationMuted(_ id: String) -> Bool { settings.automationSync.mutedIDs.contains(id) }

    /// Mute or unmute one discovered automation, then re-arm.
    func setAutomationMuted(_ id: String, _ muted: Bool) {
        var config = settings.automationSync
        if muted { config.mutedIDs.insert(id) } else { config.mutedIDs.remove(id) }
        automationSyncConfig = config
    }

    /// Re-read the sources now, for the Automations window on appear.
    func refreshSyncedAutomations() {
        automationSyncController.refresh()
        armAutomationWakesIfChanged()
    }

    /// Slow-cadence discovery + re-arm from the ticker: read the tiny local
    /// stores at most once a minute, and re-apply the wake only when it moves.
    func automationSyncTick() {
        guard settings.automationSync.enabled else {
            if automationNextWake != nil {
                automationNextWake = nil
                applyWakeScheduleToSystem() // drop the automation wake
            }
            return
        }
        let now = Date()
        if let last = lastAutomationRefreshAt, now.timeIntervalSince(last) < 60 { return }
        lastAutomationRefreshAt = now
        refreshAndArmAutomationWakes()
    }

    /// Discover, then install the next wake if it changed.
    func refreshAndArmAutomationWakes() {
        automationSyncController.refresh()
        armAutomationWakesIfChanged()
    }

    private func armAutomationWakesIfChanged() {
        let config = settings.automationSync
        let next = config.enabled
            ? AutomationSync.nextWake(automationSyncController.automations, config: config, after: Date())
            : nil
        guard next != automationNextWake else { return }
        automationNextWake = next
        applyWakeScheduleToSystem()
    }

    /// Hold the Mac awake when this system wake was for a synced automation run.
    /// Returns whether a hold was opened, so the manual wake-and-brew is skipped.
    /// A scheduled agent can extend the hold by taking a lease; otherwise the
    /// timed window lets the Mac sleep again when it ends.
    private func handleAutomationWake() -> Bool {
        let config = settings.automationSync
        guard config.enabled else { return false }
        automationSyncController.refresh()
        guard let match = AutomationSync.wakeMatch(
            automationSyncController.automations, config: config, wokeAt: Date()) else { return false }
        let now = Date()
        if let last = lastAutomationHoldAt, now.timeIntervalSince(last) < 60 { return true }
        lastAutomationHoldAt = now
        // Open a fixed hold window, unless triggers own activation: a plain
        // session would be released by the gate on the next reconcile (the same
        // reason the manual wake-and-brew path skips when triggers are on). With
        // triggers on, the wake still happened and a scheduled agent's own lease
        // can hold the Mac for the run.
        if !triggersEnabled, !session.isActive {
            session.start(mode: .timed(duration: config.holdSeconds), cause: .command)
        }
        notifier.notify(
            title: L("Awake for a scheduled run"),
            body: L("Keeping this Mac awake for \u{201C}%@\u{201D} to run.", match.automationName),
            sound: false
        )
        refreshAndArmAutomationWakes() // the run we woke for is now current; arm the next
        return true
    }

    /// Set once Keepresso has attempted to install system wake schedules on
    /// this Mac, so the no-schedule case never touches `pmset`: clearing
    /// there would delete wake schedules the user or another tool set.
    /// Debt-by-attempt like the helper's own markers (an install can
    /// partially land even on failure), reset only by a clean clear.
    /// Machine-local bookkeeping, deliberately not part of the exported
    /// settings.
    private var wakeSchedulesInstalledByKeepresso: Bool {
        get { UserDefaults.standard.bool(forKey: Self.wakeInstalledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.wakeInstalledDefaultsKey) }
    }
    private static let wakeInstalledDefaultsKey = "wakeSchedulesInstalledByKeepresso"

    /// The wake config actually installed: the user's manual schedule with the
    /// next automation-sync wake layered onto the one-shot slot. The earlier of
    /// a manual one-shot and the automation wake wins so neither is lost, and
    /// the manual repeating pair is untouched.
    private func effectiveWakeConfig() -> WakeScheduleConfig {
        var config = settings.wakeSchedule ?? WakeScheduleConfig()
        if let autoWake = automationNextWake, autoWake > Date() {
            config.oneShot = config.oneShot.map { min($0, autoWake) } ?? autoWake
        }
        return config
    }

    /// Push settings to the helper (or clear). Installing needs the helper;
    /// clearing is attempted when it answers so a disable after reinstall
    /// still drops system schedules.
    func applyWakeScheduleToSystem() {
        // A one-shot whose moment has passed can never install again (pmset
        // refuses past dates); drop it so later applies don't fail on it
        // forever.
        if let date = settings.wakeSchedule?.oneShot, date <= Date() {
            settings.wakeSchedule?.oneShot = nil
            persist()
        }
        let config = effectiveWakeConfig()
        // Leave pmset alone when there is nothing to install and Keepresso
        // never installed anything: the system schedules belong to the user
        // or another tool, not to us.
        guard config.isActive || wakeSchedulesInstalledByKeepresso else { return }
        // A pre-update daemon still answering the handshake means "updating",
        // not "missing": no failure notification, re-apply once the new
        // daemon serves.
        let helperUpdating = wakeHelperGate == .helperUpdating
        let client = helperClient
        Task.detached { [weak self] in
            guard client.ping() else {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.refreshSystemWakeState()
                    guard config.isActive else { return }
                    if helperUpdating {
                        self.reapplyWakeScheduleWhenHelperReady()
                    } else {
                        self.notifier.notify(
                            title: L("Wake schedule not installed"),
                            body: L("Installing a wake schedule needs the administrator helper (Preferences ▸ General)."),
                            sound: false
                        )
                    }
                }
                return
            }
            let parts = config.pmsetArguments
            let ok = client.applyWakeSchedule(
                oneShot: parts.oneShot,
                repeatDays: parts.repeatDays,
                repeatTime: parts.repeatTime
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if config.isActive {
                    self.wakeSchedulesInstalledByKeepresso = true
                } else if ok {
                    self.wakeSchedulesInstalledByKeepresso = false
                }
                self.refreshSystemWakeState()
                if !ok {
                    self.notifier.notify(
                        title: L("Wake schedule not installed"),
                        body: L("The administrator helper could not update the system wake schedule."),
                        sound: false
                    )
                }
            }
        }
    }

    /// One re-apply once the daemon finishes updating after an app update, so
    /// a saved schedule doesn't sit uninstalled until the next Preferences
    /// visit. Single-flight; gives up when the helper goes missing or after
    /// two minutes.
    @ObservationIgnored private var wakeReapplyWatch: Task<Void, Never>?

    private func reapplyWakeScheduleWhenHelperReady() {
        guard wakeReapplyWatch == nil else { return }
        helper.watchDaemonUpdate()
        wakeReapplyWatch = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                switch self.wakeHelperGate {
                case .ready:
                    self.wakeReapplyWatch = nil
                    self.applyWakeScheduleToSystem()
                    return
                case .needsHelper:
                    // Uninstalled while waiting; nothing to re-apply onto.
                    self.wakeReapplyWatch = nil
                    return
                case .awaitingApproval, .helperUpdating:
                    continue
                }
            }
            self?.wakeReapplyWatch = nil
        }
    }

    /// Re-read `pmset -g sched` for the Automation footer.
    func refreshSystemWakeState() {
        systemWakeState = wakeReader.current()
    }

    /// The persisted history mirrored in memory, so per-event stats updates
    /// don't re-read and re-decode the log file. Seeded once at init and
    /// appended on every recorded event.
    @ObservationIgnored private var statsHistory: [PersistedSessionEvent] = []

    /// Fold one just-recorded event into the mirror and re-summarize. Pure
    /// compute, no disk: the persister already wrote the event.
    private func recordForStats(_ event: PersistedSessionEvent) {
        statsHistory.append(event)
        // The stats window is seven days; a flap-heavy machine left running
        // for months must not grow the mirror without bound.
        if statsHistory.count > 8192 {
            statsHistory.removeFirst(statsHistory.count - 4096)
        }
        refreshAwakeStats()
    }

    func refreshAwakeStats() {
        awakeStats = AwakeStatsAggregator.summarize(events: statsHistory)
    }

    /// React to ``NSWorkspace.didWakeNotification``: if the wake matches a
    /// Keepresso schedule with wake-and-brew on, start a session (or apply a
    /// preset).
    func handleSystemWake() {
        // A synced automation run takes precedence: hold for it and skip the
        // manual wake-and-brew below.
        if handleAutomationWake() { return }
        guard let config = settings.wakeSchedule,
              WakeAndBrewPolicy.shouldStartSession(config: config, wakeDate: Date())
        else { return }
        let now = Date()
        if let last = lastWakeBrewAt, now.timeIntervalSince(last) < 60 { return }
        lastWakeBrewAt = now
        if let presetID = config.presetID,
           let preset = settings.presets.first(where: { $0.id == presetID }) {
            applyPreset(preset)
            return
        }
        if triggersEnabled {
            // Gate owns activation; just ensure triggers are live.
            return
        }
        let mode: SessionMode = {
            if let duration = config.sessionDurationSeconds, duration > 0 {
                return .timed(duration: duration)
            }
            return .indefinite
        }()
        session.start(mode: mode, cause: .command)
    }

    // MARK: - Quick stop

    /// Convert the running manual session to end this long from now (the
    /// menu's quick "stop in N" shortcuts). Deliberately not persisted: it
    /// changes only the live session, never the default duration.
    func stopSessionIn(_ interval: TimeInterval) {
        session.stopIn(interval)
    }

    /// The menu's quick-stop shortcut durations, kept normalized.
    var quickStopDurations: [TimeInterval] {
        get { settings.quickStopDurations }
        set {
            settings.quickStopDurations = KeepressoSettings.normalizedQuickStopDurations(newValue)
            persist()
        }
    }

    /// Whether the "ending soon" heads-up is on. Enabling it requests
    /// notification permission and seeds a default lead time.
    var endingSoonEnabled: Bool {
        get { settings.endingSoonNoticeSeconds != nil }
        set {
            settings.endingSoonNoticeSeconds = newValue
                ? (settings.endingSoonNoticeSeconds ?? Self.defaultEndingSoonNotice)
                : nil
            if newValue { notifier.requestAuthorization() }
            session.endingSoonNotice = settings.endingSoonNoticeSeconds
            persist()
        }
    }

    /// The heads-up lead time shown in the picker. Reads the default while the
    /// feature is off so the picker has a sensible selection before enabling.
    var endingSoonNotice: TimeInterval {
        get { settings.endingSoonNoticeSeconds ?? Self.defaultEndingSoonNotice }
        set {
            settings.endingSoonNoticeSeconds = newValue
            session.endingSoonNotice = newValue
            persist()
        }
    }

    // MARK: - Battery-aware auto-pause

    /// The default cutoff used when the feature is first enabled.
    static let defaultPauseBelowBatteryPercent = 20

    /// Whether this Mac has an internal battery at all. Read once at launch
    /// (battery hardware doesn't come and go): desktops (Mac mini, Studio,
    /// Pro) report none, and Preferences hides the auto-pause section and the
    /// battery trigger rules there, where they could never fire.
    @ObservationIgnored let machineHasBattery = IOKitPowerSourceMonitor().current.hasBattery

    /// Whether an active session force-stops (letting the Mac sleep) once
    /// battery charge drops below ``pauseBelowBatteryPercent``. Enabling it
    /// requests notification permission: the pause announces itself in a
    /// notification (an otherwise silent stop just looks like the app quit).
    var batteryAutoPauseEnabled: Bool {
        get { settings.pauseBelowBatteryPercent != nil }
        set {
            settings.pauseBelowBatteryPercent = newValue
                ? (settings.pauseBelowBatteryPercent ?? Self.defaultPauseBelowBatteryPercent)
                : nil
            session.pauseBelowBatteryPercent = settings.pauseBelowBatteryPercent
            if newValue { notifier.requestAuthorization() }
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

    // MARK: - Thermal safety

    /// Whether this Mac has any fans, read once at launch like
    /// ``machineHasBattery`` (a MacBook Air reports zero and hides the fan
    /// boost UI entirely). `nil` fan counts (SMC unreachable) read as fanless.
    @ObservationIgnored let machineHasFans = (SMCFanInfo().fanCount() ?? 0) > 0

    /// The thermal safety configuration, or nil for off. Setting it re-derives
    /// the guard and the session's pause gate, mirroring the battery setters.
    var thermalSafety: ThermalSafetyConfig? {
        get { settings.thermalSafety }
        set {
            settings.thermalSafety = newValue
            thermalGuard.config = effectiveThermalConfig(newValue)
            session.pauseWhenHot = newValue?.stopBrewing ?? false
            if newValue != nil { notifier.requestAuthorization() }
            persist()
        }
    }

    /// The guard's view of the config: the fan-boost stage is nilled out
    /// while a boost can't actually run (fanless Mac via an imported config,
    /// helper missing or removed, daemon still pre-update), so an
    /// unavailable stage 1 never eats a sustain window before the pause.
    /// Settings keep the user's chosen strength untouched.
    private func effectiveThermalConfig(_ config: ThermalSafetyConfig?) -> ThermalSafetyConfig? {
        guard var config else { return nil }
        if config.fanBoostPercent != nil,
           !(machineHasFans && helperInstalled && !helper.daemonOutdated) {
            config.fanBoostPercent = nil
        }
        return config
    }

    /// Once per tick: re-derive the guard's effective config (helper state
    /// changes on its own timetable) and, while an active boost claim
    /// exists, watch for the daemon surrendering it. Cheap when idle: a
    /// value compare, and no XPC unless a boost is showing.
    func thermalAvailabilityTick() {
        thermalGuard.config = effectiveThermalConfig(settings.thermalSafety)
        // A stale "daemon outdated" verdict would silently keep the boost
        // stage off; while it matters (boost configured), keep the version
        // watch armed so the verdict converges (single-flight, no-op while
        // one is already running).
        if settings.thermalSafety?.fanBoostPercent != nil,
           helperInstalled, helper.daemonOutdated {
            helper.watchDaemonUpdate()
        }
        fanHoldWatchTick()
    }

    /// Poll the daemon's surrendered-boost flag every few seconds while the
    /// app claims an active boost, so the menu never keeps advertising a
    /// boost the firmware refused (the daemon gives up after repeated
    /// failed writes and restores auto on its own).
    @ObservationIgnored private var fanDropCheckInFlight = false
    @ObservationIgnored private var ticksSinceFanDropCheck = 0

    private func fanHoldWatchTick() {
        guard fanBoostActivePercent != nil, !fanDropCheckInFlight else { return }
        ticksSinceFanDropCheck += 1
        guard ticksSinceFanDropCheck >= 3 else { return }
        ticksSinceFanDropCheck = 0
        fanDropCheckInFlight = true
        let client = helperClient
        Task { [weak self] in
            let dropped = await Task.detached { client.fanHoldDropped() }.value
            guard let self else { return }
            self.fanDropCheckInFlight = false
            guard dropped == true, self.fanBoostActivePercent != nil else { return }
            // Let go of our side too, so a daemon restart can't re-assert
            // the hold the firmware already refused.
            self.setFanHold(percent: nil)
            self.notifier.notify(
                title: L("Fan boost ended"),
                body: L("The firmware kept refusing manual fan control, so the fans are back with the system. The rest of the thermal safety net still applies."),
                sound: false
            )
        }
    }

    /// Set when a thermal emergency lifted closed-display mode, so recovery
    /// puts it back. In-memory only: a relaunch mid-emergency starts clean
    /// rather than resurrecting a stale intent.
    @ObservationIgnored private var thermalLiftedClosedDisplay = false

    /// The fan boost percent currently held through the helper, or nil when
    /// the fans are under system control. Drives the menu's status line.
    private(set) var fanBoostActivePercent: Int?

    /// Translate the guard's escalation effects into helper calls, the
    /// closed-display lift, and notifications. Called from the ticker on any
    /// tick that produced effects.
    func handleThermalEffects(_ effects: [ThermalEffect]) {
        if !effects.isEmpty {
            hookDispatcher.fire(.thermalStageChanged)
        }
        for effect in effects {
            switch effect {
            case .boostFans(let percent):
                // Fan writes are root-only, so this is daemon-or-skip, and the
                // skip explains itself (the Preferences toggle also warns).
                guard machineHasFans else { break }
                guard helperInstalled else {
                    notifier.notify(
                        title: L("Fans not boosted"),
                        body: L("Boosting fans needs the administrator helper (Preferences ▸ General). The rest of the thermal safety net still applies."),
                        sound: false
                    )
                    break
                }
                guard !helper.daemonOutdated else {
                    notifier.notify(
                        title: L("Fans not boosted"),
                        body: L("The administrator helper is still updating itself to this version of Keepresso. Fan boost engages once that finishes, and the rest of the thermal safety net still applies."),
                        sound: false
                    )
                    break
                }
                if fanDryRun.isRunning {
                    // A real emergency never shares the fans with the
                    // diagnostic: stop the test, wait for its release, then
                    // take the hold. Re-check that the emergency is still
                    // latched before engaging: cancelAndWait can outlast
                    // several ticks (in-flight XPC calls block up to their
                    // timeout), and a .restoreFans delivered meanwhile would
                    // find nothing to release yet, so engaging here after
                    // the guard cleared would leak the hold.
                    Task { [weak self] in
                        await self?.fanDryRun.cancelAndWait()
                        guard let self, self.thermalGuard.state.stage != .clear else { return }
                        self.setFanHold(percent: percent)
                    }
                } else {
                    setFanHold(percent: percent)
                }
            case .restoreFans:
                // Always send the release, even when no boost looks active
                // here: a failed engage rolls fanBoostActivePercent back
                // while the daemon keeps the holder and retries into
                // success, so skipping on the local status would strand a
                // live hold. The release is idempotent and costs one silent
                // call when there is truly nothing to release.
                setFanHold(percent: nil)
            case .pauseBrewing:
                // The session pause itself latches through reconcile (the
                // guard's reading), which posts the pause notification. Here:
                // the closed-display lift, always, because the guard only
                // fires with the lid shut and the override on, and pausing
                // alone can't let that Mac sleep. Only through the prompt-free
                // daemon path: never prompt for a password from an unattended
                // safety action; without the helper the lift is skipped and
                // the notification says so.
                guard closedDisplayEnabled else { break }
                guard helperInstalled else {
                    notifier.notify(
                        title: L("Closed-display mode left on"),
                        body: L("Keepresso paused for heat but can't switch off closed-display mode without the administrator helper (Preferences ▸ General)."),
                        sound: false
                    )
                    break
                }
                thermalLiftedClosedDisplay = true
                setClosedDisplay(false, userInitiated: false)
            case .resumeBrewing:
                notifier.notify(
                    title: L("Temperatures recovered"),
                    body: L("The Mac has cooled down. Keepresso is back to normal control."),
                    sound: false
                )
                if thermalLiftedClosedDisplay {
                    thermalLiftedClosedDisplay = false
                    if helperInstalled { setClosedDisplay(true, userInitiated: false) }
                }
            }
        }
    }

    /// Take (percent) or release (nil) the forced-fan hold through the helper,
    /// off the main actor: the XPC call is synchronous with a timeout. The
    /// status flips optimistically and rolls back if the daemon said no.
    private func setFanHold(percent: Int?) {
        fanBoostActivePercent = percent
        let client = helperClient
        Task.detached { [weak self] in
            let ok = client.setFanHold(percent != nil, percent: percent ?? 0)
            guard !ok, percent != nil else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fanBoostActivePercent = nil
                self.notifier.notify(
                    title: L("Fans not boosted"),
                    body: L("The administrator helper didn't accept the fan boost. The rest of the thermal safety net still applies."),
                    sound: false
                )
            }
        }
    }

    // MARK: - Fan dry run

    /// The "Test Fans" system check in Preferences ▸ General ▸ Thermal: a
    /// short supervised run through three boost levels with readings at each,
    /// so the fan path can be trusted before the safety net ever needs it.
    /// Its own controller is `@Observable`; the temperature comes from the
    /// same reader the guard uses (hottest sensor the machine offers).
    @ObservationIgnored private(set) lazy var fanDryRun = FanDryRunController(
        helper: helperClient,
        fans: SMCFanInfo(),
        readCelsius: { [thermalGuard] in
            let ids = thermalGuard.discoverSensors().map(\.id)
            return thermalGuard.liveReadings(ids: ids).values.max()
        }
    )

    /// Why the fan test can't start right now, so the UI can say it next to
    /// the disabled button instead of greying out silently. `machineHasFans`
    /// needs no case: the whole fan block is hidden on fanless Macs.
    enum FanTestGate: Equatable {
        case ready
        /// Helper not installed (also every debug build, which stays
        /// hands-off the daemon by design). The row offers the install
        /// itself, so nobody has to scroll up hunting for the helper section.
        case needsHelper
        /// Install started; macOS wants the one-time approval in System
        /// Settings.
        case awaitingApproval
        /// Installed, but the pre-update daemon image is still serving and
        /// doesn't speak the fan protocol yet.
        case helperUpdating
        /// The safety net currently holds the fans; an emergency always
        /// outranks a diagnostic.
        case boostActive
    }

    var fanTestGate: FanTestGate {
        if helper.awaitingApproval { return .awaitingApproval }
        if !helperInstalled { return .needsHelper }
        if helper.daemonOutdated { return .helperUpdating }
        if fanBoostActivePercent != nil { return .boostActive }
        return .ready
    }

    /// Whether the test may start right now.
    var canRunFanDryRun: Bool { fanTestGate == .ready }

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

    /// Whether the menu panel shows its option toggles and app entries, or the
    /// collapsed status-and-controls-only layout (the panel's "Show less" row).
    var menuPanelExpanded: Bool {
        get { settings.menuPanelExpanded }
        set {
            settings.menuPanelExpanded = newValue
            persist()
        }
    }

    /// How see-through the panel and windows are, 0 (frosted default) to 100
    /// (clearest glass). Mirrored into ``GlassClarity`` so every glass
    /// surface updates live while the slider moves.
    var glassClarity: Int {
        get { settings.glassClarity }
        set {
            settings.glassClarity = newValue
            GlassClarity.shared.value = Double(settings.glassClarity) / 100
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
    ///
    /// - Returns: how many `.shell` event hooks were disabled for safety on the
    ///   way in (see ``KeepressoSettings/disarmingImportedShellHooks()``), so
    ///   the caller can flag them for review.
    @discardableResult
    func importSettings(from data: Data) throws -> Int {
        let (disarmed, disabledShellHooks) =
            try SettingsTransfer.importSettings(from: data).disarmingImportedShellHooks()
        var imported = disarmed
        // An export from an older build can predate built-ins added since; seed
        // and refresh them the same way launch does so the import isn't
        // missing new defaults or carrying outdated ones.
        imported.seedNewBuiltInPresets()
        imported.refreshBuiltInPresets()
        apply(imported)
        return disabledShellHooks
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
        session.endingSoonNotice = newSettings.endingSoonNoticeSeconds
        session.endAction = newSettings.endAction
        session.pauseBelowBatteryPercent = newSettings.pauseBelowBatteryPercent
        session.pauseWhenHot = newSettings.thermalSafety?.stopBrewing ?? false
        session.leases = newSettings.automationLeasesEnabled ? leaseEngine : nil
        hookDispatcher.hooks = newSettings.eventHooks
        applyWakeScheduleToSystem()
        // The guard's didSet queues fan/pause releases if it was mid-emergency.
        thermalGuard.config = effectiveThermalConfig(newSettings.thermalSafety)
        GlassClarity.shared.value = Double(newSettings.glassClarity) / 100
        disk.config = newSettings.diskKeepAlive
        virtualDisplay.config = newSettings.virtualDisplay
        awdl.autoWithGaming = newSettings.awdlAutoWithGaming
        closedDisplayAuto.onlyWhileBrewing = newSettings.closedDisplayOnlyWhileBrewing
        controllerPoker.enabled = newSettings.controllerPokeWhileGaming
        gamePriority.autoWithGaming = newSettings.gamePriorityBoost
        if !newSettings.closedDisplayOnlyWhileBrewing {
            // An import that turns the automation off must also release any
            // hold it had (autoTick won't, it early-returns once it's off).
            Task { await closedDisplayAuto.stopIfHolding() }
        }
        triggersPaused = false // a fresh config always comes in unpaused, like launch
        applyTriggerGate()
        // Any imported feature that speaks through a notification (safety
        // pauses, reminders, the password notice for the helperless auto
        // features) needs authorization, exactly as `init` and the per-feature
        // setters request it. Without this, an import on a Mac that never
        // granted notifications would let a battery or thermal pause stop the
        // session with no banner, looking as if the app just quit.
        if newSettings.pauseBelowBatteryPercent != nil
            || newSettings.thermalSafety?.stopBrewing == true
            || newSettings.reminderAfter != nil
            || newSettings.notifyOnEnd
            || newSettings.endingSoonNoticeSeconds != nil
            || newSettings.closedDisplayOnlyWhileBrewing
            || newSettings.awdlAutoWithGaming {
            notifier.requestAuthorization()
        }
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
        widgetSync.write(
            SharedSessionState(
                isActive: session.isActive,
                endsAt: endsAt,
                triggersEnabled: settings.triggersEnabled,
                triggersPaused: triggersPaused
            ),
            leaseIDs: session.liveLeases.map(\.id).sorted(),
            leasesEnabled: settings.automationLeasesEnabled,
            lastWakeRequestId: lastWakeRequestId,
            lastWakeRequestOutcome: lastWakeRequestOutcome
        )
    }

    /// On quit, leave the widgets showing "off": the session's assertions die
    /// with this process, and a stale "Brewing" tile would lie until the next
    /// launch.
    func writeWidgetStateStopped() {
        widgetSync.write(
            SharedSessionState(
                isActive: false,
                triggersEnabled: settings.triggersEnabled,
                triggersPaused: triggersPaused
            ),
            leasesEnabled: settings.automationLeasesEnabled
        )
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

    // MARK: - Automation leases

    /// The engine the session polls for lease demand, and the revocation
    /// surface for explicit stops.
    @ObservationIgnored private let leaseEngine = LeaseEngine()

    /// Whether outside tools may hold automation leases (Preferences ▸
    /// Automation). Turning it off revokes every live lease, so their
    /// clients hear "revoked" at the next heartbeat instead of wondering
    /// why the Mac sleeps.
    var automationLeasesEnabled: Bool {
        get { settings.automationLeasesEnabled }
        set {
            settings.automationLeasesEnabled = newValue
            if !newValue { revokeLeases() }
            session.leases = newValue ? leaseEngine : nil
            persist()
            syncWidgetState()
        }
    }

    /// An explicit user stop must win over lease demand: end every live
    /// lease first, or the session would flap back on the very next tick
    /// with no feedback. Clients discover the revocation on heartbeat.
    private func revokeLeases() {
        leaseEngine.revokeAll(now: Date())
    }

    /// The menu's explicit lease stop, offered ahead of Pause Triggers while
    /// leases are live: revoke every lease so clients hear "revoked" on
    /// their next heartbeat. A lease-held session stops silently (a user
    /// gesture, not a natural end, so no end action fires); a trigger-held
    /// one just loses its lease rows on the immediate reconcile.
    func endAutomationLeases() {
        revokeLeases()
        if session.isLeaseHeld {
            session.stop()
        } else {
            session.reconcile()
        }
        syncWidgetState()
    }

    // MARK: - Teach-your-agent helpers

    /// The bundled skill folder inside Resources.
    private var agentSkillURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/AgentSkill/keep-awake", isDirectory: true)
    }

    /// The embedded MCP server binary, absolute path of THIS install (a dev
    /// build's path differs from /Applications).
    private var mcpServerPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/keepresso-mcp").path
    }

    /// Copy a simple text pointing to the bundled skill folder path.
    func copyAgentInstructions() {
        let skillPath = agentSkillURL.appendingPathComponent("SKILL.md").path
        let text = "Install SKILL.md from \(skillPath) globally"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Paste-ready MCP configuration per agent flavor. Claude Code, Gemini
    /// CLI, and Grok all read the same `mcpServers` JSON shape; they get
    /// their own menu entries anyway because users look for their tool's
    /// name, not its file format.
    enum MCPSetupFormat {
        case mcpServersJSON
        case codexTOML
        case serverPath
    }

    func copyMCPSetup(_ format: MCPSetupFormat) {
        let snippet: String
        switch format {
        case .mcpServersJSON:
            snippet = """
            {
              "mcpServers": {
                "keepresso": {
                  "command": "\(mcpServerPath)"
                }
              }
            }
            """
        case .codexTOML:
            snippet = """
            [mcp_servers.keepresso]
            command = "\(mcpServerPath)"
            enabled = true
            """
        case .serverPath:
            snippet = mcpServerPath
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet, forType: .string)
    }

    /// Show the bundled skill folder in Finder so it can be copied into an
    /// agent's skills directory.
    func revealAgentSkill() {
        NSWorkspace.shared.activateFileViewerSelecting([agentSkillURL])
    }

    // MARK: - Automation wake requests

    /// Whether outside tools may change the wake schedule (Preferences ▸
    /// Automation). Off by default: a wake schedule is a root-applied
    /// system change, so it stays opt-in, unlike leases.
    var automationWakeControlEnabled: Bool {
        get { settings.automationWakeControlEnabled }
        set {
            settings.automationWakeControlEnabled = newValue
            persist()
        }
    }

    /// The last processed request and its outcome, mirrored into
    /// `status.json` so `keepresso wake set` / `clear` can confirm.
    @ObservationIgnored private var lastWakeRequestId: String?
    @ObservationIgnored private var lastWakeRequestOutcome: String?

    /// Process a pending automation wake request, if any. Runs on the
    /// `sync-leases` doorbell; the request file is consumed either way so a
    /// rejected request can never fire arbitrarily later.
    private func processAutomationWakeRequest() {
        guard let request = AutomationWakeRequestFile.read() else { return }
        AutomationWakeRequestFile.delete()
        let outcome: AutomationWakeOutcome
        if !settings.automationWakeControlEnabled {
            outcome = .disabled
        } else {
            switch AutomationWakeControl.adjudicate(request, now: Date()) {
            case .invalid:
                outcome = .invalid
            case .apply(nil):
                // Clearing is always allowed, helper or not, matching the
                // Preferences "Turn Off Wake Schedule" path.
                wakeSchedule = nil
                outcome = .applied
            case .apply(let config?):
                if canEditWakeSchedule {
                    // Keep the user's session-on-wake behavior; the request
                    // only speaks about times.
                    var merged = config
                    if let existing = settings.wakeSchedule {
                        merged.startSessionOnWake = existing.startSessionOnWake
                        merged.sessionDurationSeconds = existing.sessionDurationSeconds
                        merged.presetID = existing.presetID
                    }
                    wakeSchedule = merged
                    outcome = .applied
                } else {
                    outcome = .helperUnavailable
                }
            }
        }
        lastWakeRequestId = request.requestId
        lastWakeRequestOutcome = outcome.rawValue
    }

    // MARK: - URL scheme commands

    /// Handle a `keepresso://` command from ``URLCommand/parse(_:)``. Acts like
    /// the manual toggle/duration picker. When trigger gating is on it pauses
    /// triggers first (the same in-memory pause as the menu's Pause Triggers,
    /// nothing persisted): otherwise the gate would silently override the
    /// command on the next once-a-second reconcile, turning it into a no-op
    /// with no feedback to the script that fired it.
    func handle(_ command: URLCommand) {
        // The automation doorbell is not a session command: it must not
        // pause triggers or touch the session, only process pending
        // automation inputs and bring the next reconcile (and the
        // acknowledgments in status.json) forward to now.
        if command == .syncLeases {
            processAutomationWakeRequest()
            session.reconcile()
            // Unconditional write: a stale status.json left by another
            // process (an old instance's quit snapshot) must not swallow
            // this acknowledgment.
            widgetSync.forceNextWrite()
            syncWidgetState()
            return
        }
        // Capture before pausing: pauseTriggers() stops the session. Pass
        // .command so pausing a trigger-held session logs the stop as the
        // command that caused it, not "Stopped manually".
        let wasActive = session.isActive
        pauseTriggers(cause: .command)
        switch command {
        case .start(let mode):
            session.start(mode: mode, cause: .command)
        case .stop:
            revokeLeases()
            session.stop(cause: .command)
        case .toggle:
            // Mirror toggleManual(), using the saved default duration rather
            // than the controller's in-memory mode (never seeded after launch).
            if wasActive {
                revokeLeases()
                session.stop(cause: .command)
            } else {
                session.start(mode: settings.defaultMode, cause: .command)
            }
        case .syncLeases:
            break // handled above
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
        panel.prompt = L("Keep Awake")
        panel.message = L("Choose a folder on the disk you want to keep spun up.")
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

    // MARK: - Claude Code hooks

    /// Where the Claude Code hook install stands. Refreshed by explicit
    /// actions and when the Triggers pane appears; a cheap read of one file.
    private(set) var claudeHooks: AgentHooks.HookInstallState = .notInstalled

    /// The last hook install/remove failure, shown under the status row.
    private(set) var claudeHooksError: String?

    func refreshClaudeHooksStatus() {
        do {
            claudeHooks = AgentHooks.hookInstallState(
                of: try AgentHooks.readSettings(at: AgentHooks.claudeSettingsURL()))
        } catch {
            // An existing file we can't read must report as unreadable, not
            // "not installed": the latter invites the install click, and an
            // install that mistakes a full settings.json for a missing one
            // would replace the user's whole Claude Code configuration.
            claudeHooks = .unreadable
        }
    }

    /// Merge Keepresso's hook entries into `~/.claude/settings.json` so
    /// Claude Code sessions report exact working/waiting/idle edges. Runs
    /// only on an explicit click, never from merely opening a window.
    func installClaudeHooks() {
        mutateClaudeSettings { existing in
            try AgentHooks.installHooks(into: existing, cliPath: Self.bundledCLIPath)
        }
    }

    /// Remove exactly Keepresso's hook entries, leaving everything else in
    /// the settings file untouched. Clears the session records too: with no
    /// hooks left to emit Stop or SessionEnd, a retained working record
    /// would hold the trigger for as long as its agent runs.
    func removeClaudeHooks() {
        if mutateClaudeSettings({ try AgentHooks.removeHooks(from: $0) }) {
            AgentHooks.purgeRecords()
        }
    }

    /// The bundled CLI's absolute path, baked into the installed hook
    /// command so it works regardless of PATH (DMG installs put nothing on
    /// PATH, and hook shells may run with launchd's minimal one).
    private static var bundledCLIPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/keepresso").path
    }

    /// Rewrites `~/.claude/settings.json` through `transform` and reports
    /// whether the write landed, so callers can gate follow-up cleanup on it.
    @discardableResult
    private func mutateClaudeSettings(_ transform: (Data?) throws -> Data) -> Bool {
        let url = AgentHooks.claudeSettingsURL()
        defer { refreshClaudeHooksStatus() }
        do {
            // readSettings distinguishes "no file yet" from "exists but
            // unreadable" and throws on the latter: treating a read failure
            // as absence would make the atomic write below replace the
            // user's whole settings file with just our hooks.
            let updated = try transform(try AgentHooks.readSettings(at: url))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Resolve a symlinked settings.json (dotfiles setups) so the
            // atomic write replaces the real file, not the link.
            try updated.write(to: url.resolvingSymlinksInPath(), options: .atomic)
            claudeHooksError = nil
            return true
        } catch is AgentHooks.SettingsUnreadableError {
            // The refreshed status row already explains the unreadable file;
            // a second identical line under it would just stack.
            claudeHooksError = nil
            return false
        } catch {
            claudeHooksError = L("Couldn't update Claude Code's settings file.")
            return false
        }
    }

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
            await fanDryRun.cancelAndWait()
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

    /// Watches for the approval landing while the attention window shows the
    /// switch-it-on step. The manager polls `SMAppService.status`, but that
    /// status can sit at `.enabled` the whole time (BTM disabled the daemon
    /// record behind its back), so the flip is only visible to a ping.
    @ObservationIgnored private var approvalRecoveryWatch: Task<Void, Never>?

    private func watchForApprovalRecovery() {
        approvalRecoveryWatch?.cancel()
        approvalRecoveryWatch = Task { [weak self] in
            // Five minutes of deciding time, one cheap ping per pass.
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard self.helperAttention == .needsApproval else { return }
                if await self.helper.daemonResponds() {
                    await self.verifyHelperAndFollowUp()
                    return
                }
            }
        }
    }

    /// Check that the installed helper daemon actually responds, repairing a
    /// stale registration when it doesn't (see
    /// ``HelperManager/verifyAndRepairIfNeeded()``). Called at launch, where
    /// the breakage typically surfaces (it follows an app update plus a
    /// reboot), and again from the failure edges of the privileged features.
    func verifyHelper() {
        Task { await verifyHelperAndFollowUp() }
    }

    private func verifyHelperAndFollowUp() async {
        // First clear any previous copy of the app that an update pushed into
        // the Trash: BTM's bookmark keeps resolving the helper's record into
        // the Trash and disabling the daemon while one is there, so a repair
        // before the sweep wouldn't stick.
        await Task.detached { StaleBundleCleaner.sweepNow() }.value
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
                title: L("Keepresso needs a new approval"),
                body: L("macOS turned Keepresso's background switch off. Turn it back on under Login Items & Extensions in System Settings to keep the password-free helper."),
                sound: true
            )
        case .broken:
            helperAttention = .broken
        }
        if helperAttention == .needsApproval { watchForApprovalRecovery() }
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
            // The reinstall lands on a record BTM will invalidate again if an
            // old copy still sits in the Trash; sweep before rebuilding.
            await Task.detached { StaleBundleCleaner.sweepNow() }.value
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
    func setClosedDisplay(_ on: Bool, userInitiated: Bool = true) {
        // A user toggling closed-display during a thermal pause has taken over
        // the intent: cancel any pending "restore on cooldown" so recovery
        // doesn't silently turn it back on against their choice. The thermal
        // lift/restore calls pass `userInitiated: false` so they don't clear
        // their own pending restore.
        if userInitiated { thermalLiftedClosedDisplay = false }
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
                title: L("Keepresso needs your password"),
                body: L("Enter your administrator password to switch closed-display mode on for this session."),
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

    /// Sees connected game controllers for the poke and the trigger-free
    /// Setup toggle.
    @ObservationIgnored private let controllerMonitor = GCControllerMonitor()

    /// Declares user activity during controller play (gamepad input doesn't
    /// reliably reset the HID idle timer). Enabled flag mirrored from settings.
    @ObservationIgnored let controllerPoker = ControllerActivityPoker()

    /// Boosts the frontmost game's CPU priority through the helper daemon.
    /// Lazy so the hold closure can capture self after init completes.
    @ObservationIgnored private(set) lazy var gamePriority = GamePriorityController { [weak self] holding, pid in
        guard let self, self.helperInstalled else { return }
        let client = self.helperClient
        Task.detached { _ = client.setPriorityHold(holding, pid: pid) }
    }

    /// Raise the frontmost game's CPU priority while playing (Gaming &
    /// Streaming Setup). Helper-only; the view locks the toggle otherwise.
    var gamePriorityBoost: Bool {
        get { settings.gamePriorityBoost }
        set {
            settings.gamePriorityBoost = newValue
            gamePriority.autoWithGaming = newValue // turning off releases now
            persist()
        }
    }

    /// Keep the display awake during controller play (Gaming & Streaming
    /// Setup).
    var controllerPokeWhileGaming: Bool {
        get { settings.controllerPokeWhileGaming }
        set {
            settings.controllerPokeWhileGaming = newValue
            controllerPoker.enabled = newValue
            persist()
        }
    }

    /// Once-a-second pulse for every gaming-driven automation: the AWDL
    /// watchdog's auto mode, the game priority boost, and the controller
    /// activity poke. Detects a game directly via ``gamingWatcher`` (no
    /// trigger or active session required). The guard keeps per-tick work
    /// from running while every gaming feature is off.
    func awdlAutoTick() {
        let wantsPulse = settings.awdlAutoWithGaming
            || settings.gamePriorityBoost
            || settings.controllerPokeWhileGaming
        guard wantsPulse else { return }
        gamingWatcher.tick() // advance the grace window once per pulse
        let gameInFront = gamingWatcher.wrappedIsSatisfied
        let gamingActive = gamingWatcher.isSatisfied()

        gamePriority.autoTick(
            gameFrontmost: gameInFront,
            gamingActive: gamingActive,
            frontmostPID: (gamingWatcher.wrappedTrigger as? GamingTrigger)?
                .currentSnapshot.frontmostPID
        )
        controllerPoker.tick(
            gamingActive: gamingActive,
            controllerConnected: controllerMonitor.connectedCount > 0,
            sessionActive: session.isActive
        )

        guard settings.awdlAutoWithGaming else { return }
        notifyAWDLEdges(gameInFront: gameInFront, gamingActive: gamingActive)
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
                    title: L("Keepresso needs your password"),
                    body: L("Enter your administrator password to pause AWDL for this game."),
                    sound: true
                )
            }
            if settings.awdlNotifications {
                notifier.notify(
                    title: L("Game detected"),
                    body: L("Pausing AWDL to steady your connection."),
                    sound: false
                )
            }
        }
        if !gamingActive, wasGamingActive, settings.awdlNotifications {
            notifier.notify(
                title: L("AWDL resumed"),
                body: L("The game closed; AirDrop, Handoff and Continuity are back."),
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

    /// The apps capturing the microphone right now, resolved to their top-level
    /// app identity (name + bundle id), for the "add the app using your mic
    /// now" affordance in the mic-scope editor. Reads the per-process CoreAudio
    /// state (unprivileged, no prompt); each capturing process, often an
    /// Electron helper, is resolved back to its enclosing `.app` so the picker
    /// shows "Discord" and stores `com.hnc.Discord`, not the helper id.
    func micAppsInUse() -> [(name: String, bundleID: String)] {
        var seen = Set<String>()
        var apps: [(name: String, bundleID: String)] = []
        for capturer in CoreMediaActivityMonitor.currentMicCapturers() {
            let resolved = Self.resolveCapturingApp(pid: capturer.pid, rawBundleID: capturer.bundleID)
            guard seen.insert(resolved.bundleID).inserted else { continue }
            apps.append(resolved)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Well-known call apps offered as one-click choices in the mic-scope
    /// editor, for when the user is setting up a rule while not currently on a
    /// call. Some apps ship under more than one bundle id (Teams classic vs the
    /// new client, Telegram from the App Store vs Telegram Desktop); the preset
    /// carries every variant so it matches whichever is installed, since the
    /// matcher fires on any id in a rule's list. Anything not here is added via
    /// the live "using the mic now" list or the app picker, both of which read
    /// the real bundle id and never guess (e.g. TeamSpeak, whose ids vary).
    static let callAppPresets: [(name: String, bundleIDs: [String])] = [
        ("Discord", ["com.hnc.Discord"]),
        ("Slack", ["com.tinyspeck.slackmacgap"]),
        ("Zoom", ["us.zoom.xos"]),
        ("Microsoft Teams", ["com.microsoft.teams", "com.microsoft.teams2"]),
        ("Telegram", ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        ("FaceTime", ["com.apple.FaceTime"]),
        ("Webex", ["com.cisco.webexmeetingsapp"]),
    ]

    /// Resolve a microphone-capturing process to its top-level app. Prefers the
    /// enclosing `.app` bundle read from the executable path (so an Electron
    /// helper maps to its parent app), then a running-app lookup by pid, and
    /// finally the raw bundle id CoreAudio reported (still matchable by prefix).
    private static func resolveCapturingApp(pid: pid_t, rawBundleID: String) -> (name: String, bundleID: String) {
        if let path = executablePath(forPID: pid),
           let url = CoreMediaActivityMonitor.enclosingAppBundleURL(forExecutablePath: path),
           let bundle = Bundle(url: url),
           let id = bundle.bundleIdentifier {
            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return (name, id)
        }
        if let running = NSRunningApplication(processIdentifier: pid),
           let id = running.bundleIdentifier {
            return (running.localizedName ?? id, id)
        }
        return (rawBundleID, rawBundleID)
    }

    private static func executablePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
