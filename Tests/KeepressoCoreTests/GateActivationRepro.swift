import Testing
import Foundation
@testable import KeepressoCore

private final class ReproPower: PowerSourceMonitoring {
    let current: PowerSourceSnapshot
    init(_ s: PowerSourceSnapshot) { current = s }
}
private final class ReproGaming: GamingMonitoring {
    let current: GamingSnapshot
    init(_ s: GamingSnapshot) { current = s }
}
private final class ReproProcess: ProcessListing {
    let current: [String]
    init(_ s: [String]) { current = s }
}
private final class ReproAssert: PowerAsserting {
    private(set) var held: Set<PowerAssertionKind> = []
    func apply(_ kinds: Set<PowerAssertionKind>, reason: String) { held = kinds }
}

/// Mirrors the reported bug: combine .any, "On AC power" and Process "claude"
/// satisfied, "Playing a game" not. The gate should activate the session.
@MainActor
@Test func gateActivatesWhenAnyConditionIsMet() {
    let factory = TriggerFactory(
        powerSource: ReproPower(PowerSourceSnapshot(provider: .ac, isCharging: true, hasBattery: true)),
        processes: ReproProcess(["claude --resume"]),
        gaming: ReproGaming(GamingSnapshot(frontmostBundleID: "com.apple.dt.Xcode"))
    )
    let gate = TriggerGateController(factory: factory)
    gate.rebuild(
        rules: [.powerSource(.onACPower), .gaming, .process("claude")],
        combine: .any,
        enabled: true
    )

    // Wire exactly like AppModel.applyTriggerGate.
    let session = SessionController(assertions: ReproAssert(), activity: NoopActivity(), endActor: NoopEnd())
    session.triggerGate = gate.engine

    // What the menu shows.
    let states = gate.ruleStates()
    #expect(states?.filter(\.satisfied).count == 2)

    session.reconcile()
    #expect(session.isActive) // <-- should be Brewing, not Idle
}

private final class NoopActivity: ActivitySimulating { func poke(_: ActivityPokeKind) {} }
private final class NoopEnd: SessionEndActing { func perform(_ action: SessionEndAction) {} }
