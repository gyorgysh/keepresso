import Foundation

/// A live condition that, when satisfied, wants the keep-awake session ON.
///
/// This is the seam the v0.2 trigger engine is built on: an evaluation loop
/// polls the registered triggers and feeds the combined result into
/// ``SessionController``. Each concrete trigger reads its own system state
/// through an injected monitor protocol (mirroring ``PowerAsserting``), so the
/// decision logic stays a pure, testable function of that state.
public protocol Trigger: AnyObject {
    /// A stable, human-readable description (for the rules UI and diagnostics).
    var label: String { get }

    /// Whether the condition currently holds. Cheap and side-effect-free;
    /// the engine may call it every tick.
    func isSatisfied() -> Bool
}

/// Something that produces a single live on/off signal — the abstraction the
/// ``SessionController`` gates on. A lone ``Trigger`` is one; a ``TriggerEngine``
/// combining several is another. Kept separate from ``Trigger`` so the
/// controller need not know how the decision is composed.
public protocol TriggerEvaluating: AnyObject {
    /// Whether the combined condition currently wants the session ON.
    func isSatisfied() -> Bool
}

/// Fires based on how the Mac is being powered (`IOPowerSources`).
public final class PowerSourceTrigger: Trigger {
    /// Which power situation should satisfy this trigger.
    public enum Match: String, Codable, Sendable, CaseIterable {
        /// Plugged into AC / an external adapter.
        case onACPower
        /// Running on the internal battery.
        case onBattery
        /// Battery present and actively charging (a subset of ``onACPower``).
        case charging

        var label: String {
            switch self {
            case .onACPower: return "On AC power"
            case .onBattery: return "On battery"
            case .charging:  return "Charging"
            }
        }
    }

    /// The power situation this trigger watches for.
    public var match: Match

    private let monitor: PowerSourceMonitoring

    public init(match: Match, monitor: PowerSourceMonitoring = IOKitPowerSourceMonitor()) {
        self.match = match
        self.monitor = monitor
    }

    public var label: String { match.label }

    public func isSatisfied() -> Bool {
        Self.evaluate(match, against: monitor.current)
    }

    /// Pure decision function — exposed for direct unit testing.
    static func evaluate(_ match: Match, against snapshot: PowerSourceSnapshot) -> Bool {
        switch match {
        case .onACPower: return snapshot.provider == .ac
        case .onBattery: return snapshot.provider == .battery
        case .charging:  return snapshot.isCharging
        }
    }
}

/// Fires while at least one external display is connected (`CoreGraphics`).
public final class ExternalDisplayTrigger: Trigger {
    private let monitor: DisplayMonitoring

    public init(monitor: DisplayMonitoring = CoreGraphicsDisplayMonitor()) {
        self.monitor = monitor
    }

    public var label: String { "External display connected" }

    public func isSatisfied() -> Bool { monitor.current.hasExternalDisplay }
}

/// Fires while joined to a specific Wi-Fi network (`CoreWLAN`).
public final class WiFiSSIDTrigger: Trigger {
    /// The SSID to match. Comparison is exact (SSIDs are case-sensitive).
    public var ssid: String

    private let monitor: NetworkMonitoring

    public init(ssid: String, monitor: NetworkMonitoring = CoreWLANNetworkMonitor()) {
        self.ssid = ssid
        self.monitor = monitor
    }

    public var label: String { "On Wi-Fi \u{201C}\(ssid)\u{201D}" }

    public func isSatisfied() -> Bool {
        guard let current = monitor.current.ssid else { return false }
        return current == ssid
    }
}

/// How an ``AppTrigger`` matches a target app.
public enum AppMatch: String, Codable, Sendable, CaseIterable {
    /// The app is running anywhere (background included).
    case running
    /// The app is the frontmost (active) app.
    case frontmost

    var label: String {
        switch self {
        case .running:   return "is running"
        case .frontmost: return "is frontmost"
        }
    }
}

