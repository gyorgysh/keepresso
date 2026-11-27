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

    network.current = NetworkSnapshot(ssid: nil)
    #expect(gate.ruleStates()?.first?.satisfied == true)

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
    gate.engine?.tick()
    #expect(gate.ruleStates()?.first?.satisfied == true)

    workspace.current = WorkspaceSnapshot(runningBundleIDs: [], frontmostBundleID: nil)
    now = now.addingTimeInterval(30)
    gate.rebuild(rules: [appRule, .externalDisplay], combine: .any, enabled: true)
    gate.engine?.tick()
    #expect(gate.ruleStates()?.first?.satisfied == true)

    now = now.addingTimeInterval(40)
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
    #expect(gate.ruleStates()?.first?.inGrace == false)

    workspace.current = WorkspaceSnapshot(runningBundleIDs: [], frontmostBundleID: nil)
    now = now.addingTimeInterval(20)
    gate.engine?.tick()
    #expect(gate.ruleStates()?.first?.satisfied == true)
    #expect(gate.ruleStates()?.first?.inGrace == true)
    #expect(gate.ruleStates()?.first?.graceRemaining == 40)

    now = now.addingTimeInterval(50)
    gate.engine?.tick()
    #expect(gate.ruleStates()?.first?.satisfied == false)
    #expect(gate.ruleStates()?.first?.inGrace == false)
}
