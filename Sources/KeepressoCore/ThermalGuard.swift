import Foundation

/// User configuration for the thermal safety net: which signal to watch, how
/// long it must stay hot, and what to do about it. `nil` in settings means the
/// whole feature is off.
public struct ThermalSafetyConfig: Codable, Equatable, Sendable {
    /// The watched signal.
    public enum Mode: Codable, Equatable, Sendable {
        /// Simple: macOS's own thermal pressure at or above this level. Public
        /// API, works on every Mac, the default.
        case pressure(atOrAbove: ThermalPressureLevel)
        /// Advanced: any of the selected sensors at or above this many °C.
        case sensors(ids: [String], celsius: Double)
    }

    public var mode: Mode
    /// The reading must hold at or over the threshold this long before the
    /// first stage fires (and, still hot, this long again before the second).
    public var sustainSeconds: TimeInterval
    /// Stage 1: boost fans to this percent of their range. `nil` = stage off.
    public var fanBoostPercent: Int?
    /// Stage 2: force-stop the keep-awake session and refuse restarts while hot.
    public var stopBrewing: Bool
    /// With stage 2, also switch off closed-display mode (pmset disablesleep),
    /// prompt-free through the helper only; skipped (and said so) without it.
    public var liftSleepDisable: Bool

    public init(
        mode: Mode = .pressure(atOrAbove: .serious),
        sustainSeconds: TimeInterval = ThermalSafetyConfig.defaultSustainSeconds,
        fanBoostPercent: Int? = nil,
        stopBrewing: Bool = true,
        liftSleepDisable: Bool = false
    ) {
        self.mode = Self.clamped(mode)
        self.sustainSeconds = Self.clampedSustain(sustainSeconds)
        self.fanBoostPercent = fanBoostPercent.map(Self.clampedBoostPercent)
        self.stopBrewing = stopBrewing
        self.liftSleepDisable = liftSleepDisable
    }

    /// Forgiving decode with the same clamps as the memberwise init, so a
    /// hand-edited or imported blob can't smuggle in a 20 °C cutoff.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .pressure(atOrAbove: .serious)
        self.init(
            mode: mode,
            sustainSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .sustainSeconds)
                ?? Self.defaultSustainSeconds,
            fanBoostPercent: try c.decodeIfPresent(Int.self, forKey: .fanBoostPercent),
            stopBrewing: try c.decodeIfPresent(Bool.self, forKey: .stopBrewing) ?? true,
            liftSleepDisable: try c.decodeIfPresent(Bool.self, forKey: .liftSleepDisable) ?? false
        )
    }

    public static let defaultSustainSeconds: TimeInterval = 30
    public static let sustainRange: ClosedRange<TimeInterval> = 5...600
    public static let celsiusRange: ClosedRange<Double> = 60...110
    public static let boostPercentRange: ClosedRange<Int> = 30...100

    /// Resume dead-band for sensor mode: readings must drop this far below the
    /// threshold (and stay there for the sustain window) before anything
    /// releases, so a die hovering at the cutoff doesn't flap. Pressure mode
    /// needs no margin constant: one level below the trigger is the band.
    public static let sensorResumeMarginCelsius: Double = 5

    static func clampedSustain(_ raw: TimeInterval) -> TimeInterval {
        min(max(raw, sustainRange.lowerBound), sustainRange.upperBound)
    }

    static func clampedBoostPercent(_ raw: Int) -> Int {
        min(max(raw, boostPercentRange.lowerBound), boostPercentRange.upperBound)
    }

    static func clamped(_ mode: Mode) -> Mode {
        switch mode {
        case .pressure:
            return mode
        case .sensors(let ids, let celsius):
            return .sensors(
                ids: ids,
                celsius: min(max(celsius, celsiusRange.lowerBound), celsiusRange.upperBound)
            )
        }
    }
}

