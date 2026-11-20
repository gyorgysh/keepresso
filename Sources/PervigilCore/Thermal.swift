import Foundation

/// macOS thermal pressure, ordered so "at or above serious" reads as a plain
/// comparison. Mirrors `ProcessInfo.ThermalState`; the app-side backend also
/// folds the finer five-level Darwin notification into these four (its extra
/// "heavy" level maps to ``serious``).
public enum ThermalPressureLevel: Int, Codable, Comparable, Sendable, CaseIterable {
    case nominal = 0
    case fair
    case serious
    case critical

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The user-facing name of the level.
    public var label: String {
        switch self {
        case .nominal: return L("Nominal")
        case .fair: return L("Fair")
        case .serious: return L("Serious")
        case .critical: return L("Critical")
        }
    }
}

/// One discoverable temperature sensor. ``id`` is the stable key persisted in
/// settings: the HID service's Product string on Apple Silicon, the
/// four-character SMC key (like "TC0P") on Intel. Never invent or substitute
/// ids; a persisted id that stops resolving must read as unavailable, not as
/// some other sensor.
public struct ThermalSensor: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    /// Display label; on most machines the id is already the best name there is.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The guard's verdict as ``SessionController`` consumes it, dwell and
/// hysteresis already applied. Mirrors ``SessionController/BatteryReading``'s
/// three-way shape: `.unknown` means "no verdict this tick" and must leave any
/// existing pause latch exactly as it is.
public enum ThermalReading: Equatable, Sendable {
    case hot
    case clear
    case unknown
}

/// Coarse system thermal pressure. The real backend (app-side) is push-updated
/// from `ProcessInfo` and the thermal-pressure Darwin notification, so reads
/// are free; `nil` means no reading has arrived yet.
public protocol ThermalPressureReading: AnyObject {
    var current: ThermalPressureLevel? { get }
}

/// Temperature-sensor discovery and reads. The real backend lives in the app
/// (private IOHIDEventSystemClient on Apple Silicon) or in Core's SMC reader
/// (Intel); both are unprivileged.
public protocol ThermalSensorReading: AnyObject {
    /// Every temperature sensor on this machine, or `[]` when the read path is
    /// unsupported here (the UI then offers pressure mode only).
    func discoverSensors() -> [ThermalSensor]

    /// Current readings in degrees Celsius for the requested ids. Ids that no
    /// longer resolve are simply absent from the result. `nil` means the read
    /// path itself failed this call; callers treat that as "no verdict" and
    /// hold their state, never as "cool".
    func readCelsius(ids: [String]) -> [String: Double]?
}

/// Fan presence and state, for gating and describing the fan-boost feature.
/// Reads only; forcing fans is the privileged ``FanControlling`` seam.
public protocol FanInfoReading: AnyObject {
    /// Number of fans, `nil` when unknown (SMC unreachable). 0 means fanless
    /// (MacBook Air): the fan UI hides entirely.
    func fanCount() -> Int?

    /// Current speed of the first fan in RPM, best effort, for status lines.
    func currentRPM() -> Double?

    /// Current speed of one fan in RPM, `nil` when unreadable.
    func rpm(ofFan index: Int) -> Double?

    /// The fan's reported minimum and maximum RPM, `nil` when unreadable or
    /// nonsensical (max not above min).
    func rpmRange(ofFan index: Int) -> (min: Double, max: Double)?
}

/// Default backends for tests and for platforms where a read path is absent.
public final class NullThermalPressure: ThermalPressureReading {
    public init() {}
    public var current: ThermalPressureLevel? { nil }
}

public final class NullThermalSensors: ThermalSensorReading {
    public init() {}
    public func discoverSensors() -> [ThermalSensor] { [] }
    public func readCelsius(ids: [String]) -> [String: Double]? { nil }
}

public final class NullFanInfo: FanInfoReading {
    public init() {}
    public func fanCount() -> Int? { nil }
    public func currentRPM() -> Double? { nil }
    public func rpm(ofFan index: Int) -> Double? { nil }
    public func rpmRange(ofFan index: Int) -> (min: Double, max: Double)? { nil }
}
