import Foundation
import IOBluetooth

/// A point-in-time reading of the paired Bluetooth devices.
public struct BluetoothSnapshot: Equatable, Sendable {
    /// Names of every paired device, connected or not (for the rules picker).
    public var pairedDeviceNames: [String]
    /// Names of the paired devices currently connected.
    public var connectedDeviceNames: [String]

    public init(pairedDeviceNames: [String] = [], connectedDeviceNames: [String] = []) {
        self.pairedDeviceNames = pairedDeviceNames
        self.connectedDeviceNames = connectedDeviceNames
    }
}

/// Abstraction over the paired-device list so Bluetooth triggers can be tested
/// without a radio. Mirrors the other monitor seams.
public protocol BluetoothMonitoring: AnyObject {
    var current: BluetoothSnapshot { get }
}

/// Real backend over IOBluetooth's paired-device registry.
///
/// `IOBluetoothDevice.pairedDevices()` enumerates the pairing registry, which
/// is heavier than a HAL property read, so readings are cached briefly
/// (mirroring ``CoreMediaActivityMonitor``); connection state doesn't flip
/// fast enough for a short cache to matter. On modern macOS the enumeration is
/// TCC-gated (Bluetooth privacy), so the app requests access before offering
/// Bluetooth rules and surfaces the grant in the Setup screen.
public final class IOBluetoothDeviceMonitor: BluetoothMonitoring {
    private let cache: TTLCache<BluetoothSnapshot>

    public convenience init() {
        self.init(probe: Self.probeSystem)
    }

    /// The probe and clock are injectable so the cache can be unit-tested
    /// without paired hardware.
    init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        probe: @escaping () -> BluetoothSnapshot
    ) {
        cache = TTLCache(ttl: ttl, now: now, probe: probe)
    }

    public var current: BluetoothSnapshot { cache.current }

    /// The real probe: sweep the pairing registry once.
    static func probeSystem() -> BluetoothSnapshot {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var paired: [String] = []
        var connected: [String] = []
        for device in devices {
            guard let name = device.name, !name.isEmpty else { continue }
            paired.append(name)
            if device.isConnected() { connected.append(name) }
        }
        return BluetoothSnapshot(pairedDeviceNames: paired, connectedDeviceNames: connected)
    }
}

/// Fires while a specific paired Bluetooth device is connected: headphones on
/// means someone is listening, a controller on means someone is playing.
public final class BluetoothDeviceTrigger: Trigger {
    /// Grace applied by the factory: headphones and headsets drop for a few
    /// seconds when switching hosts or re-pairing, and that blip shouldn't
    /// flap the session (mirrors ``AudioPlayingTrigger/releaseGrace``).
    public static let releaseGrace: TimeInterval = 30

    /// The device name to match, compared case-insensitively (names come from
    /// the paired-device picker, but pairing UIs vary their casing).
    public var deviceName: String
    private let monitor: BluetoothMonitoring

    public init(deviceName: String, monitor: BluetoothMonitoring = IOBluetoothDeviceMonitor()) {
        self.deviceName = deviceName
        self.monitor = monitor
    }

    public var label: String { L("Bluetooth \u{201C}%@\u{201D} connected", deviceName) }

    public func isSatisfied() -> Bool {
        monitor.current.connectedDeviceNames.contains {
            $0.caseInsensitiveCompare(deviceName) == .orderedSame
        }
    }
}
