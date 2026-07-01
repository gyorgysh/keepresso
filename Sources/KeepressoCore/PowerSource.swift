import Foundation
import IOKit.ps

/// A point-in-time reading of the Mac's power situation.
///
/// Deliberately small and value-typed so triggers can be evaluated as pure
/// functions of a snapshot in tests.
public struct PowerSourceSnapshot: Equatable, Sendable {
    /// What is currently powering the machine.
    public enum Provider: String, Codable, Sendable {
        /// Running on wall/AC power (or any external adapter).
        case ac
        /// Running on the internal battery.
        case battery
        /// Couldn't be determined (rare; treated as "neither").
        case unknown
    }

    /// The power source currently providing power to the system.
    public var provider: Provider

    /// Whether an internal battery is present *and* actively charging.
    public var isCharging: Bool

    /// Whether the machine reports any battery at all (false on most desktops).
    public var hasBattery: Bool

    /// Current charge as a percentage of full capacity (0–100), or `nil` when
    /// ``hasBattery`` is false or the reading isn't available.
    public var percentage: Int?

    public init(provider: Provider, isCharging: Bool, hasBattery: Bool, percentage: Int? = nil) {
        self.provider = provider
        self.isCharging = isCharging
        self.hasBattery = hasBattery
        self.percentage = percentage
    }
}

/// Abstraction over the IOKit power-source API (`IOPowerSources`) so trigger
/// logic can be unit-tested without real hardware state.
///
/// Mirrors the ``PowerAsserting`` seam: ``IOKitPowerSourceMonitor`` is the real
/// backend; tests inject a fake that returns canned snapshots.
public protocol PowerSourceMonitoring: AnyObject {
    /// The power situation right now. Reading is cheap; callers may poll it.
    var current: PowerSourceSnapshot { get }
}

/// Real implementation backed by `IOPSCopyPowerSourcesInfo` & friends.
///
/// Not thread-safe by design — read it from the main actor alongside the
/// owning controller, the same way ``IOKitPowerAssertionManager`` is used.
public final class IOKitPowerSourceMonitor: PowerSourceMonitoring {
    public init() {}

    public var current: PowerSourceSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSourceSnapshot(provider: .unknown, isCharging: false, hasBattery: false)
        }

        // System-wide provider (AC vs battery), independent of how many sources
        // are attached.
        let provider: PowerSourceSnapshot.Provider
        switch IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
        case kIOPSACPowerValue: provider = .ac
        case kIOPSBatteryPowerValue: provider = .battery
        default: provider = .unknown
        }

        // Walk the individual sources to learn about the battery, if any.
        var hasBattery = false
        var isCharging = false
        var percentage: Int?
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            hasBattery = true
            if let charging = desc[kIOPSIsChargingKey] as? Bool, charging {
                isCharging = true
            }
            if let current = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percentage = Int((Double(current) / Double(max) * 100).rounded())
            }
        }

        return PowerSourceSnapshot(
            provider: provider, isCharging: isCharging, hasBattery: hasBattery, percentage: percentage
        )
    }
}
