import Testing
import Foundation
@testable import KeepressoCore

private final class FakeWorkspace: WorkspaceMonitoring {
    var current: WorkspaceSnapshot
    init(_ s: WorkspaceSnapshot) { current = s }
}

@Test func rulePermissionMapping() {
    #expect(TriggerRule.wifiSSID("Cafe").requiredPermission == .location)
    #expect(TriggerRule.bluetoothDevice("AirPods").requiredPermission == .bluetooth)
    #expect(TriggerRule.calendarEvent.requiredPermission == .calendar)
    // A rule reading only unrestricted state needs no permission.
    #expect(TriggerRule.gaming.requiredPermission == nil)
    #expect(TriggerRule.cpuLoad(thresholdPercent: 50).requiredPermission == nil)
}

// MARK: - App trigger (running / frontmost)

@Test func appTriggerMatchesRunning() {
    let monitor = FakeWorkspace(WorkspaceSnapshot(runningBundleIDs: ["com.apple.Music"]))
    let trigger = AppTrigger(bundleID: "com.apple.FaceTime", match: .running, monitor: monitor)
    #expect(trigger.isSatisfied() == false)

    monitor.current = WorkspaceSnapshot(runningBundleIDs: ["com.apple.Music", "com.apple.FaceTime"])
    #expect(trigger.isSatisfied())
}

@Test func appTriggerMatchesFrontmostOnly() {
    let monitor = FakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.apple.Music", "com.apple.FaceTime"],
        frontmostBundleID: "com.apple.Music"
    ))
    let trigger = AppTrigger(bundleID: "com.apple.FaceTime", match: .frontmost, monitor: monitor)
    #expect(trigger.isSatisfied() == false) // running but not frontmost

    monitor.current = WorkspaceSnapshot(
        runningBundleIDs: ["com.apple.Music", "com.apple.FaceTime"],
        frontmostBundleID: "com.apple.FaceTime"
    )
    #expect(trigger.isSatisfied())
}

@Test func appTriggerCanMatchOneOfTwoAppsWithTheSameBundleID() {
    let stablePath = "/Applications/Xcode.app"
    let betaPath = "/Applications/Xcode-beta.app"
    let monitor = FakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.apple.dt.Xcode"],
        runningBundlePaths: [stablePath, betaPath],
        frontmostBundleID: "com.apple.dt.Xcode",
        frontmostBundlePath: betaPath
    ))
    let trigger = AppTrigger(
        bundleID: "com.apple.dt.Xcode",
        bundlePath: betaPath,
        match: .frontmost,
        monitor: monitor
    )
    #expect(trigger.isSatisfied())

    monitor.current.frontmostBundlePath = stablePath
    #expect(trigger.isSatisfied() == false)
}

@Test func appTriggerPathMatchWorksForRunning() {
    let stablePath = "/Applications/Xcode.app"
    let betaPath = "/Applications/Xcode-beta.app"
    let monitor = FakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.apple.dt.Xcode"],
        runningBundlePaths: [stablePath, betaPath]
    ))
    let betaOnly = AppTrigger(
        bundleID: "com.apple.dt.Xcode",
        bundlePath: betaPath,
        match: .running,
        monitor: monitor
    )
    #expect(betaOnly.isSatisfied())

    monitor.current.runningBundlePaths = [stablePath]
    #expect(betaOnly.isSatisfied() == false)
}

@Test func appTriggerWithoutPathStillMatchesByBundleID() {
    // Path-less rules (presets, older saves) must keep matching by ID even when
    // the snapshot also carries paths for those installs.
    let monitor = FakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.apple.dt.Xcode"],
        runningBundlePaths: ["/Applications/Xcode.app", "/Applications/Xcode-beta.app"],
        frontmostBundleID: "com.apple.dt.Xcode",
        frontmostBundlePath: "/Applications/Xcode-beta.app"
    ))
    let byID = AppTrigger(bundleID: "com.apple.dt.Xcode", match: .running, monitor: monitor)
    #expect(byID.isSatisfied())
    let frontmost = AppTrigger(bundleID: "com.apple.dt.Xcode", match: .frontmost, monitor: monitor)
    #expect(frontmost.isSatisfied())
}

@Test func appTriggerEmptyPathFallsBackToBundleID() {
    let monitor = FakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.apple.FaceTime"],
        runningBundlePaths: ["/System/Applications/FaceTime.app"]
    ))
    let trigger = AppTrigger(
        bundleID: "com.apple.FaceTime",
        bundlePath: "",
        match: .running,
        monitor: monitor
    )
    #expect(trigger.isSatisfied())
}

@Test func appRuleWithoutBundlePathDecodesForBackwardCompatibility() throws {
    let json = """
    { "bundleID": "com.acme.tool", "match": "running", "grace": 0 }
    """
    let decoded = try JSONDecoder().decode(AppRule.self, from: Data(json.utf8))
    #expect(decoded.bundlePath == nil)
    #expect(decoded.bundleID == "com.acme.tool")
}

@Test func gracePeriodLingersAfterConditionDrops() {
    var t = Date(timeIntervalSince1970: 1_000_000)
    let inner = StubFlag(true)
    let grace = GracePeriodTrigger(wrapping: inner, grace: 60, now: { t })

    grace.tick()                          // the once-per-reconcile step
    #expect(grace.isSatisfied())          // condition true
    inner.value = false
    t = t.addingTimeInterval(30)
    grace.tick()
    #expect(grace.isSatisfied())          // within grace window
    t = t.addingTimeInterval(31)          // 61s since last true
    grace.tick()
    #expect(grace.isSatisfied() == false) // window expired

    inner.value = true                    // re-arms
    grace.tick()
    #expect(grace.isSatisfied())
}

