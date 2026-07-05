import Testing
import Foundation
@testable import KeepressoCore

/// A trigger whose state the test flips directly, counting how often it's ticked.
private final class StubTrigger: Trigger {
    var satisfied: Bool
    let label: String
    private(set) var tickCount = 0
    init(_ satisfied: Bool, label: String = "stub") {
        self.satisfied = satisfied
        self.label = label
    }
    func tick() { tickCount += 1 }
    func isSatisfied() -> Bool { satisfied }
}

private final class FakeDisplays: DisplayMonitoring {
    var current: DisplaySnapshot
    init(_ s: DisplaySnapshot) { current = s }
}

private final class FakeNetwork: NetworkMonitoring {
    var current: NetworkSnapshot
    init(_ s: NetworkSnapshot) { current = s }
}

// MARK: - Combine logic

@Test func emptyEngineNeverFires() {
    #expect(TriggerEngine().isSatisfied() == false)
    #expect(TriggerEngine(combine: .all).isSatisfied() == false)
}

@Test func anyCombineIsOR() {
    let engine = TriggerEngine(combine: .any, triggers: [StubTrigger(false), StubTrigger(true)])
    #expect(engine.isSatisfied())
}

@Test func allCombineIsAND() {
    let on = StubTrigger(true)
    let off = StubTrigger(false)
    #expect(TriggerEngine(combine: .all, triggers: [on, off]).isSatisfied() == false)
    #expect(TriggerEngine(combine: .all, triggers: [on, StubTrigger(true)]).isSatisfied())
}

// MARK: - tick() decoupled from the combine

@Test func tickAdvancesEveryTriggerEvenWhenCombineShortCircuits() {
    // .any short-circuits on the first satisfied trigger, .all on the first
    // unsatisfied one. tick() must still step every trigger so stateful ones
    // (grace, CPU EMA) advance at a fixed cadence regardless of the decision.
    let a = StubTrigger(true), b = StubTrigger(false)
    let engine = TriggerEngine(combine: .any, triggers: [a, b])
    engine.tick()
    _ = engine.isSatisfied()
    #expect(a.tickCount == 1)
    #expect(b.tickCount == 1) // not starved by the OR short-circuit on `a`
}

@MainActor
@Test func gracePeriodSurvivesAnORShortCircuit() {
    // The C1 regression: OR[audio(decides), gaming(grace 300s)]. The grace's
    // window is advanced in tick(), so an earlier OR-sibling firing first no
    // longer starves it and silently voids the grace.
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let game = StubTrigger(true, label: "gaming")
    let grace = GracePeriodTrigger(wrapping: game, grace: 300, now: { now })
    let audio = StubTrigger(true, label: "audio") // masks `grace` in the combine
    let engine = TriggerEngine(combine: .any, triggers: [audio, grace])

    engine.tick() // both true at t=0: records lastSatisfiedAt even though
    _ = engine.isSatisfied() // isSatisfied() short-circuits on `audio`
    #expect(grace.isSatisfied())

    game.satisfied = false // the game quits
    now = now.addingTimeInterval(200)
    engine.tick()
    #expect(grace.isSatisfied()) // 200s < 300s: still lingering, grace intact

    now = now.addingTimeInterval(150) // 350s since last true
    engine.tick()
    #expect(!grace.isSatisfied()) // grace finally expires
}

// MARK: - Display & network triggers

@Test func externalDisplayTriggerReflectsMonitor() {
    let monitor = FakeDisplays(DisplaySnapshot(externalDisplayCount: 0, totalDisplayCount: 1))
    let trigger = ExternalDisplayTrigger(monitor: monitor)
    #expect(trigger.isSatisfied() == false)
    monitor.current = DisplaySnapshot(externalDisplayCount: 1, totalDisplayCount: 2)
    #expect(trigger.isSatisfied())
}

@Test func wifiTriggerMatchesExactSSID() {
    let monitor = FakeNetwork(NetworkSnapshot(ssid: "Cafe"))
    let trigger = WiFiSSIDTrigger(ssid: "Cafe", monitor: monitor)
    #expect(trigger.isSatisfied())

    monitor.current = NetworkSnapshot(ssid: "cafe") // case-sensitive
    #expect(trigger.isSatisfied() == false)

    monitor.current = NetworkSnapshot(ssid: nil) // not associated
    #expect(trigger.isSatisfied() == false)
}