/// One 1 Hz observation handed to the guard, already reduced to the hottest
/// relevant value. The caller passes `nil` when the read path failed, which
/// freezes the guard: an unknown reading never releases a safety measure.
public enum ThermalSample: Equatable, Sendable {
    case pressure(ThermalPressureLevel)
    /// The hottest currently-selected sensor, °C.
    case celsius(max: Double)
}

/// What the guard wants done, in order. The host (AppModel) translates these
/// into helper calls, the session latch, and notifications.
public enum ThermalEffect: Equatable, Sendable {
    case boostFans(percent: Int)
    case restoreFans
    case pauseBrewing
    case resumeBrewing
}

/// The guard's memory between 1 Hz steps.
public struct ThermalGuardState: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case clear
        case fansBoosted
        case stopped
    }

    public var stage: Stage = .clear
    /// Consecutive seconds at or over the threshold.
    public var overSeconds = 0
    /// Consecutive seconds clearly under it (past the resume margin).
    public var underSeconds = 0

    public init() {}
}

/// The escalation state machine, as a pure function over 1 Hz samples so tests
/// script readings directly (mirrors ``CPULoadTrigger/step(_:sample:thresholdPercent:)``,
/// counter-based instead of clock-based because the host ticks exactly once a
/// second, like the battery reading).
///
/// Stage ladder:
/// - over threshold for the sustain window → stage 1, boost fans (or straight
///   to stage 2 when fan boost is off or unavailable)
/// - still over for another sustain window → stage 2, pause brewing (fans stay
///   boosted: cooling remains the goal while stopped)
/// - clearly under (sensor margin, or any lower pressure level) for a sustain
///   window → restore fans, release the pause
/// - a `nil` sample freezes counters and stage: no verdict, no release.
public enum ThermalGuard {
    public static func step(
        _ state: ThermalGuardState,
        sample: ThermalSample?,
        config: ThermalSafetyConfig
    ) -> (state: ThermalGuardState, effects: [ThermalEffect]) {
        guard let sample else { return (state, []) }
        var next = state
        next.overSeconds = isOver(sample, config: config) ? state.overSeconds + 1 : 0
        next.underSeconds = isClearlyUnder(sample, config: config) ? state.underSeconds + 1 : 0
        let dwell = max(1, Int(config.sustainSeconds))

        var effects: [ThermalEffect] = []
        switch state.stage {
        case .clear where next.overSeconds >= dwell:
            if let percent = config.fanBoostPercent {
                next.stage = .fansBoosted
                next.overSeconds = 0 // the stage-2 dwell starts fresh
                effects.append(.boostFans(percent: percent))
            } else if config.stopBrewing {
                next.stage = .stopped
                effects.append(.pauseBrewing)
            } else {
                // Nothing enabled to escalate to; stay clear but keep counting,
                // so enabling an action mid-heat reacts on the next dwell.
                next.overSeconds = 0
            }
        case .fansBoosted where config.stopBrewing && next.overSeconds >= dwell:
            next.stage = .stopped
            effects.append(.pauseBrewing)
        case .fansBoosted where next.underSeconds >= dwell:
            next.stage = .clear
            effects.append(.restoreFans)
        case .stopped where next.underSeconds >= dwell:
            next.stage = .clear
            effects.append(.restoreFans) // no-op downstream if fans never boosted
            effects.append(.resumeBrewing)
        default:
            break
        }
        return (next, effects)
    }

    static func isOver(_ sample: ThermalSample, config: ThermalSafetyConfig) -> Bool {
        switch (sample, config.mode) {
        case (.pressure(let level), .pressure(let trigger)):
            return level >= trigger
        case (.celsius(let max), .sensors(_, let threshold)):
            return max >= threshold
        default:
            return false // mismatched sample kind: treat as no verdict on "over"
        }
    }

