import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Machine identity for user-facing copy

@Test func deviceNameMapsModelFamilies() {
    #expect(MachineIdentity.deviceName(modelIdentifier: "MacBookPro18,3") == "your MacBook Pro")
    #expect(MachineIdentity.deviceName(modelIdentifier: "MacBookAir10,1") == "your MacBook Air")
    #expect(MachineIdentity.deviceName(modelIdentifier: "MacBook10,1") == "your MacBook")
    #expect(MachineIdentity.deviceName(modelIdentifier: "Macmini9,1") == "your Mac mini")
    #expect(MachineIdentity.deviceName(modelIdentifier: "MacStudio13,1") == "your Mac Studio")
    #expect(MachineIdentity.deviceName(modelIdentifier: "MacPro7,1") == "your Mac Pro")
    #expect(MachineIdentity.deviceName(modelIdentifier: "iMac21,1") == "your iMac")
    #expect(MachineIdentity.deviceName(modelIdentifier: "VMware7,1") == "your Mac")
    #expect(MachineIdentity.deviceName(modelIdentifier: nil) == "your Mac")
}

@Test func powerQualifierOnlyQualifiesUnpluggedBatteries() {
    func snap(_ provider: PowerSourceSnapshot.Provider, charging: Bool, battery: Bool, pct: Int? = nil) -> PowerSourceSnapshot {
        PowerSourceSnapshot(provider: provider, isCharging: charging, hasBattery: battery, percentage: pct)
    }
    #expect(MachineIdentity.powerQualifier(snap(.battery, charging: false, battery: true, pct: 80)) == "on battery")
    #expect(MachineIdentity.powerQualifier(snap(.battery, charging: false, battery: true, pct: 12)) == "on battery at 12%")
    #expect(MachineIdentity.powerQualifier(snap(.battery, charging: false, battery: true)) == "on battery")
    #expect(MachineIdentity.powerQualifier(snap(.battery, charging: true, battery: true, pct: 80)) == nil)
    #expect(MachineIdentity.powerQualifier(snap(.ac, charging: false, battery: false)) == nil)
    #expect(MachineIdentity.powerQualifier(snap(.unknown, charging: false, battery: false)) == nil)
}

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
