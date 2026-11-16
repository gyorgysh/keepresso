import Foundation
import KeepressoCore

/// Reads the public macOS thermal pressure scale.
final class SystemThermalPressure: ThermalPressureReading {
    var current: ThermalPressureLevel? { Self.publicPressure() }

    static func publicPressure() -> ThermalPressureLevel? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil // an unknown reading must not release the cutoff
        }
    }
}

/// Temperature sensors for this machine: the private HID path (Apple Silicon,
/// real sensor names) when it yields anything, otherwise Core's SMC key reads
/// (Intel). The supervised fan diagnostic uses these readings separately
/// from the automatic thermal guard.
final class MachineThermalSensors: ThermalSensorReading {
    private let smcFallback = SMCThermalSensors()
    private lazy var cache = TTLCache<[String: Double]?>(ttl: 1.0) {
        Self.readAll()
    }

    /// One full HID sweep, or nil when the API is gone. Sensor discovery and
    /// value reads are the same call, so the cache holds the whole dictionary.
    private static func readAll() -> [String: Double]? {
        guard let readings = KPHIDTemperatureReadings() else { return nil }
        return readings.reduce(into: [:]) { result, entry in
            let value = entry.value.doubleValue
            // The HID list includes unpopulated slots reading 0 or absurd
            // values; the same plausibility band the SMC path uses.
            if SMCThermalSensors.isPlausibleCelsius(value) {
                result[entry.key] = value
            }
        }
    }

    func discoverSensors() -> [ThermalSensor] {
        if let readings = cache.current, !readings.isEmpty {
            return readings.keys.sorted().map { ThermalSensor(id: $0, name: $0) }
        }
        return smcFallback.discoverSensors()
    }

    func readCelsius(ids: [String]) -> [String: Double]? {
        guard !ids.isEmpty else { return nil }
        if let readings = cache.current, !readings.isEmpty {
            return readings.filter { ids.contains($0.key) }
        }
        return smcFallback.readCelsius(ids: ids)
    }
}
