import Testing
import Foundation
@testable import KeepressoCore

/// Power-source monitor stub returning a canned snapshot.
private final class FakePowerSource: PowerSourceMonitoring {
    var current: PowerSourceSnapshot
    init(_ snapshot: PowerSourceSnapshot) { self.current = snapshot }
}

private extension PowerSourceSnapshot {
    static let onAC = PowerSourceSnapshot(provider: .ac, isCharging: false, hasBattery: true)
    static let charging = PowerSourceSnapshot(provider: .ac, isCharging: true, hasBattery: true)
    static let onBattery = PowerSourceSnapshot(provider: .battery, isCharging: false, hasBattery: true)
    static let desktopAC = PowerSourceSnapshot(provider: .ac, isCharging: false, hasBattery: false)
}

@Test func onACPowerMatchesACAndCharging() {
    #expect(PowerSourceTrigger.evaluate(.onACPower, against: .onAC))
    #expect(PowerSourceTrigger.evaluate(.onACPower, against: .charging))
    #expect(PowerSourceTrigger.evaluate(.onACPower, against: .desktopAC))
    #expect(!PowerSourceTrigger.evaluate(.onACPower, against: .onBattery))
}

@Test func onBatteryMatchesOnlyBattery() {
    #expect(PowerSourceTrigger.evaluate(.onBattery, against: .onBattery))
    #expect(!PowerSourceTrigger.evaluate(.onBattery, against: .onAC))
    #expect(!PowerSourceTrigger.evaluate(.onBattery, against: .charging))
}

@Test func chargingMatchesOnlyWhileCharging() {
    #expect(PowerSourceTrigger.evaluate(.charging, against: .charging))
    #expect(!PowerSourceTrigger.evaluate(.charging, against: .onAC))   // plugged in but full
    #expect(!PowerSourceTrigger.evaluate(.charging, against: .onBattery))
}

@Test func triggerReadsThroughInjectedMonitor() {
    let monitor = FakePowerSource(.onBattery)
    let trigger = PowerSourceTrigger(match: .onBattery, monitor: monitor)
    #expect(trigger.isSatisfied())
    #expect(trigger.label == "On battery")

    monitor.current = .charging
    #expect(!trigger.isSatisfied()) // re-reads live state each call
}

@Test func unknownProviderSatisfiesNothing() {
    let unknown = PowerSourceSnapshot(provider: .unknown, isCharging: false, hasBattery: false)
    #expect(!PowerSourceTrigger.evaluate(.onACPower, against: unknown))
    #expect(!PowerSourceTrigger.evaluate(.onBattery, against: unknown))
    #expect(!PowerSourceTrigger.evaluate(.charging, against: unknown))
}
