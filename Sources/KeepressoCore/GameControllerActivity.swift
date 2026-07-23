import Foundation
import GameController
import IOKit.hid

// MARK: - Monitor seam

/// Abstraction over "is a game controller connected?" so the trigger and the
/// activity poke can be tested without hardware. Mirrors the other monitor
/// seams (``GamingMonitoring``, ``BluetoothMonitoring``).
public protocol ControllerMonitoring: AnyObject {
    /// Number of currently connected game controllers.
    var connectedCount: Int { get }
}

/// Real backend: the GameController framework plus a HID sweep for Steam
/// hardware. `GCController.controllers()` tracks connects and disconnects on
/// its own once the process has a run loop (the app always does) and covers
/// DualSense, DualShock, Xbox, and most modern pads, but it never reports
/// Valve hardware: a Steam Controller without Steam Input presents itself as
/// a keyboard and mouse ("lizard mode"). Plain HID *enumeration* still sees
/// the device, needs no permission (only reading input reports is TCC-gated,
/// and this never opens a device), and is cached briefly like the other
/// probes.
public final class GCControllerMonitor: ControllerMonitoring {
    private let steamHardware: TTLCache<Int>

    public convenience init() {
        self.init(steamProbe: SteamControllerHID.probeSystem)
    }

    /// The probe and clock are injectable so the cache can be unit-tested.
    init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        steamProbe: @escaping () -> Int
    ) {
        steamHardware = TTLCache(ttl: ttl, now: now, probe: steamProbe)
    }

    public var connectedCount: Int {
        // The two sources never overlap: the framework refuses Valve
        // hardware, and the sweep matches only Valve's vendor id.
        GCController.controllers().count + steamHardware.current
    }
}

/// Permission-free detection of Steam Controller hardware (wired, dongle, or
/// the Steam Controller puck) at the HID layer.
enum SteamControllerHID {
    /// Valve's USB vendor id.
    static let valveVendorID = 0x28DE

    /// Count physical Valve devices currently attached.
    static func probeSystem() -> Int {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: valveVendorID] as CFDictionary)
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return 0 }
        return distinctHardwareCount(devices: devices.map { device in
            (
                transport: IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
                location: IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int
            )
        })
    }

    /// Pure dedup over the enumeration: one physical device fans out into
    /// several HID interfaces (the puck shows four) plus virtual
    /// keyboard/mouse children from lizard mode. Virtual entries are ignored
    /// outright (they can outlive the hardware), and the rest collapse to
    /// distinct location ids, or one device when locations are missing.
    static func distinctHardwareCount(devices: [(transport: String?, location: Int?)]) -> Int {
        let physical = devices.filter { ($0.transport ?? "") != "Virtual" }
        guard !physical.isEmpty else { return 0 }
        let locations = Set(physical.compactMap(\.location)).subtracting([0])
        return locations.isEmpty ? 1 : locations.count
    }
}

// MARK: - Trigger

/// Fires while at least one game controller is connected. Deliberately
/// parameterless: unlike Bluetooth audio devices, people rarely need to
/// distinguish which controller means "keep awake".
public final class ControllerTrigger: Trigger {
    /// Short grace, matching ``BluetoothDeviceTrigger/releaseGrace``: a
    /// controller briefly rebonding (battery dip, host switch) must not drop
    /// the session.
    public static let releaseGrace: TimeInterval = 30

    private let monitor: ControllerMonitoring

    public init(monitor: ControllerMonitoring = GCControllerMonitor()) {
        self.monitor = monitor
    }

    public var label: String { L("Game controller connected") }

    public func isSatisfied() -> Bool {
        monitor.connectedCount > 0
    }
}

// MARK: - Controller activity poke

/// Declares user activity while someone plays with a controller, because
/// gamepad input does not reliably reset the HID idle timer: a controller-only
/// session can dim or sleep the display mid-game even while Keepresso holds
/// the system awake. Pure policy over injected effects, driven by the app's
/// 1 Hz tick like everything else.
@MainActor
public final class ControllerActivityPoker {
    /// The Setup screen's toggle. Off by default: poking resets the idle
    /// timer, which also defeats the screen-saver yield, so it stays opt-in.
    public var enabled = false

    /// Matches ``SessionController/activityPokeInterval``: often enough that
    /// no dim threshold can pass, rare enough to cost nothing.
    public static let pokeInterval: TimeInterval = 30

    private let activity: ActivitySimulating
    private let now: () -> Date
    private var lastPokeAt: Date?

    public init(
        activity: ActivitySimulating = IOKitActivitySimulator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.activity = activity
        self.now = now
    }

    /// One pulse: pokes when the feature is on, a game is being played, a
    /// controller is connected, and a keep-awake session is actually active
    /// (an idle Keepresso must not keep the display lit on its own).
    public func tick(gamingActive: Bool, controllerConnected: Bool, sessionActive: Bool) {
        guard enabled, gamingActive, controllerConnected, sessionActive else {
            lastPokeAt = nil
            return
        }
        let instant = now()
        if let last = lastPokeAt, instant.timeIntervalSince(last) < Self.pokeInterval {
            return
        }
        lastPokeAt = instant
        activity.poke()
    }
}