/// Fires while a specific app (by bundle identifier) is running or frontmost
/// (`NSWorkspace`).
public final class AppTrigger: Trigger {
    /// The bundle identifier to watch for, e.g. `com.apple.FaceTime`.
    public var bundleID: String
    /// Whether to match the app merely running, or being frontmost.
    public var match: AppMatch

    private let monitor: WorkspaceMonitoring

    public init(
        bundleID: String,
        match: AppMatch = .running,
        monitor: WorkspaceMonitoring = NSWorkspaceMonitor()
    ) {
        self.bundleID = bundleID
        self.match = match
        self.monitor = monitor
    }

    public var label: String { "App \(bundleID) \(match.label)" }

    public func isSatisfied() -> Bool {
        let snapshot = monitor.current
        switch match {
        case .running:   return snapshot.runningBundleIDs.contains(bundleID)
        case .frontmost: return snapshot.frontmostBundleID == bundleID
        }
    }
}

/// Fires while any running process's command line contains a query string,
/// matched case-insensitively (`ps`). Catches command-line tools and background
/// jobs that ``AppTrigger`` can't see, e.g. `node`, `python`, `ffmpeg`, `claude`.
public final class ProcessTrigger: Trigger {
    /// The substring to look for in each process's command line (e.g. "node").
    public var query: String

    private let monitor: ProcessListing

    public init(query: String, monitor: ProcessListing = PSProcessLister()) {
        self.query = query
        self.monitor = monitor
    }

    public var label: String { "Process \u{201C}\(query)\u{201D} running" }

    public func isSatisfied() -> Bool {
        Self.matches(query, in: monitor.current)
    }

    /// Pure decision function — exposed for direct unit testing. An empty query
    /// never matches (so a half-typed rule doesn't pin the Mac awake).
    static func matches(_ query: String, in processes: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        return processes.contains { $0.lowercased().contains(needle) }
    }
}

/// Wraps another trigger and keeps reporting satisfied for `grace` seconds after
/// the wrapped condition goes false — the "linger before deactivating" of v0.3.
///
/// Time-aware by necessity: unlike the stateless conditions, ``isSatisfied()``
/// records when it last saw the wrapped trigger true (the engine polls it every
/// reconcile, which is the tick that advances the window). A non-positive grace
/// makes it a transparent pass-through.
public final class GracePeriodTrigger: Trigger {
    private let wrapped: Trigger
    private let grace: TimeInterval
    private let now: () -> Date
    private var lastSatisfiedAt: Date?

    public init(wrapping wrapped: Trigger, grace: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.wrapped = wrapped
        self.grace = grace
        self.now = now
    }

    public var label: String { wrapped.label }

    public func isSatisfied() -> Bool {
        if wrapped.isSatisfied() {
            lastSatisfiedAt = now()
            return true
        }
        guard grace > 0, let last = lastSatisfiedAt else { return false }
        return now().timeIntervalSince(last) < grace
    }
}

/// How a rule set combines its triggers into a single on/off decision.
public enum CombineMode: String, Codable, Sendable, CaseIterable {
    /// OR — satisfied when *any* trigger fires. The default.
    case any
    /// AND — satisfied only when *every* trigger fires.
    case all
}

/// Combines a set of triggers into one live on/off signal — the seam the
/// ``SessionController`` gates on when running in trigger-driven mode.
///
/// An empty engine is never satisfied, so enabling trigger gating with no
/// rules configured leaves the Mac free to sleep rather than holding it awake.
public final class TriggerEngine: TriggerEvaluating {
    /// How ``triggers`` are combined. Mutable so the UI can flip OR/AND live.
    public var combine: CombineMode

    /// The conditions in this rule set.
    public private(set) var triggers: [Trigger]

    public init(combine: CombineMode = .any, triggers: [Trigger] = []) {
        self.combine = combine
        self.triggers = triggers
    }

    public func add(_ trigger: Trigger) { triggers.append(trigger) }

    public func removeAll() { triggers.removeAll() }

    public func isSatisfied() -> Bool {
        guard !triggers.isEmpty else { return false }
        switch combine {
        case .any: return triggers.contains { $0.isSatisfied() }
        case .all: return triggers.allSatisfy { $0.isSatisfied() }
        }
    }
}