    static func isClearlyUnder(_ sample: ThermalSample, config: ThermalSafetyConfig) -> Bool {
        switch (sample, config.mode) {
        case (.pressure(let level), .pressure(let trigger)):
            return level < trigger
        case (.celsius(let max), .sensors(_, let threshold)):
            return max <= threshold - ThermalSafetyConfig.sensorResumeMarginCelsius
        default:
            return false
        }
    }
}

/// Owns the live guard: samples the configured signal once per host tick, runs
/// the pure step, and hands the effects back for the app to act on. Also the
/// menu's and Preferences' source for live thermal display values.
@MainActor
@Observable
public final class ThermalGuardController {
    /// The user's configuration; `nil` = feature off. Changing it resets the
    /// state machine, first emitting the releases a latched state would
    /// otherwise strand (boosted fans, a paused session).
    public var config: ThermalSafetyConfig? {
        didSet {
            guard config != oldValue else { return }
            // Appended, not assigned: back-to-back config changes must not
            // drop a release queued by the previous one.
            pendingReleases += releaseEffects(for: state.stage)
            state = ThermalGuardState()
            lastSampleFailed = false
        }
    }

    public private(set) var state = ThermalGuardState()
    /// The most recent reading, for live UI (menu status line, sensor picker).
    public private(set) var currentCelsius: Double?
    public private(set) var currentLevel: ThermalPressureLevel?
    /// True when the last tick could not produce a sample in sensor mode, so
    /// the UI can flag "selected sensors unavailable".
    public private(set) var lastSampleFailed = false

    private let pressure: ThermalPressureReading
    private let sensors: ThermalSensorReading
    private var pendingReleases: [ThermalEffect] = []

    public init(
        pressure: ThermalPressureReading = NullThermalPressure(),
        sensors: ThermalSensorReading = NullThermalSensors()
    ) {
        self.pressure = pressure
        self.sensors = sensors
    }

    /// Every sensor this machine offers, for the Preferences picker.
    public func discoverSensors() -> [ThermalSensor] {
        sensors.discoverSensors()
    }

    /// Live per-sensor readings for the picker's °C column.
    public func liveReadings(ids: [String]) -> [String: Double] {
        sensors.readCelsius(ids: ids) ?? [:]
    }

    /// One 1 Hz step. Cheap when off (a nil check); pressure mode reads a
    /// push-updated value, sensor mode reads through the backend's TTL cache.
    /// Pending releases flush even while off, so disabling the feature
    /// mid-emergency restores fans and the session on the very next tick.
    public func tick() -> [ThermalEffect] {
        var effects = pendingReleases
        pendingReleases = []
        guard let config else { return effects }
        let sample = sample(for: config.mode)
        let (next, stepEffects) = ThermalGuard.step(state, sample: sample, config: config)
        state = next
        effects.append(contentsOf: stepEffects)
        return effects
    }

    /// The three-way verdict ``SessionController`` latches on. `.hot` only in
    /// the stopped stage; `.unknown` while off (leave whatever latch exists
    /// alone) or while a stopped guard can't read its signal.
    public var readingForSession: ThermalReading {
        guard config != nil else { return .unknown }
        switch state.stage {
        case .stopped:
            return lastSampleFailed ? .unknown : .hot
        case .clear, .fansBoosted:
            return .clear
        }
    }

    private func sample(for mode: ThermalSafetyConfig.Mode) -> ThermalSample? {
        switch mode {
        case .pressure:
            currentLevel = pressure.current
            lastSampleFailed = currentLevel == nil
            return currentLevel.map { .pressure($0) }
        case .sensors(let ids, _):
            let readings = sensors.readCelsius(ids: ids)
            currentCelsius = readings?.values.max()
            lastSampleFailed = currentCelsius == nil
            return currentCelsius.map { .celsius(max: $0) }
        }
    }

    private func releaseEffects(for stage: ThermalGuardState.Stage) -> [ThermalEffect] {
        switch stage {
        case .clear: return []
        case .fansBoosted: return [.restoreFans]
        case .stopped: return [.restoreFans, .resumeBrewing]
        }
    }
}