@Test func graceRemainingCountsDownAfterTheConditionDrops() {
    var t = Date(timeIntervalSince1970: 1_000_000)
    let inner = StubFlag(true)
    let grace = GracePeriodTrigger(wrapping: inner, grace: 60, now: { t })

    grace.tick()
    #expect(grace.wrappedIsSatisfied)
    #expect(grace.graceRemaining == nil) // condition holds: no countdown

    inner.value = false
    t = t.addingTimeInterval(20)
    grace.tick()
    #expect(grace.wrappedIsSatisfied == false)
    #expect(grace.graceRemaining == 40) // 60 - 20 left in the window

    t = t.addingTimeInterval(50) // past the window
    grace.tick()
    #expect(grace.graceRemaining == nil)
}

private final class StubFlag: Trigger {
    var value: Bool
    let label = "flag"
    init(_ v: Bool) { value = v }
    func isSatisfied() -> Bool { value }
}

// MARK: - Rule -> live trigger factory

@MainActor
@Test func factoryBuildsEngineFromRuleSet() {
    let battery = PowerSourceSnapshot(provider: .battery, isCharging: false, hasBattery: true)
    let factory = TriggerFactory(
        powerSource: ConstPower(battery),
        displays: ConstDisplays(DisplaySnapshot(externalDisplayCount: 1, totalDisplayCount: 2)),
        network: ConstNetwork(NetworkSnapshot(ssid: "Home")),
        workspace: ConstWorkspace(WorkspaceSnapshot(runningBundleIDs: []))
    )
    // AND of "external display" (true) and "on battery" (true) → satisfied.
    let ruleSet = RuleSet(combine: .all, rules: [.externalDisplay, .powerSource(.onBattery)])
    #expect(factory.makeEngine(from: ruleSet).isSatisfied())

    // Add a Wi-Fi rule that won't match → AND fails.
    let strict = RuleSet(combine: .all, rules: [.externalDisplay, .wifiSSID("Office")])
    #expect(factory.makeEngine(from: strict).isSatisfied() == false)
}

@Test func ruleLabelsAreHumanReadable() {
    #expect(TriggerRule.powerSource(.charging).label == "Charging")
    #expect(TriggerRule.externalDisplay.label == "External display connected")
    #expect(TriggerRule.wifiSSID("Cafe").label.contains("Cafe"))
    #expect(TriggerRule.app(AppRule(bundleID: "com.x.y", match: .running)).label == "App com.x.y is running")
    #expect(TriggerRule.app(AppRule(bundleID: "com.x.y", match: .frontmost, grace: 30)).label
            == "App com.x.y is frontmost (+30s)")
}

// MARK: - Persistence round-trip

@Test func ruleSetCodableRoundTrip() throws {
    let original = RuleSet(combine: .all, rules: [
        .powerSource(.charging),
        .externalDisplay,
        .wifiSSID("Home"),
        .app(AppRule(bundleID: "com.apple.FaceTime", match: .frontmost, grace: 120)),
    ])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
    #expect(decoded == original)
}

@Test func settingsStoreRoundTrips() {
    let defaults = UserDefaults(suiteName: "keepresso.tests.settings")!
    defaults.removePersistentDomain(forName: "keepresso.tests.settings")
    let store = UserDefaultsSettingsStore(defaults: defaults, key: "k")

    #expect(store.load() == .default) // nothing saved yet

    var settings = KeepressoSettings.default
    settings.triggersEnabled = true
    settings.defaultMode = .timed(duration: 3600)
    settings.ruleSet = RuleSet(combine: .all, rules: [.externalDisplay])
    store.save(settings)

    #expect(store.load() == settings)
}

// Const monitors for the factory test.
private final class ConstPower: PowerSourceMonitoring {
    let current: PowerSourceSnapshot; init(_ s: PowerSourceSnapshot) { current = s }
}
private final class ConstDisplays: DisplayMonitoring {
    let current: DisplaySnapshot; init(_ s: DisplaySnapshot) { current = s }
}
private final class ConstNetwork: NetworkMonitoring {
    let current: NetworkSnapshot; init(_ s: NetworkSnapshot) { current = s }
}
private final class ConstWorkspace: WorkspaceMonitoring {
    let current: WorkspaceSnapshot; init(_ s: WorkspaceSnapshot) { current = s }
}

// MARK: - Forgiving decode (unknown rule types)

@Test func ruleSetDropsUnknownRuleInsteadOfWipingEverything() throws {
    // A newer build's rule case (reached via a downgrade, or a set exported from
    // a newer version and imported) must drop only that rule, not throw the
    // whole decode — which, because settings load through `try?`, would silently
    // reset every setting to defaults.
    let original = RuleSet(combine: .all, rules: [.gaming, .audioPlaying])
    let data = try JSONEncoder().encode(original)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var rules = try #require(object["rules"] as? [Any])
    rules.insert(["futureRuleFromANewerBuild": [String: Any]()], at: 1)
    object["rules"] = rules
    let spliced = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(RuleSet.self, from: spliced)
    #expect(decoded.combine == .all)                       // other fields survive
    #expect(decoded.rules == [.gaming, .audioPlaying])     // known rules kept, in order
}
