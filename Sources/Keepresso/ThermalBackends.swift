import Foundation
import KeepressoCore

/// The live thermal-pressure level, push-updated so reads are free. Backed by
/// the public `ProcessInfo.thermalState` and refined, where the key exists, by
/// the finer five-level `com.apple.system.thermalpressurelevel` Darwin
/// notification (its extra "heavy" level maps to ``ThermalPressureLevel/serious``,
/// which is where throttling actually bites).
final class SystemThermalPressure: ThermalPressureReading {
    private var level: ThermalPressureLevel?
    private var notifyToken: Int32 = -1
    private var observer: NSObjectProtocol?
    private let lock = NSLock()

    init() {
        update()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.update() }
        // The Darwin notification delivers intermediate transitions faster
        // than ProcessInfo; registration failing (the key vanishing in some
        // future macOS) just leaves the ProcessInfo path.
        let status = notify_register_dispatch(
            "com.apple.system.thermalpressurelevel", &notifyToken, .main
        ) { [weak self] _ in self?.update() }
        if status != NOTIFY_STATUS_OK { notifyToken = -1 }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if notifyToken >= 0 { notify_cancel(notifyToken) }
    }

    var current: ThermalPressureLevel? {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    private func update() {
        let mapped: ThermalPressureLevel
        if notifyToken >= 0 {
            var state: UInt64 = 0
            if notify_get_state(notifyToken, &state) == NOTIFY_STATUS_OK {
                // kOSThermalPressureLevel: 0 nominal, 1 moderate, 2 heavy,
                // 3 trapping, 4 sleeping. Heavy is where throttling really
                // starts, so it maps to serious; trapping and beyond are
                // critical territory.
                switch state {
                case 0: mapped = .nominal
                case 1: mapped = .fair
                case 2: mapped = .serious
                default: mapped = .critical
                }
                lock.lock(); level = mapped; lock.unlock()
                return
            }
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: mapped = .nominal
        case .fair: mapped = .fair
        case .serious: mapped = .serious
        case .critical: mapped = .critical
        @unknown default: mapped = .critical // fail hot, never cool
        }
        lock.lock(); level = mapped; lock.unlock()
    }
}

/// Temperature sensors for this machine: the private HID path (Apple Silicon,
/// real sensor names) when it yields anything, otherwise Core's SMC key reads
/// (Intel). Readings go through a 1 s TTL cache: the guard tick and the
/// Preferences picker's live column read within the same second.
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
