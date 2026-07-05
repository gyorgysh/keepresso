import Testing
import Foundation
@testable import KeepressoCore

private final class GateFakeNetwork: NetworkMonitoring {
    var current: NetworkSnapshot
    init(_ s: NetworkSnapshot) { current = s }
}

private final class GateFakeWorkspace: WorkspaceMonitoring {
    var current: WorkspaceSnapshot
    init(_ s: WorkspaceSnapshot) { current = s }
}

private final class GateFakeDisplays: DisplayMonitoring {
    var current: DisplaySnapshot
    init(_ s: DisplaySnapshot) { current = s }
}

@MainActor
@Test func gateRuleStatesAreNilWhenDisabled() {
    let gate = TriggerGateController()
    gate.rebuild(rules: [.audioPlaying], combine: .any, enabled: false)
    #expect(gate.engine == nil)
    #expect(gate.ruleStates() == nil)
}

@MainActor
@Test func gateRuleStatesReflectTheLiveMonitorPastTheCache() {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let network = GateFakeNetwork(NetworkSnapshot(ssid: "Cafe"))
    let factory = TriggerFactory(network: network, now: { now })
    let gate = TriggerGateController(factory: factory, now: { now })

    gate.rebuild(rules: [.wifiSSID("Cafe")], combine: .any, enabled: true)
    #expect(gate.ruleStates()?.first?.satisfied == true)

    // Within the cache TTL the earlier verdict is served even after the network
    // changes, so a flurry of menu reads don't each re-evaluate.
    network.current = NetworkSnapshot(ssid: nil)
    #expect(gate.ruleStates()?.first?.satisfied == true)

    // Past the TTL it re-evaluates against the live monitor.
    now = now.addingTimeInterval(1)
    #expect(gate.ruleStates()?.first?.satisfied == false)
}

@MainActor
@Test func gateReusesLiveTriggersSoGraceSurvivesAnUnrelatedEdit() {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let workspace = GateFakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.test"], frontmostBundleID: "com.test"
    ))
    let factory = TriggerFactory(
        displays: GateFakeDisplays(DisplaySnapshot(externalDisplayCount: 0, totalDisplayCount: 1)),
        workspace: workspace,
        now: { now }
    )
    let gate = TriggerGateController(factory: factory, now: { now })
    let appRule = TriggerRule.app(AppRule(bundleID: "com.test", match: .frontmost, grace: 60))

    gate.rebuild(rules: [appRule], combine: .any, enabled: true)
    gate.engine?.tick() // the app is frontmost: arms the grace window
    #expect(gate.ruleStates()?.first?.satisfied == true)

    // The app leaves the foreground, then an UNRELATED rule is added. The app's
    // live trigger (and its in-flight grace) must carry over the rebuild.
    workspace.current = WorkspaceSnapshot(runningBundleIDs: [], frontmostBundleID: nil)
    now = now.addingTimeInterval(30)
    gate.rebuild(rules: [appRule, .externalDisplay], combine: .any, enabled: true)
    gate.engine?.tick()
    #expect(gate.ruleStates()?.first?.satisfied == true) // 30s < 60s grace, still held

    now = now.addingTimeInterval(40) // 70s since last frontmost: grace expired
    gate.engine?.tick()
    #expect(gate.ruleStates()?.first?.satisfied == false)
}

@MainActor
@Test func ruleStatesFlagTheGraceWindowAsInGrace() {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let workspace = GateFakeWorkspace(WorkspaceSnapshot(
        runningBundleIDs: ["com.test"], frontmostBundleID: "com.test"
    ))
    let factory = TriggerFactory(
        displays: GateFakeDisplays(DisplaySnapshot(externalDisplayCount: 0, totalDisplayCount: 1)),
        workspace: workspace,
        now: { now }
    )
    let gate = TriggerGateController(factory: factory, now: { now })
    gate.rebuild(
        rules: [.app(AppRule(bundleID: "com.test", match: .frontmost, grace: 60))],
        combine: .any, enabled: true
    )

    gate.engine?.tick()
    #expect(gate.ruleStates()?.first?.satisfied == true)
    #expect(gate.ruleStates()?.first?.inGrace == false) // app in front: green, not amber

    workspace.current = WorkspaceSnapshot(runningBundleIDs: [], frontmostBundleID: nil)
    now = now.addingTimeInterval(20)
    gate.engine?.tick()
    #expect(gate.ruleStates()?.first?.satisfied == true)
    #expect(gate.ruleStates()?.first?.inGrace == true)  // lingering in grace: amber
    #expect(gate.ruleStates()?.first?.graceRemaining == 40) // 60 - 20 left, for the countdown

    now = now.addingTimeInterval(50) // past the 60s grace
    gate.engine?.tick()
    #expect(gate.ruleStates()?.first?.satisfied == false)
    #expect(gate.ruleStates()?.first?.inGrace == false)
}
