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
    #expect(TriggerRule.gaming.requiredPermission == nil)
    #expect(TriggerRule.cpuLoad(thresholdPercent: 50).requiredPermission == nil)
}


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
    #expect(trigger.isSatisfied() == false)

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
        runningInstalls: [
            stablePath: "com.apple.dt.Xcode",
            betaPath: "com.apple.dt.Xcode",
        ],
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
        runningInstalls: [
            stablePath: "com.apple.dt.Xcode",
            betaPath: "com.apple.dt.Xcode",
        ]
    ))
    let betaOnly = AppTrigger(
        bundleID: "com.apple.dt.Xcode",
        bundlePath: betaPath,
        match: .running,
        monitor: monitor
    )
    #expect(betaOnly.isSatisfied())

    monitor.current.runningInstalls = [stablePath: "com.apple.dt.Xcode"]
    #expect(betaOnly.isSatisfied() == false)
}

@Test func appTriggerWithoutPathStillMatchesByBundleID() {
    let monitor = FakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.apple.dt.Xcode"],
        runningInstalls: [
            "/Applications/Xcode.app": "com.apple.dt.Xcode",
            "/Applications/Xcode-beta.app": "com.apple.dt.Xcode",
        ],
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
        runningInstalls: ["/System/Applications/FaceTime.app": "com.apple.FaceTime"]
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

@Test func appRuleWithBundlePathRoundTrips() throws {
    let original = AppRule(
        bundleID: "com.apple.dt.Xcode",
        bundlePath: "/Applications/Xcode-beta.app",
        name: "Xcode-beta",
        match: .frontmost,
        grace: 30
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AppRule.self, from: data)
    #expect(decoded == original)
    #expect(decoded.bundlePath == "/Applications/Xcode-beta.app")
}

@Test func appTriggerPathMatchAlsoRequiresBundleID() {
    let path = "/Applications/Xcode-beta.app"
    let monitor = FakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.other.App"],
        runningInstalls: [path: "com.other.App"],
        frontmostBundleID: "com.other.App",
        frontmostBundlePath: path
    ))
    let running = AppTrigger(
        bundleID: "com.apple.dt.Xcode",
        bundlePath: path,
        match: .running,
        monitor: monitor
    )
    #expect(running.isSatisfied() == false)

    let frontmost = AppTrigger(
        bundleID: "com.apple.dt.Xcode",
        bundlePath: path,
        match: .frontmost,
        monitor: monitor
    )
    #expect(frontmost.isSatisfied() == false)

    monitor.current.runningBundleIDs = ["com.apple.dt.Xcode"]
    monitor.current.runningInstalls = [path: "com.apple.dt.Xcode"]
    monitor.current.frontmostBundleID = "com.apple.dt.Xcode"
    #expect(running.isSatisfied())
    #expect(frontmost.isSatisfied())
}

@Test func appTriggerPathLockDoesNotCrossCoupleSeparateApps() {
    let lockedPath = "/Applications/Xcode-beta.app"
    let otherXcode = "/Applications/Xcode.app"
    let monitor = FakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.other.App", "com.apple.dt.Xcode"],
        runningInstalls: [
            lockedPath: "com.other.App",
            otherXcode: "com.apple.dt.Xcode",
        ]
    ))
    let running = AppTrigger(
        bundleID: "com.apple.dt.Xcode",
        bundlePath: lockedPath,
        match: .running,
        monitor: monitor
    )
    #expect(running.isSatisfied() == false)

    monitor.current.runningInstalls[lockedPath] = "com.apple.dt.Xcode"
    #expect(running.isSatisfied())
}

@Test func gracePeriodLingersAfterConditionDrops() {
    var t = Date(timeIntervalSince1970: 1_000_000)
    let inner = StubFlag(true)
    let grace = GracePeriodTrigger(wrapping: inner, grace: 60, now: { t })

    grace.tick()
    #expect(grace.isSatisfied())
    inner.value = false
    t = t.addingTimeInterval(30)
    grace.tick()
    #expect(grace.isSatisfied())
    t = t.addingTimeInterval(31)
    grace.tick()
    #expect(grace.isSatisfied() == false)

    inner.value = true
    grace.tick()
    #expect(grace.isSatisfied())
}

