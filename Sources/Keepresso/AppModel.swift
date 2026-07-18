import AppKit
import Observation
import UserNotifications
import KeepressoCore

private final class AppWakeIntentBox: WakeKeepAliveIntentControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isIntended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setKeepAliveIntended(_ intended: Bool) {
        lock.lock()
        value = intended
        lock.unlock()
    }
}

enum CodexAgentPhase: String, Equatable {
    case idle
    case preparing
    case launching
    case awaitingLease
    case leased
    case readinessFailed
}

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
    /// Structured Agent lease and unattended orchestration audit log.
    @ObservationIgnored let unattendedAuditLog = UnattendedAuditLog()
    /// Live `pmset -g sched` view for Preferences.
    @ObservationIgnored private let wakeReader: WakeScheduleReading
    /// Cached system wake schedule for the Automation tab.
    private(set) var systemWakeState: SystemWakeState = .empty
    /// Active and recently completed explicit Agent wake leases.
    private(set) var agentLeaseSnapshot = AgentLeaseSnapshot(
        capturedAt: .distantPast,
        leases: []
    )
    /// Last registry read or persistence error, if the lease channel is down.
    private(set) var agentLeaseError: String?
    /// Enabled local Codex automation metadata. Prompts never enter this model.
    private(set) var codexAutomations: [CodexAutomation] = []
    /// Safe discovery issues, reported as a count without file contents.
    private(set) var codexAutomationIssueCount = 0
    /// Nearest wake plus the full queue of enabled local runs.
    private(set) var codexWakePlanning = CodexAutomationWakePlanningResult(
        wakePlan: nil,
        queuedRuns: []
    )
    /// Live preparation, launch, and lease-handoff phase.
    private(set) var codexAgentPhase: CodexAgentPhase = .idle
    /// Final time a scheduled run may wait for its first explicit lease.
    private(set) var codexLeaseHandoffDeadline: Date?
    /// Seven-day awake stats from the persisted log.
    private(set) var awakeStats: AwakeStats = .empty

    private let store: SettingsStore
    private let notifier: UserNotificationReminder
    /// Runs the privacy actions used only for unattended work. The same
    /// concrete performer is also passed to the session controller.
    @ObservationIgnored private let unattendedActionPerformer: SessionEndActing
    /// Direct line to the helper daemon for the thermal fan boost (the other
    /// privileged features go through their Routed* controllers).
    @ObservationIgnored private let helperClient: PrivilegedHelperCalling
    /// Durable lease union shared with CLI, Skill, and MCP clients.
    @ObservationIgnored private var agentLeaseRegistry: AgentLeaseRegistry?
    /// Pure ownership state for manual sessions, user gates, and external work.
    @ObservationIgnored private var externalWakeCoordinator = ExternalWakeDemandCoordinator()
    /// External source joined with the existing user trigger engine.
    @ObservationIgnored private let externalWakeTrigger = MutableTriggerEvaluator()
    /// Scheduled preparation and handoff sources in the external wake union.
    @ObservationIgnored private var scheduledWakeDemands: Set<ScheduledWakeDemand> = []
    /// Lease IDs already active before the current scheduled preparation.
    @ObservationIgnored private var scheduledLeaseBaseline: Set<UUID> = []
    @ObservationIgnored private var currentScheduledRuns: [CodexAutomationQueuedRun] = []
    @ObservationIgnored private var scheduledHandoffLeaseIDs: Set<UUID> = []
    @ObservationIgnored private var lastHandledCodexRun: Date?
    /// Preparation pipeline for power, network, application launch, and timeout.
    @ObservationIgnored private var codexOrchestration: UnattendedOrchestrationController?
    @ObservationIgnored private let wakeIntentBox = AppWakeIntentBox()
    @ObservationIgnored private var codexDiscoveryInFlight = false
    @ObservationIgnored private var lastCodexDiscoveryAt: Date?
    @ObservationIgnored private var lastInstalledCodexWake: Date?
    @ObservationIgnored private var externalPrivacyApplied = false
    private(set) var settings: KeepressoSettings
    /// Avoid double-starting on a single system wake.
    @ObservationIgnored private var lastWakeBrewAt: Date?
    /// While armed, the session uses the unattended end action instead of the
    /// user's interactive-session preference.
    @ObservationIgnored private var unattendedSessionArmed = false

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
        self.unattendedActionPerformer = endActor
        self.session = SessionController(reminder: notifier, endActor: endActor)
        self.session.options = loaded.options
        self.session.reminderAfter = loaded.reminderAfter
        self.session.reminderRepeats = loaded.reminderRepeats
        self.session.reminderSound = loaded.reminderSound
        self.session.notifyOnEnd = loaded.notifyOnEnd
        self.session.endingSoonNotice = loaded.endingSoonNoticeSeconds
        self.session.endAction = loaded.endAction
        self.session.pauseBelowBatteryPercent = loaded.pauseBelowBatteryPercent
        self.session.pauseWhenHot = loaded.thermalSafety?.stopBrewing ?? false
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
        // Decision log → outbound hooks + disk. After every stored property
        // is initialized so weak self is legal.
        self.session.log.onRecord = { [weak hooks, weak logPersister, weak self] event in
            hooks?.handle(sessionEvent: event)
            let persisted = PersistedSessionEvent(event, batteryPercent: event.batteryPercent)
            logPersister?.append(persisted)
            self?.recordForStats(persisted)
            if let kind = event.kind,
               [SessionEventKind.sessionEnded, .triggerReleased, .batteryPaused, .thermalPaused, .startRefused]
                .contains(kind) {
                // SessionController records before it snapshots the pending
                // end action. Defer restoration one actor turn so an
                // unattended completion still captures its sleep action.
                Task { @MainActor [weak self] in
                    self?.disarmUnattendedPowerPolicy()
                }
            }
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
            guard let self else { return nil }
            var held: [String] = []
            if self.agentLeaseSnapshot.activeCount > 0 {
                held.append(L("%d active Agent lease(s)", self.agentLeaseSnapshot.activeCount))
            }
            if !self.scheduledWakeDemands.isEmpty {
                held.append(L("Codex automation preparation"))
            }
            if let states = self.ruleStates() {
                held.append(contentsOf: states.filter(\.satisfied).map(\.rule.label))
            }
            return held.isEmpty ? nil : held.joined(separator: ", ")
        }
        do {
            let registry = try AgentLeaseRegistry()
            self.agentLeaseRegistry = registry
            registry.onEvent = { [weak self] event in
                self?.handleAgentLeaseEvent(event)
            }
            registry.onSnapshotChange = { [weak self] snapshot in
                self?.adoptAgentLeaseSnapshot(snapshot, at: snapshot.capturedAt)
            }
            for lease in registry.currentSnapshot.activeLeases {
                unattendedAuditLog.recordLeaseEvent(AgentLeaseLifecycleEvent(
                    date: Date(),
                    kind: .restored,
                    source: .recovery,
                    lease: lease
                ))
            }
            adoptAgentLeaseSnapshot(registry.currentSnapshot, at: Date())
        } catch {
            agentLeaseError = L("The Agent lease registry could not be opened.")
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

    func recentUnattendedAudit(limit: Int = 30) -> [UnattendedAuditRecord] {
        unattendedAuditLog.loadRecent(limit: limit)
    }

    var unattendedAuditLogPath: String { unattendedAuditLog.fileURL.path }

    var bundledMCPServerPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/keepresso-mcp", isDirectory: false)
            .path
    }

    func revealBundledAgentSkill() {
        guard let resources = Bundle.main.resourceURL else { return }
        let candidates = [
            resources.appendingPathComponent("keepresso-power", isDirectory: true),
            resources.appendingPathComponent("Skills/keepresso-power", isDirectory: true),
        ]
        guard let skill = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path)
        }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([skill])
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
        guard !hasExternalWakeDemand else { return }
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
        guard !hasExternalWakeDemand else { return }
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
            if !hasExternalWakeDemand { session.stop() }
            applyTriggerGate()
            if hasExternalWakeDemand { session.reconcile() }
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
        if !hasExternalWakeDemand { session.stop(cause: cause) }
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
        let userGate: (any TriggerEvaluating)? =
            (settings.triggersEnabled && !triggersPaused) ? gate.engine : nil
        if externalWakeTrigger.isOn {
            if let userGate {
                session.triggerGate = AnyTriggerEvaluator([userGate, externalWakeTrigger])
            } else {
                session.triggerGate = externalWakeTrigger
            }
        } else {
            session.triggerGate = userGate
        }
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
            if !unattendedSessionArmed { session.endAction = newValue }
            persist()
        }
    }

    /// Privacy and shutdown behavior used by scheduled and Agent-driven work.
    var unattendedPowerPolicy: UnattendedPowerPolicy {
        get { settings.unattendedPowerPolicy }
        set {
            settings.unattendedPowerPolicy = newValue
            if unattendedSessionArmed { session.endAction = newValue.endAction }
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

    // MARK: - Explicit Agent wake leases

    var activeAgentLeases: [AgentWakeLease] { agentLeaseSnapshot.activeLeases }

    var hasExternalWakeDemand: Bool { !externalWakeCoordinator.demand.isEmpty }

    var unattendedStatusPhase: String? {
        if codexAgentPhase != .idle { return codexAgentPhase.rawValue }
        if agentLeaseSnapshot.activeCount > 0 { return CodexAgentPhase.leased.rawValue }
        return nil
    }

    /// Poll the cross-process lease registry and apply TTL watchdog deadlines.
    /// Called from the existing one-second ticker.
    func agentLeaseTick() {
        guard let agentLeaseRegistry else { return }
        do {
            let snapshot = try agentLeaseRegistry.watchdogTick()
            adoptAgentLeaseSnapshot(snapshot, at: snapshot.capturedAt)
        } catch {
            agentLeaseError = L("The Agent lease registry could not be read.")
        }
    }

    private func handleAgentLeaseEvent(_ event: AgentLeaseLifecycleEvent) {
        unattendedAuditLog.recordLeaseEvent(event)
        if event.kind == .timedOut {
            notifier.notify(
                title: L("Agent wake lease expired"),
                body: L("An Agent stopped renewing its lease. Keepresso released that task's wake request safely."),
                sound: false
            )
        }
    }

    private func adoptAgentLeaseSnapshot(_ snapshot: AgentLeaseSnapshot, at date: Date) {
        agentLeaseSnapshot = snapshot
        agentLeaseError = nil
        reconcileExternalWakeDemand(at: date)
        codexLeaseHandoffIfNeeded(at: date)
    }

    /// Reconcile every external source atomically, then translate the pure Core
    /// ownership decision into the existing SessionController seams.
    private func reconcileExternalWakeDemand(at date: Date) {
        let userGateInstalled = settings.triggersEnabled && !triggersPaused
        let demand = ExternalWakeDemandSnapshot(
            activeLeaseIDs: Set(agentLeaseSnapshot.activeLeases.map(\.id)),
            scheduled: scheduledWakeDemands
        )
        let decision = externalWakeCoordinator.update(
            demand,
            session: ExternalWakeSessionObservation(
                isSessionActive: session.isActive,
                isUserTriggerGateInstalled: userGateInstalled
            ),
            at: date
        )

        if case .began = decision.lifecycle {
            externalPrivacyApplied = false
            prepareUnattendedPowerPolicy()
        }

        externalWakeTrigger.isOn = !demand.isEmpty
        closedDisplayAuto.onlyWhileBrewing = settings.closedDisplayOnlyWhileBrewing || !demand.isEmpty
        applyTriggerGate()

        if demand.isEmpty {
            externalPrivacyApplied = false
            switch decision.sessionAction {
            case .preserveManualSession:
                disarmUnattendedPowerPolicy()
                session.reconcile(now: date)
            case .returnToUserTriggerGate:
                if userGateInstalled {
                    session.reconcile(now: date)
                    if session.isActive { disarmUnattendedPowerPolicy() }
                } else {
                    finishExternalSession(at: date)
                }
            case .finishUnattendedSession:
                if userGateInstalled {
                    session.reconcile(now: date)
                    if session.isActive { disarmUnattendedPowerPolicy() }
                } else {
                    finishExternalSession(at: date)
                }
            case .none, .ensureSessionActive:
                break
            }
            if case .ended = decision.lifecycle,
               !settings.closedDisplayOnlyWhileBrewing {
                Task { await closedDisplayAuto.stopIfHolding() }
            }
            return
        }

        if decision.sessionAction == .ensureSessionActive {
            prepareUnattendedPowerPolicy()
            session.reconcile(now: date)
        }
        if session.isActive, !externalPrivacyApplied {
            performUnattendedPrivacyActions()
            externalPrivacyApplied = true
        }
    }

    private func finishExternalSession(at date: Date) {
        if session.isActive {
            session.finishUnattended(reason: "All Agent and scheduled work finished")
        } else {
            disarmUnattendedPowerPolicy()
        }
        session.reconcile(now: date)
    }

    // MARK: - Codex automation wake handoff

    var codexAutomation: CodexAutomationSettings {
        get { settings.codexAutomation }
        set {
            if newValue.enabled, !canEditWakeSchedule { return }
            let wasEnabled = settings.codexAutomation.enabled
            settings.codexAutomation = newValue
            persist()
            if !newValue.enabled {
                cancelCodexPreparation(at: Date())
                codexAutomations = []
                codexAutomationIssueCount = 0
                codexWakePlanning = CodexAutomationWakePlanningResult(
                    wakePlan: nil,
                    queuedRuns: []
                )
                lastInstalledCodexWake = nil
                applyWakeScheduleToSystem()
            } else {
                refreshCodexAutomationPlan(force: !wasEnabled)
            }
        }
    }

    /// Read active local Codex schedules off the main actor, then derive the
    /// nearest system wake and the complete next-run queue.
    func refreshCodexAutomationPlan(force: Bool = false) {
        let policy = settings.codexAutomation
        guard policy.enabled else { return }
        let now = Date()
        if !force, let last = lastCodexDiscoveryAt,
           now.timeIntervalSince(last) < 60 { return }
        guard !codexDiscoveryInFlight else { return }
        codexDiscoveryInFlight = true
        let searchAfter = max(
            now,
            lastHandledCodexRun?.addingTimeInterval(1) ?? now
        )
        Task.detached {
            let result = CodexAutomationDiscovery().discover()
            let planning = CodexAutomationWakePlanner(
                leadTime: policy.wakeLeadTime
            ).plan(for: result.automations, after: searchAfter)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.codexDiscoveryInFlight = false
                self.lastCodexDiscoveryAt = Date()
                guard self.settings.codexAutomation.enabled else { return }
                self.codexAutomations = result.automations
                self.codexAutomationIssueCount = result.issues.count
                self.codexWakePlanning = planning
                self.unattendedAuditLog.record(UnattendedDiagnosticEvent(
                    date: Date(),
                    kind: result.issues.isEmpty ? .discoveryCompleted : .discoveryFailed,
                    automationCount: result.automations.count,
                    issueCount: result.issues.count
                ))
                if let plan = planning.wakePlan {
                    self.unattendedAuditLog.record(plan.diagnosticEvent(at: Date()))
                }
                let wake = planning.wakePlan?.scheduledWake
                if wake != self.lastInstalledCodexWake {
                    self.lastInstalledCodexWake = wake
                    self.applyWakeScheduleToSystem()
                }
                self.beginCodexPreparationIfNeeded(at: Date())
            }
        }
    }

    /// Per-second orchestration pulse. Discovery itself is rate-limited to a
    /// minute; readiness and task state use the injected host tick.
    func codexAutomationTick() {
        let now = Date()
        guard settings.codexAutomation.enabled else { return }
        if codexAgentPhase == .idle || codexAgentPhase == .readinessFailed {
            refreshCodexAutomationPlan()
            beginCodexPreparationIfNeeded(at: now)
        }
        guard let orchestration = codexOrchestration else {
            codexLeaseHandoffIfNeeded(at: now)
            return
        }
        orchestration.tick(at: now)
        switch orchestration.state {
        case .preparing:
            codexAgentPhase = .preparing
        case .running:
            codexAgentPhase = .launching
        case .completed:
            enterCodexLeaseHandoff(at: now)
        case .readinessFailed:
            failCodexPreparation(
                title: L("Codex automation was not started"),
                body: L("Power, network, or the Codex application did not become ready in time."),
                at: now
            )
        case .cancelled:
            cancelCodexPreparation(at: now)
        case .idle:
            break
        }
        codexLeaseHandoffIfNeeded(at: now)
    }

    private func beginCodexPreparationIfNeeded(at date: Date) {
        guard settings.codexAutomation.enabled,
              codexAgentPhase == .idle || codexAgentPhase == .readinessFailed,
              let nearest = codexWakePlanning.queuedRuns.first
        else { return }
        let policy = settings.codexAutomation
        let preparationStart = nearest.scheduledRun.addingTimeInterval(-policy.wakeLeadTime)
        let handoffEnd = nearest.scheduledRun.addingTimeInterval(policy.leaseHandoffTimeout)
        guard date >= preparationStart, date <= handoffEnd else { return }
        guard wakeHelperGate == .ready else {
            failCodexPreparation(
                title: L("Codex automation needs the administrator helper"),
                body: L("Install and approve the helper before relying on unattended wake or closed-lid work."),
                at: date
            )
            return
        }

        let groupingWindow: TimeInterval = 60
        currentScheduledRuns = codexWakePlanning.queuedRuns.filter {
            $0.scheduledRun <= nearest.scheduledRun.addingTimeInterval(groupingWindow)
        }
        // Capture every retained ID, not only active ones. A completed lease
        // from before this handoff must not become a new claim later.
        scheduledLeaseBaseline = Set(agentLeaseSnapshot.leases.map(\.id))
        scheduledHandoffLeaseIDs = []
        scheduledWakeDemands = Set(currentScheduledRuns.map {
            ScheduledWakeDemand(id: $0.automationID, phase: .preparation)
        })
        codexLeaseHandoffDeadline = currentScheduledRuns
            .map { $0.scheduledRun.addingTimeInterval(policy.leaseHandoffTimeout) }
            .max()
        codexAgentPhase = .preparing
        reconcileExternalWakeDemand(at: date)

        let launchTask = UnattendedTaskDefinition(
            id: "launch-codex-app",
            name: "Open Codex",
            automationID: nearest.automationID,
            target: .application(bundleIdentifier: policy.applicationBundleIdentifier),
            timeout: min(60, policy.readinessTimeout)
        )
        let requirements = WakeReadinessRequirements(
            tasks: [launchTask],
            powerPolicy: WakePowerPolicy(
                requireExternalPower: policy.requireExternalPower,
                minimumBatteryPercentage: policy.minimumBatteryPercentage
            ),
            networkRequired: policy.requireNetwork
        )
        let orchestration = UnattendedOrchestrationController(
            intent: wakeIntentBox,
            probe: SystemWakeReadinessProbe(),
            launcher: SystemUnattendedTaskLauncher(),
            readinessPolicy: WakeReadinessPolicy(timeout: policy.readinessTimeout),
            diagnostics: unattendedAuditLog
        )
        codexOrchestration = orchestration
        orchestration.begin(tasks: [launchTask], requirements: requirements, at: date)
    }

    private func enterCodexLeaseHandoff(at date: Date) {
        guard codexAgentPhase != .awaitingLease, codexAgentPhase != .leased else { return }
        scheduledWakeDemands = Set(currentScheduledRuns.map {
            ScheduledWakeDemand(id: $0.automationID, phase: .handoff)
        })
        codexAgentPhase = .awaitingLease
        codexOrchestration = nil
        reconcileExternalWakeDemand(at: date)
    }

    private func codexLeaseHandoffIfNeeded(at date: Date) {
        if codexAgentPhase == .awaitingLease || codexAgentPhase == .preparing
            || codexAgentPhase == .launching {
            let claims = CodexLeaseHandoffPolicy.matchedClaims(
                runs: currentScheduledRuns,
                leases: agentLeaseSnapshot.leases,
                excluding: scheduledLeaseBaseline
            )
            scheduledHandoffLeaseIDs = Set(claims.values)
            let expectedLeaseCount = max(1, currentScheduledRuns.count)
            if claims.count >= expectedLeaseCount {
                scheduledWakeDemands.removeAll()
                codexAgentPhase = .leased
                codexLeaseHandoffDeadline = nil
                codexOrchestration?.cancel(at: date)
                codexOrchestration = nil
                markCurrentCodexRunsHandled()
                // The new lease IDs and removed scheduled sources enter the
                // ownership coordinator in one snapshot, with no sleep gap.
                reconcileExternalWakeDemand(at: date)
                refreshCodexAutomationPlan(force: true)
                return
            }
        }

        if codexAgentPhase == .leased {
            let active = Set(agentLeaseSnapshot.activeLeases.map(\.id))
            if active.isDisjoint(with: scheduledHandoffLeaseIDs) {
                scheduledHandoffLeaseIDs = []
                currentScheduledRuns = []
                codexAgentPhase = .idle
                refreshCodexAutomationPlan(force: true)
            }
            return
        }

        if let deadline = codexLeaseHandoffDeadline,
           date >= deadline,
           !scheduledWakeDemands.isEmpty {
            if !scheduledHandoffLeaseIDs.isEmpty {
                scheduledWakeDemands.removeAll()
                codexLeaseHandoffDeadline = nil
                codexAgentPhase = .leased
                markCurrentCodexRunsHandled()
                reconcileExternalWakeDemand(at: date)
                notifier.notify(
                    title: L("Some Codex automations did not claim a wake lease"),
                    body: L("Keepresso released the expired handoff requests. Any Agent leases still active remain protected."),
                    sound: false
                )
                refreshCodexAutomationPlan(force: true)
                return
            }
            failCodexPreparation(
                title: L("Codex automation did not claim a wake lease"),
                body: L("The handoff window expired, so Keepresso restored normal sleep safely."),
                at: date
            )
        }
    }

    private func failCodexPreparation(title: String, body: String, at date: Date) {
        guard codexAgentPhase != .readinessFailed || !scheduledWakeDemands.isEmpty else { return }
        codexOrchestration?.cancel(at: date)
        codexOrchestration = nil
        scheduledWakeDemands.removeAll()
        codexLeaseHandoffDeadline = nil
        markCurrentCodexRunsHandled()
        codexAgentPhase = .readinessFailed
        reconcileExternalWakeDemand(at: date)
        notifier.notify(title: title, body: body, sound: false)
        refreshCodexAutomationPlan(force: true)
    }

    private func cancelCodexPreparation(at date: Date) {
        codexOrchestration?.cancel(at: date)
        codexOrchestration = nil
        scheduledWakeDemands.removeAll()
        scheduledHandoffLeaseIDs = []
        codexLeaseHandoffDeadline = nil
        currentScheduledRuns = []
        codexAgentPhase = .idle
        reconcileExternalWakeDemand(at: date)
    }

    private func markCurrentCodexRunsHandled() {
        if let latest = currentScheduledRuns.map(\.scheduledRun).max() {
            lastHandledCodexRun = max(lastHandledCodexRun ?? latest, latest)
        }
    }

    private func effectiveWakeSchedule(at date: Date = Date()) -> WakeScheduleConfig {
        CodexWakeSchedulePolicy.effective(
            manual: settings.wakeSchedule,
            codexWake: codexWakePlanning.wakePlan?.scheduledWake,
            codexEnabled: settings.codexAutomation.enabled,
            at: date
        )
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

    /// Push settings to the helper (or clear). Installing needs the helper;
    /// clearing is attempted when it answers so a disable after reinstall
    /// still drops system schedules.
    func applyWakeScheduleToSystem() {
        let now = Date()
        // A one-shot whose moment has passed can never install again (pmset
        // refuses past dates); drop it so later applies don't fail on it
        // forever.
        if let date = settings.wakeSchedule?.oneShot, date <= now {
            settings.wakeSchedule?.oneShot = nil
            persist()
        }
        let config = effectiveWakeSchedule(at: now)
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
        let now = Date()
        if let config = settings.wakeSchedule,
           WakeAndBrewPolicy.shouldStartSession(config: config, wakeDate: now),
           lastWakeBrewAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            lastWakeBrewAt = now
            prepareUnattendedPowerPolicy()
            if let presetID = config.presetID,
               let preset = settings.presets.first(where: { $0.id == presetID }) {
                applyPreset(preset)
                performUnattendedPrivacyActions()
            } else if triggersEnabled {
                // Gate owns activation; just ensure triggers are live.
                performUnattendedPrivacyActions()
            } else {
                let mode: SessionMode = {
                    if let duration = config.sessionDurationSeconds, duration > 0 {
                        return .timed(duration: duration)
                    }
                    return .indefinite
                }()
                session.start(mode: mode, cause: .command)
                if session.isActive {
                    performUnattendedPrivacyActions()
                } else {
                    disarmUnattendedPowerPolicy()
                }
            }
        }
        // A consumed manual one-shot may have been the earlier of two pending
        // wakes. Re-apply here so a later Codex wake becomes the system's next
        // one-shot even though its discovery result itself did not change.
        applyWakeScheduleToSystem()
        beginCodexPreparationIfNeeded(at: now)
    }

    /// Apply the secure defaults before an unattended task can show content.
    /// The display action does not release the system-sleep assertion.
    func armUnattendedPowerPolicy() {
        prepareUnattendedPowerPolicy()
        performUnattendedPrivacyActions()
    }

    private func prepareUnattendedPowerPolicy() {
        guard !unattendedSessionArmed else { return }
        unattendedSessionArmed = true
        session.endAction = settings.unattendedPowerPolicy.endAction
    }

    private func performUnattendedPrivacyActions() {
        guard unattendedSessionArmed else { return }
        let policy = settings.unattendedPowerPolicy
        if policy.lockScreenOnStart {
            unattendedActionPerformer.perform(.lockScreen)
        }
        if policy.sleepDisplayOnStart {
            unattendedActionPerformer.perform(.sleepDisplay)
        }
    }

    /// Restore the interactive preference after the unattended session has
    /// captured its own pending end action.
    func disarmUnattendedPowerPolicy() {
        guard unattendedSessionArmed else { return }
        unattendedSessionArmed = false
        session.endAction = settings.endAction
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
                setClosedDisplay(false)
            case .resumeBrewing:
                notifier.notify(
                    title: L("Temperatures recovered"),
                    body: L("The Mac has cooled down. Keepresso is back to normal control."),
                    sound: false
                )
                if thermalLiftedClosedDisplay {
                    thermalLiftedClosedDisplay = false
                    if helperInstalled { setClosedDisplay(true) }
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
    func importSettings(from data: Data) throws {
        var imported = try SettingsTransfer.importSettings(from: data)
        // An export from an older build can predate built-ins added since; seed
        // and refresh them the same way launch does so the import isn't
        // missing new defaults or carrying outdated ones.
        imported.seedNewBuiltInPresets()
        imported.refreshBuiltInPresets()
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
        if !hasExternalWakeDemand { session.stop() }
        settings = newSettings
        session.options = newSettings.options
        session.reminderAfter = newSettings.reminderAfter
        session.reminderRepeats = newSettings.reminderRepeats
        session.reminderSound = newSettings.reminderSound
        session.notifyOnEnd = newSettings.notifyOnEnd
        session.endingSoonNotice = newSettings.endingSoonNoticeSeconds
        session.endAction = newSettings.unattendedPowerPolicy.effectiveEndAction(
            interactive: newSettings.endAction,
            whileArmed: unattendedSessionArmed
        )
        session.pauseBelowBatteryPercent = newSettings.pauseBelowBatteryPercent
        session.pauseWhenHot = newSettings.thermalSafety?.stopBrewing ?? false
        hookDispatcher.hooks = newSettings.eventHooks
        applyWakeScheduleToSystem()
        // The guard's didSet queues fan/pause releases if it was mid-emergency.
        thermalGuard.config = effectiveThermalConfig(newSettings.thermalSafety)
        GlassClarity.shared.value = Double(newSettings.glassClarity) / 100
        disk.config = newSettings.diskKeepAlive
        virtualDisplay.config = newSettings.virtualDisplay
        awdl.autoWithGaming = newSettings.awdlAutoWithGaming
        closedDisplayAuto.onlyWhileBrewing =
            newSettings.closedDisplayOnlyWhileBrewing || hasExternalWakeDemand
        if !newSettings.closedDisplayOnlyWhileBrewing, !hasExternalWakeDemand {
            // An import that turns the automation off must also release any
            // hold it had (autoTick won't, it early-returns once it's off).
            Task { await closedDisplayAuto.stopIfHolding() }
        }
        triggersPaused = false // a fresh config always comes in unpaused, like launch
        applyTriggerGate()
        if hasExternalWakeDemand { session.reconcile() }
        registerHotKey()
        persist()
        if newSettings.codexAutomation.enabled {
            refreshCodexAutomationPlan(force: true)
        } else {
            cancelCodexPreparation(at: Date())
            codexWakePlanning = CodexAutomationWakePlanningResult(
                wakePlan: nil,
                queuedRuns: []
            )
        }
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
            unattended: UnattendedStatusMetadata(
                activeLeaseCount: agentLeaseSnapshot.activeCount,
                nextLeaseDeadline: agentLeaseSnapshot.nextDeadline,
                phase: unattendedStatusPhase,
                closedLidProtectionReady: wakeHelperGate == .ready,
                nextCodexRun: codexWakePlanning.wakePlan?.scheduledRun
            )
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
            unattended: UnattendedStatusMetadata(
                activeLeaseCount: agentLeaseSnapshot.activeCount,
                nextLeaseDeadline: agentLeaseSnapshot.nextDeadline,
                phase: unattendedStatusPhase,
                closedLidProtectionReady: false,
                nextCodexRun: codexWakePlanning.wakePlan?.scheduledRun
            )
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

    // MARK: - URL scheme commands

    /// Handle a `keepresso://` command from ``URLCommand/parse(_:)``. Acts like
    /// the manual toggle/duration picker. When trigger gating is on it pauses
    /// triggers first (the same in-memory pause as the menu's Pause Triggers,
    /// nothing persisted): otherwise the gate would silently override the
    /// command on the next once-a-second reconcile, turning it into a no-op
    /// with no feedback to the script that fired it.
    func handle(_ command: URLCommand) {
        // Manual and remote controls never weaken a lease or a scheduled
        // preparation. The owning Agent must release its own lease.
        guard !hasExternalWakeDemand else { return }
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
            closedDisplayAuto.onlyWhileBrewing = newValue || hasExternalWakeDemand
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
            } else if !newValue, !hasExternalWakeDemand {
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
        let shouldFollowSession = settings.closedDisplayOnlyWhileBrewing || hasExternalWakeDemand
        closedDisplayAuto.onlyWhileBrewing = shouldFollowSession
        guard shouldFollowSession else { return }
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
}
