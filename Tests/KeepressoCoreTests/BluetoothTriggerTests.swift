import Testing
import Foundation
@testable import KeepressoCore

private final class FakeBluetoothMonitor: BluetoothMonitoring {
    var snapshot: BluetoothSnapshot
    init(connected: [String] = [], paired: [String] = []) {
        snapshot = BluetoothSnapshot(
            pairedDeviceNames: paired.isEmpty ? connected : paired,
            connectedDeviceNames: connected
        )
    }
    var current: BluetoothSnapshot { snapshot }
}

@Test func bluetoothTriggerFollowsConnectionState() {
    let monitor = FakeBluetoothMonitor(connected: ["WH-1000XM5"])
    let trigger = BluetoothDeviceTrigger(deviceName: "WH-1000XM5", monitor: monitor)
    #expect(trigger.isSatisfied())

    monitor.snapshot = BluetoothSnapshot()
    #expect(!trigger.isSatisfied())
}

@Test func bluetoothTriggerMatchesCaseInsensitively() {
    let monitor = FakeBluetoothMonitor(connected: ["AirPods Pro"])
    #expect(BluetoothDeviceTrigger(deviceName: "airpods pro", monitor: monitor).isSatisfied())
    #expect(!BluetoothDeviceTrigger(deviceName: "AirPods Max", monitor: monitor).isSatisfied())
}

@Test func bluetoothRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.bluetoothDevice("AirPods Pro")
    #expect(rule.label == "Bluetooth \u{201C}AirPods Pro\u{201D} connected")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}

@Test func factoryWrapsBluetoothTriggerInReleaseGrace() {
    // A brief disconnect (host switch, re-pair) must not drop the session;
    // only an outage past the grace does.
    let monitor = FakeBluetoothMonitor(connected: ["AirPods Pro"])
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let factory = TriggerFactory(bluetooth: monitor, now: { now })
    let engine = factory.makeEngine(from: RuleSet(rules: [.bluetoothDevice("AirPods Pro")]))
    engine.tick()
    #expect(engine.isSatisfied())

    monitor.snapshot = BluetoothSnapshot()
    now.addTimeInterval(BluetoothDeviceTrigger.releaseGrace - 1)
    engine.tick()
    #expect(engine.isSatisfied())

    now.addTimeInterval(2)
    engine.tick()
    #expect(!engine.isSatisfied())
}

@Test func bluetoothMonitorCachesWithinTTLAndReprobesAfter() {
    var probes = 0
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let monitor = IOBluetoothDeviceMonitor(ttl: 3, now: { now }) {
        probes += 1
        return BluetoothSnapshot(connectedDeviceNames: ["Keyboard"])
    }

    #expect(monitor.current.connectedDeviceNames == ["Keyboard"])
    now.addTimeInterval(2)
    _ = monitor.current
    #expect(probes == 1)

    now.addTimeInterval(2)
    _ = monitor.current
    #expect(probes == 2)
}
