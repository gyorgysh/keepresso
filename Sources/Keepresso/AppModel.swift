import AppKit
import Darwin
import Observation
import UniformTypeIdentifiers
import UserNotifications
import KeepressoCore

@MainActor
@Observable
final class AppModel {
    let session: SessionController
    let disk: DiskKeepAliveController
    let closedDisplay: ClosedDisplayController
    let closedDisplayAuto: ClosedDisplayAutoController
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
    let streaming = StreamingReadinessController()
    let keyboardLock: KeyboardLockController
    var keyboardLockOverlay: KeyboardLockOverlay?
    let captive = CaptiveNetworkController()
    let jitter = JitterTestController()
    let awdl: AWDLWatchdogController
    let thermalGuard = ThermalGuardController(
        pressure: SystemThermalPressure(),
        sensors: MachineThermalSensors()
    )
    let helper: HelperManager
    let hookDispatcher: EventHookDispatcher
    let logPersister: DecisionLogPersister
    @ObservationIgnored private let wakeReader: WakeScheduleReading
    private(set) var systemWakeState: SystemWakeState = .empty
    private(set) var awakeStats: AwakeStats = .empty
    let automationSyncController = AutomationSyncController()
    @ObservationIgnored private var automationNextWake: Date?
    @ObservationIgnored private var lastArmedEffectiveOneShot: Date?
    @ObservationIgnored private var lastAutomationRefreshAt: Date?
    @ObservationIgnored private var lastAutomationHoldAt: Date?

    private let store: SettingsStore
    private let notifier: UserNotificationReminder
    @ObservationIgnored private let helperClient: PrivilegedHelperCalling
    private(set) var settings: KeepressoSettings
    @ObservationIgnored private var lastWakeBrewAt: Date?