@Test func graceRemainingCountsDownAfterTheConditionDrops() {
    var t = Date(timeIntervalSince1970: 1_000_000)
    let inner = StubFlag(true)
    let grace = GracePeriodTrigger(wrapping: inner, grace: 60, now: { t })

    grace.tick()
    #expect(grace.wrappedIsSatisfied)
    #expect(grace.graceRemaining == nil)

    inner.value = false
    t = t.addingTimeInterval(20)
    grace.tick()
    #expect(grace.wrappedIsSatisfied == false)
    #expect(grace.graceRemaining == 40)

    t = t.addingTimeInterval(50)
    grace.tick()
    #expect(grace.graceRemaining == nil)
}

private final class StubFlag: Trigger {
    var value: Bool
    let label = "flag"
    init(_ v: Bool) { value = v }
    func isSatisfied() -> Bool { value }
}


@MainActor
@Test func factoryBuildsEngineFromRuleSet() {
    let battery = PowerSourceSnapshot(provider: .battery, isCharging: false, hasBattery: true)
    let factory = TriggerFactory(
        powerSource: ConstPower(battery),
        displays: ConstDisplays(DisplaySnapshot(externalDisplayCount: 1, totalDisplayCount: 2)),
        network: ConstNetwork(NetworkSnapshot(ssid: "Home")),
        workspace: ConstWorkspace(WorkspaceSnapshot(runningBundleIDs: []))
    )
    let ruleSet = RuleSet(combine: .all, rules: [.externalDisplay, .powerSource(.onBattery)])
    #expect(factory.makeEngine(from: ruleSet).isSatisfied())

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

    #expect(store.load() == .default)

    var settings = KeepressoSettings.default
    settings.triggersEnabled = true
    settings.defaultMode = .timed(duration: 3600)
    settings.ruleSet = RuleSet(combine: .all, rules: [.externalDisplay])
    store.save(settings)

    #expect(store.load() == settings)
}

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


@Test func absurdImportedGraceIsCappedAndLabelSafe() throws {
    let appJSON = #"{ "bundleID": "com.example.App", "grace": 1e308 }"#
    let appRule = try JSONDecoder().decode(AppRule.self, from: Data(appJSON.utf8))
    #expect(appRule.grace == SessionMode.maxTimedMinutes * 60)
    _ = appRule.label

    let agentJSON = #"{ "grace": 1e308 }"#
    let agentRule = try JSONDecoder().decode(AgentRule.self, from: Data(agentJSON.utf8))
    #expect(agentRule.grace == SessionMode.maxTimedMinutes * 60)
    _ = agentRule.label

    let negative = try JSONDecoder().decode(AppRule.self, from: Data(#"{ "bundleID": "x", "grace": -5 }"#.utf8))
    #expect(negative.grace == 0)
    _ = negative.label
}

@Test func subSecondGraceOmitsDurationSuffixInLabels() {
    let app = AppRule(bundleID: "com.example.App", match: .running, grace: 0.4)
    #expect(app.label == "App com.example.App is running")
    let agent = AgentRule(grace: 0.4)
    #expect(agent.label == "AI agent working")
}

@Test func ruleSetDropsUnknownRuleInsteadOfWipingEverything() throws {
    let original = RuleSet(combine: .all, rules: [.gaming, .audioPlaying])
    let data = try JSONEncoder().encode(original)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var rules = try #require(object["rules"] as? [Any])
    rules.insert(["futureRuleFromANewerBuild": [String: Any]()], at: 1)
    object["rules"] = rules
    let spliced = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(RuleSet.self, from: spliced)
    #expect(decoded.combine == .all)
    #expect(decoded.rules == [.gaming, .audioPlaying])
}
