import Testing
import Foundation
@testable import KeepressoCore

/// A trigger whose state the test flips directly.
private final class StubTrigger: Trigger {
    var satisfied: Bool
    let label: String
    init(_ satisfied: Bool, label: String = "stub") {
        self.satisfied = satisfied
        self.label = label
    }
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