    static let defaultReminderAfter: TimeInterval = 30 * 60

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
            ),
            brightness: brightnessBackend
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
        self.keyboardLock = KeyboardLockController(
            locker: KeyboardLocker(
                remapper: HidutilKeyboardRemapper(),
                marker: FileKeyboardLockMarker(),
                helper: helperClient,
                helperAvailable: helperInstalled,
                privilegedApply: { OsascriptKeyboardRemapper.apply($0) }
            )
        )
        var loaded = store.load()
            .withFreshInstallDefaults(hasStoredSettings: store.hasStoredSettings)
        if !store.hasStoredSettings {
            store.save(loaded)
        }
        loaded.seedNewBuiltInPresets()
        loaded.refreshBuiltInPresets()
        self.settings = loaded
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
        self.session.leases = loaded.automationLeasesEnabled ? leaseEngine : nil
        let hooks = EventHookDispatcher(runner: SystemHookRunner())
        hooks.hooks = loaded.eventHooks
        self.hookDispatcher = hooks
        let logPersister = DecisionLogPersister()
        self.logPersister = logPersister
        self.wakeReader = PMSetWakeScheduleReader()
        self.statsHistory = []
        self.awakeStats = .empty
        self.thermalGuard.config = loaded.thermalSafety
        GlassClarity.shared.value = Double(loaded.glassClarity) / 100
        self.disk = DiskKeepAliveController()
        self.disk.config = loaded.diskKeepAlive
        self.virtualDisplay.config = loaded.virtualDisplay
        self.awdl.autoWithGaming = loaded.awdlAutoWithGaming
        self.gamingWatcher.grace = loaded.awdlGraceSeconds
        self.closedDisplayAuto.onlyWhileBrewing = loaded.closedDisplayOnlyWhileBrewing
        self.closedDisplay.policy = loaded.closedLidDisplayPolicy
        self.session.closedLidDisplayPolicy = loaded.closedLidDisplayPolicy
        self.controllerPoker.enabled = loaded.controllerPokeWhileGaming
        self.gamePriority.autoWithGaming = loaded.gamePriorityBoost
        self.session.log.onRecord = { [weak hooks, weak logPersister, weak self] event in
            hooks?.handle(sessionEvent: event)
            let persisted = PersistedSessionEvent(event, batteryPercent: event.batteryPercent)
            logPersister?.append(persisted)
            guard let self, self.decisionLogHydrated else { return }
            self.recordForStats(persisted)
        }
        if !helperManager.isInstalled,
           loaded.closedDisplayOnlyWhileBrewing || loaded.awdlAutoWithGaming {
            notifier.requestAuthorization()
        }
        if loaded.thermalSafety != nil || (loaded.hotspotFallback.enabled && loaded.hotspotFallback.notifyOnConnect) {
            notifier.requestAuthorization()
        }
        applyTriggerGate()
        session.triggerDescriber = { [weak self] in
            guard let states = self?.ruleStates() else { return nil }
            let held = states.filter(\.satisfied).map(\.rule.label)
            return held.isEmpty ? nil : held.joined(separator: ", ")
        }
    }


    private let hotspotCredentials = KeychainHotspotCredentials()
    @ObservationIgnored private lazy var hotspotNetwork = CoreWLANHotspotNetworking()
    @ObservationIgnored private(set) lazy var hotspot: HotspotFallbackController = {
        let controller = HotspotFallbackController(network: hotspotNetwork, credentials: hotspotCredentials)
        controller.config = settings.hotspotFallback
        controller.onConnected = { [weak self] ssid in
            self?.notifier.notify(title: L("Connected to hotspot"), body: ssid, sound: false)
        }
        return controller
    }()
    @ObservationIgnored private(set) lazy var closedLidLowPowerController = ClosedLidLowPowerController(helper: helperClient)
    let lidState = CachedLidState()
    private let connectivityPower = IOKitPowerSourceMonitor()
    @ObservationIgnored private var sawLowPowerHelperError = false

    var hotspotConfig: HotspotFallbackConfig {
        get { settings.hotspotFallback }
        set {
            settings.hotspotFallback = newValue.normalized()
            hotspot.config = settings.hotspotFallback
            if newValue.enabled && newValue.notifyOnConnect { notifier.requestAuthorization() }
            persist()
        }
    }
    var closedLidLowPower: Bool {
        get { settings.closedLidLowPower }
        set { settings.closedLidLowPower = newValue; persist(); connectivityTick() }
    }
    var closedLidLowPowerOnAC: Bool {
        get { settings.closedLidLowPowerOnAC }
        set { settings.closedLidLowPowerOnAC = newValue; persist(); connectivityTick() }
    }
    /// Built-in speaker mute while the lid is closed in closed-display mode.
    /// No helper and no permission: CoreAudio mute is the user's own setting.
    @ObservationIgnored private(set) lazy var speakerMute = ClosedLidSpeakerMuteController()
    var closedLidMuteSpeakers: Bool {
        get { settings.closedLidMuteSpeakers }
        set { settings.closedLidMuteSpeakers = newValue; persist(); speakerMuteTick() }
    }
    @ObservationIgnored private var checkedSpeakerMuteMarker = false
    func speakerMuteTick() {
        if !checkedSpeakerMuteMarker, !AppRelocator.isRelocating {
            checkedSpeakerMuteMarker = true
            speakerMute.restoreIfNeeded()
        }
        let enabled = settings.closedLidMuteSpeakers
        speakerMute.tick(enabled: enabled,
            lidClosed: enabled ? lidClosedThisTick() : nil, closedDisplayActive: closedDisplay.isEnabled)
    }
    private func lidClosedThisTick() -> Bool? { lidState.isClosed() }
    func saveHotspotPassword(_ password: String, ssid: String) async throws {
        try await Task.detached { [hotspotCredentials] in
            try hotspotCredentials.save(password: password, for: ssid)
        }.value
        if settings.hotspotFallback.ssid == ssid { hotspot.retryNow() }
    }
    func hasHotspotPassword(ssid: String) async -> Bool {
        await Task.detached { [hotspotCredentials] in
            ((try? hotspotCredentials.password(for: ssid)) ?? "").isEmpty == false
        }.value
    }
    func forgetHotspotPassword(ssid: String) async throws {
        try await Task.detached { [hotspotCredentials] in
            try hotspotCredentials.removePassword(for: ssid)
        }.value
        if settings.hotspotFallback.ssid == ssid {
            var config = hotspotConfig; config.enabled = false; hotspotConfig = config
        }
    }
    func connectivityTick() {
        let lowPowerFailed = closedLidLowPowerController.failed
        if lowPowerFailed, !sawLowPowerHelperError, helperInstalled { verifyHelper() }
        sawLowPowerHelperError = lowPowerFailed
        let useHotspot = settings.hotspotFallback.enabled
        let useLowPower = settings.closedLidLowPower
        guard useHotspot || useLowPower || closedLidLowPowerController.hasPendingRequests || closedLidLowPowerController.busy else { return }
        let power = connectivityPower.current
        let lidClosed = lidClosedThisTick()
        let closed = closedDisplay.isEnabled
        if useHotspot {
            hotspot.tick(conditions: HotspotConditions(sessionActive: session.isActive, lidClosed: lidClosed == true,
                closedDisplayActive: closed == true, onBattery: power.provider == .battery,
                batteryPercent: power.percentage, powerKnown: !machineHasBattery || power.provider != .unknown))
        }
        closedLidLowPowerController.tick(enabled: useLowPower, lidClosed: lidClosed, closedDisplayActive: closed,
            onBattery: power.provider == .unknown ? nil : power.provider == .battery,
            helperAvailable: helper.daemonReadyForCurrentFeatures, allowOnAC: settings.closedLidLowPowerOnAC)
    }


    @ObservationIgnored private let menuAssertionCache = CachingAssertionLister(
        inner: IOPMAssertionLister(), ttl: 3)

    func currentAssertions() -> [PowerAssertionInfo] {
        menuAssertionCache.currentUncached()
    }

    func topExternalAssertion() -> PowerAssertionInfo? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        return menuAssertionCache.current().first { $0.effect != nil && $0.pid != myPID }
    }


    let menuPanel = MenuPanelSnapshot()

    /// Whether the menu bar dropdown is on screen. The closed panel stays
    /// alive on current macOS; the ticker skips snapshot pulses while false.
    @ObservationIgnored var menuPanelVisible = false

    func pulseMenuPanelIfVisible() {
        guard menuPanelVisible else { return }
        menuPanel.pulse(elapsed: session.elapsed, external: topExternalAssertion())
    }


    @ObservationIgnored private var decisionLogHydrated = false

    func hydrateDecisionLog() {
        Task(priority: .utility) { @MainActor in
            await Task.yield()
            guard !self.decisionLogHydrated else { return }
            let history = self.logPersister.loadAll()
            // MainActor + sync loadAll: onRecord cannot interleave mid-read, so
            // any event recorded since launch is already on disk and in history.
            self.session.log.load(Array(history.suffix(DecisionLogPersister.loadLimit)))
            self.statsHistory = history
            self.awakeStats = AwakeStatsAggregator.summarize(events: history)
            self.decisionLogHydrated = true
        }
    }


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

    func startManualOverride(mode: SessionMode) {
        pauseTriggers()
        settings.defaultMode = mode
        persist()
        session.start(mode: mode)
    }

    func startUntil(hour: Int, minute: Int) {
        guard let mode = SessionMode.until(hour: hour, minute: minute) else { return }
        pauseTriggers()
        session.start(mode: mode)
    }


    var simulateUserActivity: Bool {
        get { session.options.simulateUserActivity }
        set { updateOptions { $0.simulateUserActivity = newValue } }
    }

    /// How keep-active reports activity. HID methods prompt for Accessibility
    /// only when the user switches to one, never at launch.
    var activitySimulationMethod: ActivitySimulationMethod {
        get { session.options.activitySimulationMethod }
        set {
            let wasHID = session.options.activitySimulationMethod.needsAccessibility
            updateOptions { $0.activitySimulationMethod = newValue }
            if newValue.needsAccessibility && !wasHID {
                requestAccessibilityForActivityIfNeeded()
            }
        }
    }

    var activitySimulationKey: PresenceKey? {
        get {
            session.options.activitySimulationKeyCode.map {
                PresenceKey(keyCode: $0, modifiers: session.options.activitySimulationEffectiveKeyModifiers)
            }
        }
        set {
            updateOptions {
                $0.activitySimulationKeyCode = newValue?.keyCode
                $0.activitySimulationKeyModifiers = newValue?.modifiers ?? []
            }
        }
    }

    var activityPokeIdleMinutes: Int? {
        get { session.options.activityPokeIdleMinutes }
        set { updateOptions { $0.activityPokeIdleMinutes = newValue } }
    }

    func gameFrontmostForActivityPoke() -> Bool {
        guard session.options.activityPokeIdleMinutes != nil else { return false }
        return gamingWatcher.wrappedIsSatisfied
    }

    var accessibilityTrusted = false

    @ObservationIgnored private var accessibilityPoll: Task<Void, Never>?

    func refreshAccessibilityTrust() {
        accessibilityTrusted = AccessibilityTrust.isTrusted
    }

    func requestAccessibilityForActivityIfNeeded() {
        accessibilityTrusted = AccessibilityTrust.requestIfNeeded()
        if !accessibilityTrusted {
            pollAccessibilityTrust()
        }
    }

    func openAccessibilitySettings() {
        if let url = AccessibilityTrust.settingsURL {
            NSWorkspace.shared.open(url)
        }
        pollAccessibilityTrust()
    }

    private func pollAccessibilityTrust() {
        accessibilityPoll?.cancel()
        accessibilityPoll = Task { @MainActor [weak self] in
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.refreshAccessibilityTrust()
                if self.accessibilityTrusted { return }
            }
        }
    }

    func updateOptions(_ mutate: (inout SleepPreventionOptions) -> Void) {
        var options = session.options
        mutate(&options)
        session.options = options
        settings.options = options
        persist()
    }


    var defaultMode: SessionMode { settings.defaultMode }

    var mode: SessionMode {
        get { session.isActive ? session.mode : settings.defaultMode }
        set {
            settings.defaultMode = newValue
            if session.isActive { session.start(mode: newValue) }
            persist()
        }
    }


    var triggersEnabled: Bool {
        get { settings.triggersEnabled }
        set {
            settings.triggersEnabled = newValue
            triggersPaused = false
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

    private(set) var triggersPaused = false

    func pauseTriggers(cause: SessionCause = .manual) {
        guard settings.triggersEnabled, !triggersPaused else { return }
        triggersPaused = true
        applyTriggerGate()
        if session.isActive, !session.liveLeases.isEmpty {
            session.handOffToLeases()
            session.reconcile()
        } else {
            session.stop(cause: cause)
        }
    }

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

    @ObservationIgnored private let gate: TriggerGateController

    private func applyTriggerGate() {
        gate.rebuild(
            rules: settings.ruleSet.rules,
            combine: settings.ruleSet.combine,
            enabled: settings.triggersEnabled
        )
        session.triggerGate = (settings.triggersEnabled && !triggersPaused) ? gate.engine : nil
    }

    func ruleStates() -> [RuleState]? {
        gate.ruleStates()
    }

    func triggerSummary() -> String? {
        guard let states = ruleStates(), !states.isEmpty else { return nil }
        func conditions(_ count: Int) -> String {
            L(count == 1 ? "%d condition" : "%d conditions", count)
        }
        if session.isActive {
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

    var reminderAfter: TimeInterval {
        get { settings.reminderAfter ?? Self.defaultReminderAfter }
        set {
            settings.reminderAfter = newValue
            session.reminderAfter = newValue
            persist()
        }
    }

    var reminderRepeats: Bool {
        get { settings.reminderRepeats }
        set {
            settings.reminderRepeats = newValue
            session.reminderRepeats = newValue
            persist()
        }
    }

    var reminderSound: Bool {
        get { settings.reminderSound }
        set {
            settings.reminderSound = newValue
            session.reminderSound = newValue
            persist()
        }
    }

    var notifyOnEnd: Bool {
        get { settings.notifyOnEnd }
        set {
            settings.notifyOnEnd = newValue
            session.notifyOnEnd = newValue
            if newValue { notifier.requestAuthorization() }
            persist()
        }
    }

    var endAction: SessionEndAction {
        get { settings.endAction }
        set {
            settings.endAction = newValue
            session.endAction = newValue
            persist()
        }
    }

    var eventHooks: [EventHook] {
        get { settings.eventHooks }
        set {
            settings.eventHooks = newValue
            hookDispatcher.hooks = newValue
            persist()
        }
    }

    var hooksEditing: Bool {
        get { hookDispatcher.isSuspended }
        set { hookDispatcher.isSuspended = newValue }
    }

    func fireAgentIdleHookIfNeeded() {
        if gate.agentJustWentIdle() {
            hookDispatcher.fire(.agentWentIdle)
        }
    }


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

    var wakeSchedule: WakeScheduleConfig? {
        get { settings.wakeSchedule }
        set {
            if newValue != nil, !canEditWakeSchedule { return }
            settings.wakeSchedule = newValue
            persist()
            applyWakeScheduleToSystem()
        }
    }


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

    var syncedAutomations: [ScheduledAutomation] { automationSyncController.automations }

    var automationsLastChecked: Date? { automationSyncController.lastRefresh }

    var automationNextWakeTime: Date? { automationNextWake }

    func isAutomationSourceEnabled(_ source: ScheduledAutomation.Source) -> Bool {
        settings.automationSync.enabledSources.contains(source)
    }

    func setAutomationSourceEnabled(_ source: ScheduledAutomation.Source, _ on: Bool) {
        var config = settings.automationSync
        if on { config.enabledSources.insert(source) } else { config.enabledSources.remove(source) }
        automationSyncConfig = config
    }

    func isAutomationMuted(_ id: String) -> Bool { settings.automationSync.mutedIDs.contains(id) }

    func setAutomationMuted(_ id: String, _ muted: Bool) {
        var config = settings.automationSync
        if muted { config.mutedIDs.insert(id) } else { config.mutedIDs.remove(id) }
        automationSyncConfig = config
    }

    func refreshSyncedAutomations() {
        automationSyncController.refresh()
        armAutomationWakesIfChanged()
    }

    func automationSyncTick() {
        guard settings.automationSync.enabled else {
            if automationNextWake != nil {
                automationNextWake = nil
                applyWakeScheduleToSystem()
            }
            return
        }
        let now = Date()
        if let last = lastAutomationRefreshAt, now.timeIntervalSince(last) < 60 { return }
        lastAutomationRefreshAt = now
        refreshAndArmAutomationWakes()
    }

    func refreshAndArmAutomationWakes() {
        automationSyncController.refresh()
        armAutomationWakesIfChanged()
    }

    /// Discover automations and compute the next wake WITHOUT applying, so the
    /// launch path can apply the full effective schedule (manual + automation)
    /// in one step. Without this, launch applies before discovery has run and a
    /// wake persisted from a previous run (pmset survives reboots) is cancelled,
    /// then only re-armed a tick later.
    func primeAutomationDiscovery() {
        automationSyncController.refresh()
        let config = settings.automationSync
        automationNextWake = config.enabled
            ? AutomationSync.nextWake(automationSyncController.automations, config: config, after: Date())
            : nil
    }

    private func armAutomationWakesIfChanged() {
        let config = settings.automationSync
        automationNextWake = config.enabled
            ? AutomationSync.nextWake(automationSyncController.automations, config: config, after: Date())
            : nil
        guard effectiveWakeConfig().oneShot != lastArmedEffectiveOneShot else { return }
        applyWakeScheduleToSystem()
    }

    private func handleAutomationWake() -> Bool {
        let config = settings.automationSync
        guard config.enabled else { return false }
        automationSyncController.refresh()
        guard let match = AutomationSync.wakeMatch(
            automationSyncController.automations, config: config, wokeAt: Date()) else { return false }
        let now = Date()
        if let last = lastAutomationHoldAt, now.timeIntervalSince(last) < 60 { return true }
        lastAutomationHoldAt = now
        if !triggersEnabled, !session.isActive {
            session.start(mode: .timed(duration: config.holdSeconds), cause: .command)
            notifier.notify(
                title: L("Awake for a scheduled run"),
                body: L("Keeping this Mac awake for \u{201C}%@\u{201D} to run.", match.automationName),
                sound: false
            )
        }
        refreshAndArmAutomationWakes()
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

    private func effectiveWakeConfig() -> WakeScheduleConfig {
        var config = settings.wakeSchedule ?? WakeScheduleConfig()
        config.oneShot = AutomationSync.effectiveOneShot(
            manual: config.oneShot, automationWake: automationNextWake, now: Date())
        return config
    }

    @ObservationIgnored private var wakeApplyTask: Task<Void, Never>?
    @ObservationIgnored private var wakeApplyPending = false

    func applyWakeScheduleToSystem() {
        // A one-shot whose moment has passed can never install again (pmset
        // refuses past dates); drop it so later applies don't fail on it
        // forever.
        if let date = settings.wakeSchedule?.oneShot, date <= Date() {
            settings.wakeSchedule?.oneShot = nil
            persist()
        }
        let config = effectiveWakeConfig()
        lastArmedEffectiveOneShot = config.oneShot
        wakeApplyPending = true
        if wakeApplyTask == nil {
            runWakeApplyLoop()
        }
    }

    private func runWakeApplyLoop() {
        let client = helperClient
        wakeApplyTask = Task.detached { [weak self] in
            while true {
                let shouldContinue = await MainActor.run { [weak self] () -> Bool in
                    guard let self else { return false }
                    if self.wakeApplyPending {
                        self.wakeApplyPending = false
                        return true
                    }
                    self.wakeApplyTask = nil
                    return false
                }
                guard shouldContinue, let self else { return }
                await self.performWakeApply(client: client)
            }
        }
    }

    /// One apply pass, reading the desired config at execution time. The
    /// blocking handshake and XPC call run off the main actor.
    private func performWakeApply(client: PrivilegedHelperCalling) async {
        if let date = settings.wakeSchedule?.oneShot, date <= Date() {
            settings.wakeSchedule?.oneShot = nil
            persist()
        }
        let config = effectiveWakeConfig()
        // Leave pmset alone when there is nothing to install and Keepresso
        // never installed anything: the system schedules belong to the user
        // or another tool, not to us. Checked here, against the same config
        // the pass applies, so enqueue-time and execution-time cannot
        // disagree in either direction.
        guard config.isActive || wakeSchedulesInstalledByKeepresso else { return }
        // A pre-update daemon still answering the handshake means "updating",
        // not "missing": no failure notification, re-apply once the new
        // daemon serves.
        let helperUpdating = wakeHelperGate == .helperUpdating
        let reachable: Bool = await Task.detached { client.ping() }.value
        if reachable {
            let parts = config.pmsetArguments
            let ok: Bool = await Task.detached {
                client.applyWakeSchedule(
                    oneShot: parts.oneShot,
                    repeatDays: parts.repeatDays,
                    repeatTime: parts.repeatTime
                )
            }.value
            if config.isActive {
                wakeSchedulesInstalledByKeepresso = true
            } else if ok {
                wakeSchedulesInstalledByKeepresso = false
            }
            lastArmedEffectiveOneShot = config.oneShot
            refreshSystemWakeState()
            if !ok {
                notifier.notify(
                    title: L("Wake schedule not installed"),
                    body: L("The administrator helper could not update the system wake schedule."),
                    sound: false
                )
            }
            return
        }
        refreshSystemWakeState()
        guard config.isActive else { return }
        if helperUpdating {
            reapplyWakeScheduleWhenHelperReady()
        } else {
            notifier.notify(
                title: L("Wake schedule not installed"),
                body: L("Installing a wake schedule needs the administrator helper (Preferences ▸ General)."),
                sound: false
            )
        }
    }

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
                    self.wakeReapplyWatch = nil
                    return
                case .awaitingApproval, .helperUpdating:
                    continue
                }
            }
            self?.wakeReapplyWatch = nil
        }
    }

    func refreshSystemWakeState() {
        systemWakeState = wakeReader.current()
    }

    @ObservationIgnored private var statsHistory: [PersistedSessionEvent] = []

    private func recordForStats(_ event: PersistedSessionEvent) {
        statsHistory.append(event)
        if statsHistory.count > 8192 {
            statsHistory.removeFirst(statsHistory.count - 4096)
        }
        refreshAwakeStats()
    }

    func refreshAwakeStats() {
        awakeStats = AwakeStatsAggregator.summarize(events: statsHistory)
    }

    func handleSystemWake() {
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


    func stopSessionIn(_ interval: TimeInterval) {
        session.stopIn(interval)
    }

    var quickStopDurations: [TimeInterval] {
        get { settings.quickStopDurations }
        set {
            settings.quickStopDurations = KeepressoSettings.normalizedQuickStopDurations(newValue)
            persist()
        }
    }

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

    var endingSoonNotice: TimeInterval {
        get { settings.endingSoonNoticeSeconds ?? Self.defaultEndingSoonNotice }
        set {
            settings.endingSoonNoticeSeconds = newValue
            session.endingSoonNotice = newValue
            persist()
        }
    }


    static let defaultPauseBelowBatteryPercent = 20

    @ObservationIgnored let machineHasBattery = IOKitPowerSourceMonitor().current.hasBattery

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

    var pauseBelowBatteryPercent: Int {
        get { settings.pauseBelowBatteryPercent ?? Self.defaultPauseBelowBatteryPercent }
        set {
            settings.pauseBelowBatteryPercent = newValue
            session.pauseBelowBatteryPercent = newValue
            persist()
        }
    }


    @ObservationIgnored let machineHasFans = (SMCFanInfo().fanCount() ?? 0) > 0

    @ObservationIgnored private(set) lazy var fanFloor = ClosedLidFanFloorController(helper: XPCHelperClient())
    @ObservationIgnored private var fanFloorArming = ThermalArming()
    @ObservationIgnored private var fanFloorCancelInFlight = false
    @ObservationIgnored private var sawFanFloorHelperError = false
    var closedLidMinimumFanPercent: Int? {
        get { settings.closedLidMinimumFanPercent }
        set {
            settings.closedLidMinimumFanPercent = newValue.map(ClosedLidFanFloor.clampedPercent)
            persist()
        }
    }
    private func fanFloorTick() {
        let floorFailed = fanFloor.failed
        if floorFailed, !sawFanFloorHelperError, helperInstalled { verifyHelper() }
        sawFanFloorHelperError = floorFailed
        guard settings.closedLidMinimumFanPercent != nil || fanFloor.requestedPercent != nil || fanFloor.busy else { return }
        let armed = fanFloorArming.update(lidClosed: lidClosedThisTick(), sleepOverrideActive: closedDisplay.isEnabled)
        let supported = machineHasFans && helper.daemonReadyForCurrentFeatures
        if armed, supported, settings.closedLidMinimumFanPercent != nil, fanDryRun.isRunning {
            guard !fanFloorCancelInFlight else { return }
            fanFloorCancelInFlight = true
            Task { [weak self] in
                await self?.fanDryRun.cancelAndWait()
                self?.fanFloorCancelInFlight = false
            }
            return
        }
        fanFloor.tick(percent: settings.closedLidMinimumFanPercent, armed: armed, supported: supported)
    }

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

    private func effectiveThermalConfig(_ config: ThermalSafetyConfig?) -> ThermalSafetyConfig? {
        guard var config else { return nil }
        if config.fanBoostPercent != nil,
           !(machineHasFans && helperInstalled && !helper.daemonOutdated) {
            config.fanBoostPercent = nil
        }
        return config
    }

    func thermalAvailabilityTick() {
        thermalGuard.config = effectiveThermalConfig(settings.thermalSafety)
        if settings.thermalSafety?.fanBoostPercent != nil || settings.closedLidMinimumFanPercent != nil,
           helperInstalled, helper.daemonOutdated {
            helper.watchDaemonUpdate()
        }
        fanHoldWatchTick()
        fanFloorTick()
    }

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
            self.setFanHold(percent: nil)
            self.notifier.notify(
                title: L("Fan boost ended"),
                body: L("The firmware kept refusing manual fan control, so the fans are back with the system. The rest of the thermal safety net still applies."),
                sound: false
            )
        }
    }

    @ObservationIgnored private var thermalLiftedClosedDisplay = false

    @ObservationIgnored private var batteryLiftedClosedDisplay = false

    @ObservationIgnored private var sawBatteryPaused = false

    private(set) var fanBoostActivePercent: Int?

    func handleThermalEffects(_ effects: [ThermalEffect]) {
        if !effects.isEmpty {
            hookDispatcher.fire(.thermalStageChanged)
        }
        for effect in effects {
            switch effect {
            case .boostFans(let percent):
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
                    Task { [weak self] in
                        await self?.fanDryRun.cancelAndWait()
                        guard let self, self.thermalGuard.state.stage != .clear else { return }
                        self.setFanHold(percent: percent)
                    }
                } else {
                    setFanHold(percent: percent)
                }
            case .restoreFans:
                setFanHold(percent: nil)
            case .pauseBrewing:
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
                    if session.pausedByBattery {
                        batteryLiftedClosedDisplay = true
                    } else if helperInstalled {
                        setClosedDisplay(true, userInitiated: false)
                    }
                }
            }
        }
    }

    private func setFanHold(percent: Int?) {
        fanBoostActivePercent = percent
        let client = helperClient
        Task.detached { [weak self] in
            let ok = client.setFanHold(percent != nil, percent: percent ?? 0)
            guard !ok, percent != nil else { return }
            await MainActor.run { [weak self] in
                guard let self, self.fanBoostActivePercent == percent else { return }
                self.fanBoostActivePercent = nil
                self.notifier.notify(
                    title: L("Fans not boosted"),
                    body: L("The administrator helper didn't accept the fan boost. The rest of the thermal safety net still applies."),
                    sound: false
                )
            }
        }
    }


    @ObservationIgnored private(set) lazy var fanDryRun = FanDryRunController(
        helper: helperClient,
        fans: SMCFanInfo(),
        readCelsius: { [thermalGuard] in
            let ids = thermalGuard.discoverSensors().map(\.id)
            return thermalGuard.liveReadings(ids: ids).values.max()
        }
    )

    enum FanTestGate: Equatable {
        case ready
        case needsHelper
        case awaitingApproval
        case helperUpdating
        case boostActive
    }

    var fanTestGate: FanTestGate {
        if helper.awaitingApproval { return .awaitingApproval }
        if !helperInstalled { return .needsHelper }
        if helper.daemonOutdated { return .helperUpdating }
        if fanBoostActivePercent != nil || fanFloor.requestedPercent != nil || fanFloor.busy { return .boostActive }
        return .ready
    }

    var canRunFanDryRun: Bool { fanTestGate == .ready }


    @ObservationIgnored private let hotKeyManager = GlobalHotKeyManager()

    var hotKey: HotKeyShortcut? {
        get { settings.hotKey }
        set {
            settings.hotKey = KeepressoSettings.sanitizedHotKey(newValue)
            persist()
            registerHotKey()
        }
    }

    func registerHotKey() {
        let ok = hotKeyManager.update(to: settings.hotKey) { [weak self] in self?.toggleManual() }
        if !ok {
            NSLog("Keepresso: global shortcut refused, kept the previous one")
        }
    }

    func suspendHotKeyForKeyboardLock() {
        hotKeyManager.update(to: nil) { }
    }

    func resumeHotKeyAfterKeyboardLock() {
        registerHotKey()
    }

    func showKeyboardLockOverlay() {
        keyboardLockOverlay?.close()
        let overlay = KeyboardLockOverlay(controller: keyboardLock) { [weak self] in
            Task { await self?.unlockKeyboardFromOverlay() }
        }
        overlay.show()
        keyboardLockOverlay = overlay
    }

    func unlockKeyboardFromOverlay() async {
        await keyboardLock.unlock()
        guard !keyboardLock.isLocked else { return }
        dismissKeyboardLockOverlay()
        resumeHotKeyAfterKeyboardLock()
    }

    func dismissKeyboardLockOverlay() {
        keyboardLockOverlay?.close()
        keyboardLockOverlay = nil
    }


    var startOnLaunch: Bool {
        get { settings.startOnLaunch }
        set { settings.startOnLaunch = newValue; persist() }
    }

    func startOnLaunchIfNeeded() {
        guard settings.startOnLaunch, !settings.triggersEnabled, !session.isActive else { return }
        session.start(mode: settings.defaultMode)
    }


    var hasOnboarded: Bool {
        get { settings.hasOnboarded }
        set { settings.hasOnboarded = newValue; persist() }
    }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestNotificationAuthorization() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await center.notificationSettings().authorizationStatus
    }


    var showCountdownInMenuBar: Bool {
        get { settings.showCountdownInMenuBar }
        set {
            settings.showCountdownInMenuBar = newValue
            persist()
        }
    }

    var menuPanelExpanded: Bool {
        get { settings.menuPanelExpanded }
        set {
            settings.menuPanelExpanded = newValue
            persist()
        }
    }

    var menuCustomizationEnabled: Bool {
        get { settings.menuCustomizationEnabled }
        set {
            settings.menuCustomizationEnabled = newValue
            persist()
        }
    }

    var advancedMenuLayout: MenuLayout? {
        settings.customizedMenuLayout
    }

    var editableMenuLayout: MenuLayout {
        settings.menuLayout ?? MenuLayout()
    }

    func updateMenuLayout(_ update: (inout MenuLayout) -> Void) {
        var layout = editableMenuLayout
        update(&layout)
        settings.setMenuLayout(layout)
        persist()
    }

    var glassClarity: Int {
        get { settings.glassClarity }
        set {
            settings.glassClarity = newValue
            GlassClarity.shared.value = Double(settings.glassClarity) / 100
            persist()
        }
    }


    var presets: [Preset] { settings.presets }

    func applyPreset(_ preset: Preset) {
        settings.ruleSet = preset.ruleSet
        if settings.triggersEnabled {
            triggersPaused = false
            applyTriggerGate()
            persist()
        } else {
            triggersEnabled = true
        }
    }

    func saveCurrentRulesAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.presets.append(Preset(name: trimmed, ruleSet: settings.ruleSet))
        persist()
    }

    func removePreset(_ preset: Preset) {
        settings.presets.removeAll { $0.id == preset.id }
        persist()
    }

    var missingBuiltInPresets: [Preset] { settings.missingBuiltInPresets }

    func restoreDefaultPresets() {
        settings.restoreMissingBuiltInPresets()
        persist()
    }


    func exportSettingsData() throws -> Data {
        try SettingsTransfer.exportData(settings, appVersion: AppInfo.version)
    }

    @discardableResult
    func importSettings(from data: Data) throws -> Int {
        let (disarmed, disabledShellHooks) =
            try SettingsTransfer.importSettings(from: data).disarmingImportedShellHooks()
        var imported = disarmed
        imported.seedNewBuiltInPresets()
        imported.refreshBuiltInPresets()
        apply(imported)
        return disabledShellHooks
    }

    private func apply(_ newSettings: KeepressoSettings) {
        session.stop()
        revokeLeases()
        settings = newSettings
        hotspot.config = newSettings.hotspotFallback
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
        thermalGuard.config = effectiveThermalConfig(newSettings.thermalSafety)
        GlassClarity.shared.value = Double(newSettings.glassClarity) / 100
        disk.config = newSettings.diskKeepAlive
        virtualDisplay.config = newSettings.virtualDisplay
        awdl.autoWithGaming = newSettings.awdlAutoWithGaming
        gamingWatcher.grace = newSettings.awdlGraceSeconds
        closedDisplayAuto.onlyWhileBrewing = newSettings.closedDisplayOnlyWhileBrewing
        closedDisplay.policy = newSettings.closedLidDisplayPolicy
        session.closedLidDisplayPolicy = newSettings.closedLidDisplayPolicy
        controllerPoker.enabled = newSettings.controllerPokeWhileGaming
        gamePriority.autoWithGaming = newSettings.gamePriorityBoost
        if !newSettings.closedDisplayOnlyWhileBrewing {
            Task { await closedDisplayAuto.stopIfHolding() }
        }
        triggersPaused = false
        applyTriggerGate()
        if newSettings.pauseBelowBatteryPercent != nil
            || newSettings.thermalSafety?.stopBrewing == true
            || newSettings.reminderAfter != nil
            || newSettings.notifyOnEnd
            || newSettings.endingSoonNoticeSeconds != nil
            || newSettings.closedDisplayOnlyWhileBrewing
            || newSettings.awdlAutoWithGaming
            || (newSettings.hotspotFallback.enabled && newSettings.hotspotFallback.notifyOnConnect) {
            notifier.requestAuthorization()
        }
        registerHotKey()
        persist()
    }


    @ObservationIgnored private let widgetSync = WidgetStateSync()

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

    func applyPendingWidgetCommand() {
        guard let command = widgetSync.consumeCommand() else { return }
        switch command {
        case .start:
            if !session.isActive { handle(.start(mode: settings.defaultMode)) }
        case .stop:
            if session.isActive { handle(.stop) }
        case .pauseTriggers:
            pauseTriggers(cause: .command)
        case .resumeTriggers:
            resumeTriggers()
        }
        syncWidgetState()
    }


    @ObservationIgnored private let leaseEngine = LeaseEngine()

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

    private func revokeLeases() {
        leaseEngine.revokeAll(now: Date())
    }

    func endAutomationLeases() {
        revokeLeases()
        if session.isLeaseHeld {
            session.stop()
        } else {
            session.reconcile()
        }
        syncWidgetState()
    }


    private var agentSkillURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/AgentSkill/keep-awake", isDirectory: true)
    }

    private var mcpServerPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/keepresso-mcp").path
    }

    func copyAgentInstructions() {
        let skillPath = agentSkillURL.appendingPathComponent("SKILL.md").path
        let text = "Install SKILL.md from \(skillPath) globally"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

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

    func revealAgentSkill() {
        NSWorkspace.shared.activateFileViewerSelecting([agentSkillURL])
    }

    func copyAutomationRunInstructions() {
        let text = """
        Keep this Mac awake for the entire run using Keepresso. Use the \
        "keep-awake" skill if you have it, or Keepresso's MCP tools \
        (acquire_lease, heartbeat_lease, release_lease). Acquire one lease when \
        the run starts, with a UUID you generate once; send a heartbeat before \
        half its TTL elapses; and release it in your cleanup path when you \
        finish, even on error. If Keepresso reports that automation leases are \
        disabled, tell me and continue without one.
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }


    var automationWakeControlEnabled: Bool {
        get { settings.automationWakeControlEnabled }
        set {
            settings.automationWakeControlEnabled = newValue
            persist()
        }
    }

    @ObservationIgnored private var lastWakeRequestId: String?
    @ObservationIgnored private var lastWakeRequestOutcome: String?

    private func processAutomationWakeRequest() {
        guard let request = AutomationWakeRequestFile.read() else { return }
        guard AutomationWakeRequestFile.claim(requestId: request.requestId) else { return }
        let outcome: AutomationWakeOutcome
        if !settings.automationWakeControlEnabled {
            outcome = .disabled
        } else {
            switch AutomationWakeControl.adjudicate(request, now: Date()) {
            case .invalid:
                outcome = .invalid
            case .apply(nil):
                wakeSchedule = nil
                outcome = .applied
            case .apply(let config?):
                if canEditWakeSchedule {
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


    func handle(_ command: URLCommand) {
        if command == .syncLeases {
            processAutomationWakeRequest()
            leaseEngine.invalidateStoreCache()
            session.reconcile()
            widgetSync.forceNextWrite()
            syncWidgetState()
            return
        }
        let wasActive = session.isActive
        pauseTriggers(cause: .command)
        switch command {
        case .start(let mode):
            session.start(mode: mode, cause: .command)
        case .stop:
            revokeLeases()
            session.stop(cause: .command)
        case .toggle:
            if wasActive {
                revokeLeases()
                session.stop(cause: .command)
            } else {
                session.start(mode: settings.defaultMode, cause: .command)
            }
        case .syncLeases:
            break
        }
    }


    var diskKeepAliveEnabled: Bool { settings.diskKeepAlive != nil }

    var diskKeepAliveDirectory: URL? { settings.diskKeepAlive?.directory }

    var diskKeepAliveInterval: TimeInterval {
        get { settings.diskKeepAlive?.interval ?? DiskKeepAliveConfig.defaultInterval }
        set {
            guard var config = settings.diskKeepAlive else { return }
            config.interval = newValue
            setDiskConfig(config)
        }
    }

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

    func disableDiskKeepAlive() { setDiskConfig(nil) }

    private func setDiskConfig(_ config: DiskKeepAliveConfig?) {
        settings.diskKeepAlive = config
        disk.config = config
        persist()
    }

    private func persist() { store.save(settings) }


    /// Re-read the system sleep setting that backs the closed-display toggle.
    /// Non-blocking: the underlying `pmset` read runs off the main thread.
    /// Re-read `pmset disablesleep`. Menu open uses the cached value when it
    /// is fresher than ``ClosedDisplayController/refreshFreshness``; pass
    /// `force: true` for launch and correctness-critical enforcement paths.
    func refreshClosedDisplay(force: Bool = false) {
        Task { await closedDisplay.refresh(force: force) }
    }


    private(set) var claudeHooks: AgentHooks.HookInstallState = .notInstalled

    private(set) var claudeHooksError: String?

    private(set) var claudeCodePresent = false

    func refreshClaudeHooksStatus() {
        claudeCodePresent = AgentTool.claudeCode.isPresent()
        do {
            claudeHooks = AgentHooks.hookInstallState(
                of: try AgentHooks.readSettings(at: AgentHooks.claudeSettingsURL()),
                cliPath: Self.bundledCLIPath, format: Self.claudeHookFormat())
            autoRepairIfNeeded(.claudeCode)
        } catch {
            claudeHooks = .unreadable
        }
    }

    func installClaudeHooks() {
        let format = Self.claudeHookFormat()
        mutateClaudeSettings { existing in
            try AgentHooks.installHooks(into: existing, cliPath: Self.bundledCLIPath, format: format)
        }
    }

    private static func claudeHookFormat() -> AgentHooks.SettingsFormat {
        let versions = ClaudeCodeVersions.detect(
            home: FileManager.default.homeDirectoryForCurrentUser.path)
        return .claude(includingStopFailure: versions.supportsStopFailure)
    }

    func removeClaudeHooks() {
        if mutateClaudeSettings({ try AgentHooks.removeHooks(from: $0) }) {
            AgentHooks.purgeRecords(where: AgentHooks.shouldPurgeOnClaudeUninstall)
        }
    }


    private(set) var cursorHooks: AgentHooks.HookInstallState = .notInstalled

    private(set) var cursorHooksError: String?

    private(set) var cursorPresent = false

    func refreshCursorHooksStatus() {
        cursorPresent = AgentTool.cursor.isPresent()
        do {
            cursorHooks = CursorHooks.hookInstallState(
                of: try AgentHooks.readSettings(at: CursorHooks.hooksURL()),
                cliPath: Self.bundledCLIPath)
            autoRepairIfNeeded(.cursor)
        } catch {
            cursorHooks = .unreadable
        }
    }

    func installCursorHooks() {
        mutateCursorHooks { existing in
            try CursorHooks.installHooks(into: existing, cliPath: Self.bundledCLIPath)
        }
    }

    func removeCursorHooks() {
        if mutateCursorHooks({ try CursorHooks.removeHooks(from: $0) }) {
            AgentHooks.purgeRecords(where: CursorHooks.ownsRecord)
        }
    }


    private(set) var antigravityHooks: AgentHooks.HookInstallState = .notInstalled

    private(set) var antigravityHooksError: String?

    private(set) var antigravityPresent = false

    func refreshAntigravityHooksStatus() {
        antigravityPresent = AgentTool.antigravity.isPresent()
        do {
            antigravityHooks = AntigravityHooks.hookInstallState(
                of: try AgentHooks.readSettings(at: AntigravityHooks.hooksURL()),
                cliPath: Self.bundledCLIPath)
            autoRepairIfNeeded(.antigravity)
        } catch {
            antigravityHooks = .unreadable
        }
    }

    func installAntigravityHooks() {
        mutateAntigravityHooks { existing in
            try AntigravityHooks.installHooks(into: existing, cliPath: Self.bundledCLIPath)
        }
    }

    func removeAntigravityHooks() {
        if mutateAntigravityHooks({ try AntigravityHooks.removeHooks(from: $0) }) {
            AgentHooks.purgeRecords(where: AntigravityHooks.ownsRecord)
        }
    }

    @discardableResult
    private func mutateAntigravityHooks(_ transform: (Data?) throws -> Data) -> Bool {
        let url = AntigravityHooks.hooksURL()
        defer { refreshAntigravityHooksStatus() }
        do {
            try Self.updateConfigFile(at: url, transform)
            antigravityHooksError = nil
            return true
        } catch is AgentHooks.SettingsUnreadableError {
            antigravityHooksError = nil
            return false
        } catch {
            antigravityHooksError = L("Couldn't update Antigravity's hooks file.")
            return false
        }
    }


    private(set) var ompHooks: AgentHooks.HookInstallState = .notInstalled
    private(set) var ompHooksError: String?
    private(set) var ompPresent = false

    func refreshOMPHooksStatus() {
        ompPresent = AgentTool.omp.isPresent()
        ompHooks = OMPHooks.installState(cliPath: Self.bundledCLIPath)
        autoRepairIfNeeded(.omp)
    }

    func installOMPExtension() {
        defer { refreshOMPHooksStatus() }
        do {
            try OMPHooks.install(cliPath: Self.bundledCLIPath)
            ompHooksError = nil
        } catch {
            ompHooksError = Self.ompExtensionError(error)
        }
    }

    func removeOMPExtension() {
        defer { refreshOMPHooksStatus() }
        do {
            try OMPHooks.remove()
            AgentHooks.purgeRecords(where: OMPHooks.ownsRecord)
            ompHooksError = nil
        } catch {
            ompHooksError = Self.ompExtensionError(error)
        }
    }

    private static func ompExtensionError(_ error: Error) -> String {
        if case OMPHooks.InstallError.extensionAlreadyOwnedByAnotherFile = error {
            return L("Another keepresso-agent-activity.ts is in OMP's extensions folder. Move it, then try again.")
        }
        return L("Couldn't update the OMP extension.")
    }


    var agentSetupTools: [AgentTool] {
        AgentTool.setupTools(present: isAgentToolPresent, connected: { hookState(of: $0) != .notInstalled })
    }

    func isAgentToolPresent(_ tool: AgentTool) -> Bool {
        switch tool {
        case .claudeCode: return claudeCodePresent
        case .cursor: return cursorPresent
        case .codex: return codexPresent
        case .antigravity: return antigravityPresent
        case .grok: return grokPresent
        case .omp: return ompPresent
        case .hermes: return hermesPresent
        case .qwen, .devin, .kimi: return tool.compatTool.map(compatPresent.contains) ?? false
        }
    }

    func hookState(of tool: AgentTool) -> AgentHooks.HookInstallState {
        switch tool {
        case .claudeCode: return claudeHooks
        case .cursor: return cursorHooks
        case .codex: return codexHooks
        case .antigravity: return antigravityHooks
        case .grok: return grokHooks
        case .omp: return ompHooks
        case .hermes: return hermesHooks
        case .qwen, .devin, .kimi: return tool.compatTool.flatMap { compatHooks[$0] } ?? .notInstalled
        }
    }

    func connectAgentTool(_ tool: AgentTool) {
        switch tool {
        case .claudeCode: installClaudeHooks()
        case .cursor: installCursorHooks()
        case .codex: installCodexHooks()
        case .antigravity: installAntigravityHooks()
        case .grok: installGrokHooks()
        case .omp: installOMPExtension()
        case .hermes: installHermesPlugin()
        case .qwen, .devin, .kimi: tool.compatTool.map(installCompatHooks)
        }
    }

    static var runsFromApplicationsFolder: Bool {
        AppRelocator.runsFromApplications
    }

    func refreshAgentHookStatuses() {
        refreshClaudeHooksStatus()
        refreshCursorHooksStatus()
        refreshCodexHooksStatus()
        refreshAntigravityHooksStatus()
        refreshGrokHooksStatus()
        refreshOMPHooksStatus()
        refreshHermesPluginStatus()
        refreshCompatHooksStatus()
    }

    private var repairedThisRun: Set<AgentTool> = []

    private func autoRepairIfNeeded(_ tool: AgentTool) {
        guard Self.runsFromApplicationsFolder else { return }
        guard case .needsRepair = hookState(of: tool) else { return }
        guard repairedThisRun.insert(tool).inserted else { return }
        connectAgentTool(tool)
    }


    private(set) var codexHooks: AgentHooks.HookInstallState = .notInstalled
    private(set) var codexHooksError: String?
    private(set) var codexPresent = false

    func refreshCodexHooksStatus() {
        codexPresent = AgentTool.codex.isPresent()
        do {
            codexHooks = CodexHooks.hookInstallState(
                of: try AgentHooks.readSettings(at: CodexHooks.hooksURL()),
                cliPath: Self.bundledCLIPath)
            autoRepairIfNeeded(.codex)
        } catch {
            codexHooks = .unreadable
        }
    }

    func installCodexHooks() {
        mutateCodexHooks { existing in
            try CodexHooks.installHooks(into: existing, cliPath: Self.bundledCLIPath)
        }
    }

    func removeCodexHooks() {
        if mutateCodexHooks({ try CodexHooks.removeHooks(from: $0) }) {
            AgentHooks.purgeRecords(where: CodexHooks.ownsRecord)
        }
    }

    @discardableResult
    private func mutateCodexHooks(_ transform: (Data?) throws -> Data) -> Bool {
        let url = CodexHooks.hooksURL()
        defer { refreshCodexHooksStatus() }
        do {
            try Self.updateConfigFile(at: url, transform)
            codexHooksError = nil
            return true
        } catch is AgentHooks.SettingsUnreadableError {
            codexHooksError = nil
            return false
        } catch {
            codexHooksError = L("Couldn't update Codex's hooks file.")
            return false
        }
    }


    private(set) var grokHooks: AgentHooks.HookInstallState = .notInstalled
    private(set) var grokHooksError: String?
    private(set) var grokPresent = false

    func refreshGrokHooksStatus() {
        grokPresent = AgentTool.grok.isPresent()
        do {
            grokHooks = GrokHooks.hookInstallState(
                of: try AgentHooks.readSettings(at: GrokHooks.hooksURL()),
                cliPath: Self.bundledCLIPath)
            autoRepairIfNeeded(.grok)
        } catch {
            grokHooks = .unreadable
        }
    }

    func installGrokHooks() {
        mutateGrokHooks { existing in
            try GrokHooks.installHooks(into: existing, cliPath: Self.bundledCLIPath)
        }
    }

    func removeGrokHooks() {
        let url = GrokHooks.hooksURL()
        defer { refreshGrokHooksStatus() }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url.resolvingSymlinksInPath())
            }
            grokHooksError = nil
            AgentHooks.purgeRecords(where: GrokHooks.ownsRecord)
        } catch {
            grokHooksError = L("Couldn't update Grok's hooks file.")
        }
    }

    @discardableResult
    private func mutateGrokHooks(_ transform: (Data?) throws -> Data) -> Bool {
        let url = GrokHooks.hooksURL()
        defer { refreshGrokHooksStatus() }
        do {
            try Self.updateConfigFile(at: url, transform)
            grokHooksError = nil
            return true
        } catch is AgentHooks.SettingsUnreadableError {
            grokHooksError = nil
            return false
        } catch {
            grokHooksError = L("Couldn't update Grok's hooks file.")
            return false
        }
    }


    private(set) var compatHooks: [CompatHooks.Tool: AgentHooks.HookInstallState] = [:]
    private(set) var compatHooksErrors: [CompatHooks.Tool: String] = [:]
    private(set) var compatPresent: Set<CompatHooks.Tool> = []

    func refreshCompatHooksStatus() {
        for tool in CompatHooks.Tool.allCases {
            let agentTool = tool.agentTool
            if agentTool.isPresent() { compatPresent.insert(tool) } else { compatPresent.remove(tool) }
            do {
                let data = try AgentHooks.readSettings(at: tool.configURL())
                compatHooks[tool] = tool == .kimi
                    ? KimiHooksFile.hookInstallState(of: data, cliPath: Self.bundledCLIPath)
                    : AgentHooks.hookInstallState(
                        of: data, cliPath: Self.bundledCLIPath, format: tool.settingsFormat)
                autoRepairIfNeeded(agentTool)
            } catch {
                compatHooks[tool] = .unreadable
            }
        }
    }

    func installCompatHooks(_ tool: CompatHooks.Tool) {
        mutateCompatHooks(tool) { existing in
            tool == .kimi
                ? try KimiHooksFile.installHooks(into: existing, cliPath: Self.bundledCLIPath)
                : try AgentHooks.installHooks(
                    into: existing, cliPath: Self.bundledCLIPath, format: tool.settingsFormat)
        }
    }

    func removeCompatHooks(_ tool: CompatHooks.Tool) {
        let removed = mutateCompatHooks(tool) { existing in
            tool == .kimi
                ? try KimiHooksFile.removeHooks(from: existing)
                : try AgentHooks.removeHooks(from: existing, format: tool.settingsFormat)
        }
        if removed { AgentHooks.purgeRecords(where: tool.ownsRecord) }
    }

    @discardableResult
    private func mutateCompatHooks(
        _ tool: CompatHooks.Tool, _ transform: (Data?) throws -> Data
    ) -> Bool {
        let url = tool.configURL()
        defer { refreshCompatHooksStatus() }
        do {
            try Self.updateConfigFile(at: url, transform)
            compatHooksErrors[tool] = nil
            return true
        } catch is AgentHooks.SettingsUnreadableError {
            compatHooksErrors[tool] = nil
            return false
        } catch {
            compatHooksErrors[tool] = L("Couldn't update %@'s hooks.", tool.agentTool.displayName)
            return false
        }
    }


    private(set) var hermesHooks: AgentHooks.HookInstallState = .notInstalled
    private(set) var hermesHooksError: String?
    private(set) var hermesPresent = false
    @ObservationIgnored private var hermesCLIRunning = false

    func refreshHermesPluginStatus() {
        hermesPresent = AgentTool.hermes.isPresent()
        let directory = HermesHooks.pluginDirectoryURL()
        var files: [String: Data?] = [:]
        for name in HermesHooks.pluginFiles(cliPath: Self.bundledCLIPath).keys {
            files[name] = try? Data(contentsOf: directory.appendingPathComponent(name))
        }
        let config = (try? Data(contentsOf: HermesHooks.configURL()))
            .map { String(decoding: $0, as: UTF8.self) }
        hermesHooks = HermesHooks.installState(
            files: files,
            enabled: HermesHooks.isEnabled(inConfig: config),
            cliPath: Self.bundledCLIPath)
        if !hermesCLIRunning { autoRepairIfNeeded(.hermes) }
    }

    /// Write the plugin, then let Hermes enable it: its own CLI owns the
    /// YAML edit, and `--no-allow-tool-override` keeps the command from
    /// prompting (the plugin replaces no tools). The CLI is Python and takes
    /// a second or two to start, so it runs off the main thread.
    func installHermesPlugin() {
        guard !hermesCLIRunning else { return }
        let directory = HermesHooks.pluginDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, contents) in HermesHooks.pluginFiles(cliPath: Self.bundledCLIPath) {
                try Data(contents.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        } catch {
            hermesHooksError = L("Couldn't update the Hermes plugin.")
            refreshHermesPluginStatus()
            return
        }
        hermesHooksError = nil
        refreshHermesPluginStatus()
        guard !HermesHooks.isEnabled(inConfig: (try? Data(contentsOf: HermesHooks.configURL()))
            .map { String(decoding: $0, as: UTF8.self) }) else { return }
        runHermesCLI(["plugins", "enable", HermesHooks.pluginName, "--no-allow-tool-override"])
    }

    func removeHermesPlugin() {
        let finish = { [weak self] in
            guard let self else { return }
            let directory = HermesHooks.pluginDirectoryURL()
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                AgentHooks.purgeRecords(where: HermesHooks.ownsRecord)
                self.hermesHooksError = nil
            } catch {
                self.hermesHooksError = L("Couldn't update the Hermes plugin.")
            }
            self.refreshHermesPluginStatus()
        }
        guard HermesHooks.hermesCommand() != nil else { return finish() }
        runHermesCLI(["plugins", "disable", HermesHooks.pluginName], then: finish)
    }

    private func runHermesCLI(_ arguments: [String], then completion: (@MainActor () -> Void)? = nil) {
        guard let command = HermesHooks.hermesCommand() else {
            hermesHooksError = L("Couldn't update the Hermes plugin.")
            return
        }
        hermesCLIRunning = true
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst()) + arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let succeeded = (try? process.run()) != nil && {
                process.waitUntilExit()
                return process.terminationStatus == 0
            }()
            await MainActor.run {
                self.hermesCLIRunning = false
                self.hermesHooksError = succeeded ? nil : L("Couldn't update the Hermes plugin.")
                if let completion { completion() } else { self.refreshHermesPluginStatus() }
            }
        }
    }

    @discardableResult
    private func mutateCursorHooks(_ transform: (Data?) throws -> Data) -> Bool {
        let url = CursorHooks.hooksURL()
        defer { refreshCursorHooksStatus() }
        do {
            try Self.updateConfigFile(at: url, transform)
            cursorHooksError = nil
            return true
        } catch is AgentHooks.SettingsUnreadableError {
            cursorHooksError = nil
            return false
        } catch {
            cursorHooksError = L("Couldn't update Cursor's hooks file.")
            return false
        }
    }

    /// The bundled CLI's absolute path, baked into the installed hook
    /// command so it works regardless of PATH (DMG installs put nothing on
    /// PATH, and hook shells may run with launchd's minimal one).
    private static var bundledCLIPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/keepresso").path
    }

    private static func writePreservingPermissions(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let previous = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        try data.write(to: url, options: .atomic)
        if let previous {
            try? manager.setAttributes([.posixPermissions: previous], ofItemAtPath: url.path)
        }
    }

    private static func updateConfigFile(
        at url: URL, _ transform: (Data?) throws -> Data
    ) throws {
        try ConfigFileUpdate.apply(
            read: { try AgentHooks.readSettings(at: url) },
            write: { data in
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writePreservingPermissions(data, to: url.resolvingSymlinksInPath())
            },
            transform: transform)
    }

    @discardableResult
    private func mutateClaudeSettings(_ transform: (Data?) throws -> Data) -> Bool {
        let url = AgentHooks.claudeSettingsURL()
        defer { refreshClaudeHooksStatus() }
        do {
            try Self.updateConfigFile(at: url, transform)
            claudeHooksError = nil
            return true
        } catch is AgentHooks.SettingsUnreadableError {
            claudeHooksError = nil
            return false
        } catch {
            claudeHooksError = L("Couldn't update Claude Code's settings file.")
            return false
        }
    }


    var helperInstalled: Bool { helper.isInstalled }

    func installHelper() {
        guard !helperOperationInFlight else { return }
        helperRecoveryFailed = false; helperApprovalRequired = false
        helperAttention = nil
        helper.install()
        verifyHelper()
    }

    func removeHelper() {
        guard beginHelperOperation() else { return }
        Task {
            defer { helperOperationInFlight = false }
            await releaseHelperHolds()
            await helper.uninstall()
        }
    }

    private func releaseHelperHolds() async {
        await fanDryRun.cancelAndWait()
        await fanFloor.stopAndWait()
        await closedLidLowPowerController.stopAndWait()
        await closedDisplayAuto.stopIfHolding()
        await awdl.stop()
    }

    private func beginHelperOperation() -> Bool {
        guard !helperOperationInFlight else { return false }
        helperOperationInFlight = true
        helperVerificationGeneration &+= 1
        helper.cancelRecoveryWork()
        approvalRecoveryGeneration &+= 1
        approvalRecoveryWatch?.cancel(); approvalRecoveryWatch = nil
        helperRecoveryPending = false; helperRecoveryFailed = false
        helperApprovalRequired = false; helperAttention = nil
        return true
    }

    enum HelperAttention: Equatable {
        case needsApproval
        case broken
    }

    private(set) var helperAttention: HelperAttention?
    private(set) var helperRecoveryPending = false
    private(set) var helperRecoveryFailed = false
    private(set) var helperOperationInFlight = false
    private var helperApprovalRequired = false
    private var helperVerificationCount = 0
    @ObservationIgnored private var helperVerificationGeneration = 0
    @ObservationIgnored private var approvalRecoveryGeneration = 0

    var helperRecoveryPhase: HelperRecoveryPhase {
        .resolve(installed: helperInstalled,
                 awaitingApproval: helper.awaitingApproval || helperApprovalRequired,
                 checking: helper.isChecking || helper.isWaitingForUpdatedHelper || helperVerificationCount > 0,
                 outdated: helper.daemonOutdated, hasReply: helper.daemonProtocolVersion != nil,
                 recoveryPending: helperRecoveryPending, recoveryExhausted: helperRecoveryFailed,
                 healthCheckCompleted: helper.hasCompletedHealthCheck)
    }
    var helperRecoveryHint: String? {
        switch helperRecoveryPhase {
        case .initializing: return L("Initializing the helper…")
        case .updating: return L("Updating the helper…")
        default: return nil
        }
    }

    /// Watches for the approval landing while the attention window shows the
    /// switch-it-on step. The manager polls `SMAppService.status`, but that
    /// status can sit at `.enabled` the whole time (BTM disabled the daemon
    /// record behind its back), so the flip is only visible to a ping.
    ///
    /// A fresh `.broken` starts quiet: a slow launchd spawn heals on its own
    /// within a minute, and that must never pop a reinstall window. Only a
    /// daemon still dead after the quiet minute escalates to `.broken`, which
    /// opens the window; a recovery before then clears silently.
    @ObservationIgnored private var approvalRecoveryWatch: Task<Void, Never>?
    /// Quiet polls before a dead daemon escalates to a visible `.broken`
    /// (18 × 5s = ninety seconds).
    ///
    /// A minute was tuned for a warm relaunch and is short for a cold start:
    /// straight after a boot or a login, launchd hands the daemon over late
    /// because everything else on the machine is starting at the same time,
    /// and the reinstall window would open on a helper that then came up by
    /// itself seconds later. Waiting longer costs nothing when the helper is
    /// fine (the watch clears silently on recovery) and only delays the
    /// prompt when it truly is broken.
    private static let helperQuietPolls = 18

    private func watchForHelperRecovery() {
        approvalRecoveryWatch?.cancel()
        approvalRecoveryGeneration &+= 1
        let generation = approvalRecoveryGeneration
        helperRecoveryPending = true
        approvalRecoveryWatch = Task { [weak self] in
            defer {
                if self?.approvalRecoveryGeneration == generation {
                    self?.helperRecoveryPending = false
                    self?.approvalRecoveryWatch = nil
                }
            }
            // Keep watching through delayed launchd recovery as well as
            // approval, so a late success does not leave a reinstall prompt.
            var escalated = false
            for i in 0..<60 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if await self.helper.daemonResponds() {
                    await self.verifyHelperAndFollowUp()
                    return
                }
                if self.helperAttention != nil || self.helperApprovalRequired { continue }
                if escalated { return }
                // After an app update the helper can legitimately need a few
                // minutes (the old image idles out while launchd starts the
                // new binary), so hold the quiet phase through the manager's
                // settlement window before offering a reinstall.
                let quietLimit = self.helper.isWaitingForUpdatedHelper ? 36 : Self.helperQuietPolls
                if i >= quietLimit {
                    self.helperRecoveryFailed = true
                    self.helperAttention = .broken
                    escalated = true
                }
            }
        }
    }

    func verifyHelper() {
        guard !helperOperationInFlight else { return }
        let generation = helperVerificationGeneration
        Task {
            guard generation == helperVerificationGeneration else { return }
            await verifyHelperAndFollowUp()
        }
    }

    private func verifyHelperAndFollowUp() async {
        guard !helperOperationInFlight else { return }
        let generation = helperVerificationGeneration
        helperVerificationCount += 1
        defer { helperVerificationCount -= 1 }
        // First clear any previous copy of the app that an update pushed into
        // the Trash: BTM's bookmark keeps resolving the helper's record into
        // the Trash and disabling the daemon while one is there, so a repair
        // before the sweep wouldn't stick.
        await Task.detached { StaleBundleCleaner.sweepNow() }.value
        guard generation == helperVerificationGeneration, !helperOperationInFlight else { return }
        let health = await helper.verifyAndRepairIfNeeded()
        guard generation == helperVerificationGeneration, !helperOperationInFlight else { return }
        switch health {
        case .healthy:
            helperRecoveryFailed = false; helperApprovalRequired = false
            helperAttention = nil
            closedDisplayAuto.retryEngage()
            awdl.retryEngage()
        case .notApplicable:
            helperApprovalRequired = helper.awaitingApproval
            helperAttention = helper.awaitingApproval ? .needsApproval : nil
        case .repaired:
            helperRecoveryFailed = false; helperApprovalRequired = false
            helperAttention = nil
            closedDisplayAuto.retryEngage()
            awdl.retryEngage()
        case .needsApproval:
            helperRecoveryFailed = false; helperApprovalRequired = true
            helperAttention = .needsApproval
            // Also say so in a notification: the attention window can land
            // behind whatever the user is doing at login.
            notifier.notify(
                title: L("Keepresso needs a new approval"),
                body: L("macOS turned Keepresso's background switch off. Turn it back on under Login Items & Extensions in System Settings to keep the password-free helper."),
                sound: true
            )
        case .broken:
            // Provisional: the daemon may just be slow (a launchd spawn after
            // an update or reboot). Watch quietly for a minute and surface the
            // window only if it is still dead then; a recovery before that
            // clears silently without ever bothering the user.
            watchForHelperRecovery()
        }
        if helperAttention != nil { watchForHelperRecovery() }
    }

    func dismissHelperAttention() {
        helperAttention = nil
    }

    func reinstallHelper() {
        guard beginHelperOperation() else { return }
        Task {
            defer { helperOperationInFlight = false }
            // The reinstall lands on a record BTM will invalidate again if an
            // old copy still sits in the Trash; sweep before rebuilding.
            await Task.detached { StaleBundleCleaner.sweepNow() }.value
            await releaseHelperHolds()
            guard await helper.uninstall() else {
                helperRecoveryFailed = true
                helperAttention = .broken
                return
            }
            helper.install()
            guard helperInstalled || helper.awaitingApproval else {
                helperRecoveryFailed = true
                helperAttention = .broken
                return
            }
            fanFloor.resumeAfterHelperReplacement()
            closedLidLowPowerController.resumeAfterHelperReplacement()
            helperOperationInFlight = false
            await verifyHelperAndFollowUp()
        }
    }


    var closedDisplayEnabled: Bool { closedDisplay.isEnabled ?? false }

    var closedDisplayError: String? { closedDisplay.lastError }

    var closedDisplayBusy: Bool { closedDisplay.isBusy }

    /// Turn closed-display mode on or off. Prompts for administrator rights
    /// (it flips the global `pmset disablesleep` setting); the live state is
    /// re-read once the prompt is answered.
    ///
    /// Keepresso is a background agent (`LSUIElement`), so it must become the
    /// active app first or the system password dialog can appear unfocused
    /// behind other windows, leaving the menu in a stuck-looking state. With
    /// the helper installed there is no dialog, so no focus grab either.
    /// After the prompt, the window that owned the toggle is ordered front
    /// again (Welcome, Preferences, …); SecurityAgent otherwise leaves it
    /// buried under every other app.
    func setClosedDisplay(_ on: Bool, userInitiated: Bool = true) {
        if userInitiated {
            thermalLiftedClosedDisplay = false
            batteryLiftedClosedDisplay = false
        }
        // Without the helper the write goes through osascript, which shows the
        // password sheet whoever asked for it. `ClosedDisplayCoordinator`'s
        // foreign-hold clear runs with `userInitiated: false` and still
        // prompts, so gate the dance on the helper, not on the caller. The
        // safety lift/restore paths only call here with the helper installed.
        let needsAuthDance = !helperInstalled
        runAfterPossibleAuthPrompt(needsPrompt: needsAuthDance) {
            _ = await self.closedDisplay.set(on)
            if self.closedDisplay.lastError != nil, self.helperInstalled {
                self.verifyHelper()
            }
        }
    }

    private func waitForSleepWriteToSettle() async {
        for _ in 0..<20 {
            guard closedDisplay.isBusy else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func quitSleepCoverageNow() -> QuitSleepCheck.Coverage {
        // Preview hook: the override variant needs a real persistent
        // `disablesleep` latch, which costs an administrator prompt to set up
        // and leaves the Mac awake afterwards. `KEEPRESSO_QUIT_MODAL` forces
        // a variant so the copy and the art can be checked without any of
        // that. Reads the environment, so it cannot be set on a shipped app
        // by accident.
        if let forced = ProcessInfo.processInfo.environment["KEEPRESSO_QUIT_MODAL"] {
            switch forced {
            case "session": return .session
            case "override": return .overrideLive
            case "both": return .sessionAndOverride
            case "none": return .none
            default: break
            }
        }
        // Read pmset for real, blocking. The cached `isEnabled` is only
        // refreshed at launch and on menu open, so a lid mode switched on
        // since then (or never read at all, leaving it nil) would read as
        // off and the override variant would never show.
        closedDisplay.refreshBlocking()
        return QuitSleepCheck.coverage(
            brewing: session.isActive,
            overrideLive: closedDisplay.isEnabled == true && !closedDisplayAuto.isHolding)
    }

    func quitScopedLidMode() -> Bool {
        closedDisplay.isEnabled == true && closedDisplayAuto.isHolding
    }

    /// Consent-based clear for the quit modal: release the scoped hold, then
    /// clear the persistent override when it is still live.
    ///
    /// Returns whether the override is actually off afterwards, confirmed by
    /// re-reading `pmset` rather than trusting the exit status. The caller
    /// must not quit on `false`: quitting then would strand the very setting
    /// the user pressed "Turn off and quit" to clear.
    @discardableResult
    func clearSleepOverrideForQuit() async -> Bool {
        await closedDisplayAuto.stopIfHolding()
        await waitForSleepWriteToSettle()
        await closedDisplay.refresh(force: true)
        guard closedDisplay.isEnabled == true else { return true }
        if !helperInstalled {
            // Clearing without the helper needs an osascript password sheet.
            // Never spring one unannounced: the dialog names "osascript", not
            // Keepresso, so say what it is for first, and activate so it comes
            // up in front instead of behind everything.
            NSApp.activate(ignoringOtherApps: true)
            notifier.notify(
                title: L("Keepresso needs your password"),
                body: machineHasBattery
                    ? L("Enter your administrator password to switch closed-display mode off before Keepresso quits.")
                    : L("Enter your administrator password to switch the sleep override off before Keepresso quits."),
                sound: true
            )
        }
        let result = await closedDisplay.set(false)
        if case .failed(let message) = result {
            NSLog("Keepresso: quit-time sleep restore failed: %@", message)
        }
        await closedDisplay.refresh(force: true)
        let cleared = closedDisplay.isEnabled != true
        if !cleared {
            // Every unsuccessful outcome says so, not just `.failed`. macOS
            // re-prompts a wrong password itself and then gives osascript the
            // same `-128` it uses for Cancel, so a mistyped password arrives
            // here as `.cancelled`. Staying silent on that is the one case
            // where the user most needs telling: they tried to turn it off,
            // it is still on, and the app did not quit.
            notifier.notify(
                title: L("Closed-display mode left on"),
                body: L("Keepresso could not switch it off, so it stayed running instead of quitting."),
                sound: false
            )
        }
        return cleared
    }

    /// Activate, run privileged work that may show the osascript password
    /// sheet, then put the caller's window back in front.
    ///
    /// LSUIElement apps lose frontmost status when SecurityAgent takes over.
    /// Without the restore, Welcome or Preferences drops behind everything
    /// and people lose the tour mid-setup. No-ops the dance when no prompt
    /// can appear (helper installed, already authorized this run).
    private func runAfterPossibleAuthPrompt(
        needsPrompt: Bool,
        operation: @escaping @MainActor () async -> Void
    ) {
        let window = needsPrompt ? NSApp.keyWindow : nil
        if needsPrompt {
            NSApp.activate(ignoringOtherApps: true)
        }
        Task {
            await operation()
            guard needsPrompt else { return }
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            // Auth sheets can leave an LSUIElement app half-active; same repair
            // used when a window first opens.
            WindowPlacement.repairIfWedged(window, attempts: 3)
        }
    }

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
            closedDisplayCoordinator.rearmForeignHoldClear()
            if newValue && !closedDisplayAuto.isAuthorized && !helperInstalled {
                notifier.requestAuthorization()
                runAfterPossibleAuthPrompt(needsPrompt: true) {
                    await self.closedDisplayAuto.prime()
                    self.refreshThenEnforceClosedDisplay(allowPrompt: true)
                }
            } else if newValue {
                refreshThenEnforceClosedDisplay()
            } else {
                Task {
                    await closedDisplayAuto.stopIfHolding()
                    try? await Task.sleep(for: .seconds(3))
                    await closedDisplay.refresh(force: true)
                }
            }
        }
    }


    var closedLidDisplayPolicy: ClosedLidDisplayPolicy {
        get { settings.closedLidDisplayPolicy }
        set {
            settings.closedLidDisplayPolicy = newValue
            closedDisplay.policy = newValue
            session.closedLidDisplayPolicy = newValue
            persist()
        }
    }

    var displayDarkeningReason: String? { closedDisplay.lastDecisionReason }

    var closedDisplayAutoError: String? { closedDisplayAuto.lastError }

    var closedDisplayAutoBusy: Bool { closedDisplayAuto.isBusy }

    @ObservationIgnored private let closedDisplayCoordinator = ClosedDisplayCoordinator()

    private var closedDisplayConditions: ClosedDisplayCoordinator.Conditions {
        .init(
            onlyWhileBrewing: settings.closedDisplayOnlyWhileBrewing,
            brewing: session.isActive,
            helperInstalled: helperInstalled,
            automationHolding: closedDisplayAuto.isHolding,
            automationAuthorized: closedDisplayAuto.isAuthorized,
            automationFailed: closedDisplayAuto.lastError != nil,
            settingIsOn: closedDisplay.isEnabled,
            settingIsBusy: closedDisplay.isBusy
        )
    }

    private func perform(_ action: ClosedDisplayCoordinator.Action) {
        switch action {
        case .announceEngagePrompt:
            // Without the helper, the first engage of an app run prompts for the
            // password (e.g. auto mode was enabled in a previous run): become the
            // active app so the dialog is focused (same reason as
            // ``setClosedDisplay(_:)``), and say what's happening in a
            // notification, since the dialog itself is easy to miss and names
            // "osascript", not Keepresso.
            NSApp.activate(ignoringOtherApps: true)
            notifier.notify(
                title: L("Keepresso needs your password"),
                body: L("Enter your administrator password to switch closed-display mode on for this session."),
                sound: true
            )
        case .verifyHelper:
            verifyHelper()
        case .runAutoTick(let brewing):
            Task { await closedDisplayAuto.autoTick(brewing: brewing) }
        case .refreshThenEnforce(let delay):
            refreshThenEnforceClosedDisplay(after: delay.map { .seconds($0) })
        case .clearForeignHold(let announce):
            if announce {
                // Never a password dialog out of nowhere: say what it is for
                // first (the dialog itself names "osascript", not Keepresso).
                notifier.notify(
                    title: L("Keepresso needs your password"),
                    body: machineHasBattery
                        ? L("No session is running, so closed-display mode should be off. Enter your administrator password to switch it off.")
                        : L("No session is running, so the sleep override should be off. Enter your administrator password to switch it off."),
                    sound: true
                )
            }
            setClosedDisplay(false, userInitiated: false)
        }
    }

    private func refreshThenEnforceClosedDisplay(
        after delay: Duration? = nil,
        allowPrompt: Bool = false
    ) {
        let token = closedDisplayCoordinator.beginRefresh()
        Task {
            if let delay { try? await Task.sleep(for: delay) }
            guard closedDisplayCoordinator.refreshIsCurrent(token) else { return }
            await closedDisplay.refresh(force: true)
            guard closedDisplayCoordinator.endRefresh(
                token,
                settingIsOn: closedDisplay.isEnabled
            ) else { return }
            if let action = closedDisplayCoordinator.enforce(
                closedDisplayConditions,
                allowPrompt: allowPrompt
            ) {
                perform(action)
            }
        }
    }

    func closedDisplayAutoTick() {
        for action in closedDisplayCoordinator.tick(closedDisplayConditions) {
            perform(action)
        }
    }

    /// Once-a-second pulse: a battery safety pause also clears sticky
    /// closed-display mode, otherwise `pmset disablesleep` keeps a lid-closed
    /// Mac awake past the cutoff. "Only while brewing" already releases with
    /// the session, so this path is the sticky case (see
    /// ``BatteryPauseClosedDisplay``).
    func syncBatteryPauseClosedDisplay() {
        let paused = session.pausedByBattery
        let onlyWhileBrewing = settings.closedDisplayOnlyWhileBrewing
        if onlyWhileBrewing {
            batteryLiftedClosedDisplay = false
            sawBatteryPaused = paused
            return
        }
        switch BatteryPauseClosedDisplay.decide(
            paused: paused,
            onlyWhileBrewing: onlyWhileBrewing,
            settingIsOn: closedDisplayEnabled,
            alreadyLifted: batteryLiftedClosedDisplay,
            helperInstalled: helperInstalled
        ) {
        case .idle:
            break
        case .lift:
            // Same rule as the thermal lift: only through the prompt-free
            // daemon path; never ask for a password from an unattended safety
            // action. Re-asserted every tick while the setting is still on, so
            // a failed write or a thermal restore mid-pause cannot stick.
            batteryLiftedClosedDisplay = true
            setClosedDisplay(false, userInitiated: false)
        case .skipLiftNeedsHelper:
            batteryLiftedClosedDisplay = true
            if !sawBatteryPaused {
                notifier.notify(
                    title: L("Closed-display mode left on"),
                    body: L("Keepresso paused on low battery but can't switch off closed-display mode without the administrator helper (Preferences ▸ General)."),
                    sound: false
                )
            }
        case .restore:
            batteryLiftedClosedDisplay = false
            if helperInstalled { setClosedDisplay(true, userInitiated: false) }
        }
        sawBatteryPaused = paused
    }


    /// Whether the private virtual-display API exists on this macOS.
    var virtualDisplaySupported: Bool { virtualDisplay.isSupported }

    var virtualDisplayEnabled: Bool { settings.virtualDisplay != nil }

    var virtualDisplayConfig: VirtualDisplayConfig? { settings.virtualDisplay }

    var virtualDisplayError: String? { virtualDisplay.lastError }

    func setVirtualDisplay(_ config: VirtualDisplayConfig?) {
        settings.virtualDisplay = config
        virtualDisplay.config = config
        persist()
    }


    func refreshStreaming() {
        Task { await streaming.refresh() }
        refreshAWDLState()
        helper.refresh()
    }

    func refreshCaptive() {
        Task { await captive.refresh() }
        helper.refresh()
    }

    /// Flush the DNS cache through the helper daemon. Returns false when the
    /// helper is missing or the call fails, so the window can copy the sudo
    /// command instead of prompting. Both XPC calls can block for their whole
    /// timeout when the daemon is registered but not spawning, so they run off
    /// the main actor: `AppModel` is `@MainActor`.
    func flushDNS() async -> Bool {
        guard helperInstalled else { return false }
        let client = helperClient
        return await Task.detached {
            // Live handshake: the cached `daemonProtocolVersion` stays nil until
            // a verify run, so an early Wi-Fi assistant flush must not treat a
            // ready protocol-9 daemon as too old.
            guard let version = client.pingVersion(),
                  version >= HelperService.flushDNSMinProtocol else {
                return false
            }
            return client.flushDNS()
        }.value
    }

    func lockKeyboard(duration: TimeInterval?) async -> KeyboardLockResult {
        let helperCanLockSilently = helperInstalled
            && (helper.daemonProtocolVersion ?? 0) >= KeyboardLocker.helperMinProtocol
        let needsPrompt = !helperCanLockSilently
        let window = needsPrompt ? NSApp.keyWindow : nil
        if needsPrompt {
            NSApp.activate(ignoringOtherApps: true)
        }
        let result = await keyboardLock.lock(duration: duration)
        if needsPrompt {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            WindowPlacement.repairIfWedged(window, attempts: 3)
        }
        if result != .cancelled {
            suspendHotKeyForKeyboardLock()
        }
        return result
    }

    func refreshAWDLState() {
        Task { await awdl.refresh() }
    }

    func setAWDLWatchdog(_ on: Bool) {
        if !on {
            gamingWatcher.resetGrace()
            awdl.holdAutoOff()
        }
        // The admin prompt steals focus and can bury the window the toggle lives
        // in (the Gaming & Streaming window). Capture it now, while it's key, and
        // bring it back once the prompt is answered. No prompt can appear when
        // the helper daemon is installed (or the fallback loop is already
        // authorized this run), so skip the dance there.
        let dance = on && !helperInstalled && !awdl.isAuthorized
        runAfterPossibleAuthPrompt(needsPrompt: dance) {
            if on {
                await self.awdl.start()
                if self.awdl.lastError != nil, self.helperInstalled {
                    self.verifyHelper()
                }
            } else {
                await self.awdl.stop()
            }
        }
    }

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
                runAfterPossibleAuthPrompt(needsPrompt: true) {
                    await self.awdl.prime()
                }
            } else if !newValue {
                gamingWatcher.resetGrace()
                Task { await awdl.stopIfAuto() }
            }
        }
    }

    @ObservationIgnored private let gamingWatcher = GracePeriodTrigger(
        wrapping: GamingTrigger(),
        grace: 60
    )

    var awdlGraceSeconds: TimeInterval {
        get { settings.awdlGraceSeconds }
        set {
            settings.awdlGraceSeconds = newValue
            gamingWatcher.grace = newValue
            persist()
        }
    }

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

    @ObservationIgnored private let controllerMonitor = GCControllerMonitor()

    /// Declares user activity during controller play (gamepad input doesn't
    /// reliably reset the HID idle timer). Enabled flag mirrored from settings.
    @ObservationIgnored let controllerPoker = ControllerActivityPoker()

    @ObservationIgnored private(set) lazy var gamePriority = GamePriorityController { [weak self] holding, pid in
        guard let self, self.helperInstalled else { return }
        let client = self.helperClient
        Task.detached { _ = client.setPriorityHold(holding, pid: pid) }
    }

    var gamePriorityBoost: Bool {
        get { settings.gamePriorityBoost }
        set {
            settings.gamePriorityBoost = newValue
            gamePriority.autoWithGaming = newValue
            persist()
        }
    }

    var controllerPokeWhileGaming: Bool {
        get { settings.controllerPokeWhileGaming }
        set {
            settings.controllerPokeWhileGaming = newValue
            controllerPoker.enabled = newValue
            persist()
        }
    }

    func awdlAutoTick() {
        let wantsPulse = settings.awdlAutoWithGaming
            || settings.gamePriorityBoost
            || settings.controllerPokeWhileGaming
        guard wantsPulse else { return }
        gamingWatcher.tick()
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

    enum AWDLStatus: Equatable {
        case off
        case watchingForGame
        case pausedManually
        case pausedForGame
        case resumingAfterGame(seconds: Int)

        var isPausing: Bool {
            switch self {
            case .pausedManually, .pausedForGame, .resumingAfterGame: return true
            case .off, .watchingForGame: return false
            }
        }
    }

    var awdlStatus: AWDLStatus {
        guard awdl.isRunning else {
            return settings.awdlAutoWithGaming ? .watchingForGame : .off
        }
        if settings.awdlAutoWithGaming {
            if gamingWatcher.wrappedIsSatisfied { return .pausedForGame }
            if let remaining = gamingWatcher.graceRemaining {
                return .resumingAfterGame(seconds: KeepressoSettings.displaySeconds(remaining))
            }
        }
        return .pausedManually
    }


    func refreshReadiness() {
        Task { await readiness.refresh() }
        permissionChecks.rebuild(for: settings.ruleSet.rules)
    }

    @ObservationIgnored private lazy var permissionChecks = PermissionChecksBuilder(readiness: readiness)


    func currentSSID() -> String? { CoreWLANNetworkMonitor().current.ssid }

    func mountedVolumes() -> [String] {
        FileManagerVolumeMonitor().current.volumeNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func pairedBluetoothDevices() -> [String] {
        IOBluetoothDeviceMonitor().current.pairedDeviceNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    struct RunningApp: Identifiable, Hashable {
        let installPath: String
        let name: String
        let bundleID: String
        /// The path to pin a rule to, set only when several installs share
        /// ``bundleID``. `nil` in the ordinary case keeps the rule portable:
        /// a moved, re-downloaded or translocated app still matches.
        let bundlePath: String?

        var id: String { installPath }
    }

    func runningApps() -> [RunningApp] {
        var candidates: [(name: String, bundleID: String, installPath: String, fileName: String)] = []
        var seenPaths = Set<String>()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, let url = app.bundleURL else { continue }
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            let fileName = url.deletingPathExtension().lastPathComponent
            // Prefer the Dock-localized name; fall back to the bundle filename
            // when localization is missing.
            candidates.append((app.localizedName ?? fileName, id, path, fileName))
        }

        let installsPerID = Dictionary(grouping: candidates, by: \.bundleID).mapValues(\.count)
        // When the ambiguous installs also share a localized name, show the
        // on-disk bundle filename so the rows stay tellable apart.
        let nameCounts = Dictionary(grouping: candidates, by: { "\($0.bundleID)\0\($0.name)" })
            .mapValues(\.count)

        return candidates
            .map { app in
                let ambiguous = (installsPerID[app.bundleID] ?? 0) > 1
                let sharesName = (nameCounts["\(app.bundleID)\0\(app.name)"] ?? 0) > 1
                return RunningApp(
                    installPath: app.installPath,
                    name: sharesName ? app.fileName : app.name,
                    bundleID: app.bundleID,
                    bundlePath: ambiguous ? app.installPath : nil
                )
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
