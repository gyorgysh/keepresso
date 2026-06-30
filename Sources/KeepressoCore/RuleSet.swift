import Foundation

/// A serializable description of a single trigger condition.
///
/// Triggers themselves are live objects bound to system monitors, so they can't
/// be persisted directly. A `TriggerRule` is the saved, value-typed form; the
/// ``TriggerFactory`` rebuilds live ``Trigger``s from rules at launch.
public enum TriggerRule: Codable, Equatable, Hashable, Sendable {
    /// On AC / on battery / charging (see ``PowerSourceTrigger/Match``).
    case powerSource(PowerSourceTrigger.Match)
    /// At least one external display connected.
    case externalDisplay
    /// Joined to this exact Wi-Fi SSID.
    case wifiSSID(String)
    /// An app is running / frontmost, optionally with a deactivation grace.
    case app(AppRule)
    /// Any process whose command line contains this string is running
    /// (matches command-line tools and background jobs, not just GUI apps).
    case process(String)

    /// A human-readable summary for the rules UI.
    public var label: String {
        switch self {
        case .powerSource(let match): return match.label
        case .externalDisplay:        return "External display connected"
        case .wifiSSID(let ssid):     return "On Wi-Fi \u{201C}\(ssid)\u{201D}"
        case .app(let rule):          return rule.label
        case .process(let query):     return "Process \u{201C}\(query)\u{201D} running"
        }
    }
}

/// A persisted "caffeinating app" rule: which app, how it's matched, and how
/// long to linger after it stops matching.
public struct AppRule: Codable, Equatable, Hashable, Sendable {
    /// Bundle identifier, e.g. `com.apple.FaceTime`.
    public var bundleID: String
    /// Running vs frontmost.
    public var match: AppMatch
    /// Seconds to stay active after the app stops matching (0 = no grace).
    public var grace: TimeInterval

    public init(bundleID: String, match: AppMatch = .running, grace: TimeInterval = 0) {
        self.bundleID = bundleID
        self.match = match
        self.grace = grace
    }

    public var label: String {
        let base = "App \(bundleID) \(match.label)"
        return grace > 0 ? base + " (+\(Int(grace))s)" : base
    }
}

/// A named set of trigger rules plus how they combine — the persisted shape of
/// a trigger configuration.
public struct RuleSet: Codable, Equatable, Sendable {
    /// OR (any) or AND (all). Defaults to OR.
    public var combine: CombineMode
    /// The conditions in this set, in display order.
    public var rules: [TriggerRule]

    public init(combine: CombineMode = .any, rules: [TriggerRule] = []) {
        self.combine = combine
        self.rules = rules
    }

    /// An empty rule set (which a ``TriggerEngine`` treats as "never fire").
    public static let empty = RuleSet()
}

/// Rebuilds live ``Trigger``s and ``TriggerEngine``s from persisted ``RuleSet``s.
///
/// Holds one instance of each system monitor and shares it across every trigger
/// it builds, so all conditions read a consistent view of the world. Inject
/// fakes in tests; the defaults wire the real IOKit/CoreGraphics/CoreWLAN/AppKit
/// backends.
public struct TriggerFactory {
    private let powerSource: PowerSourceMonitoring
    private let displays: DisplayMonitoring
    private let network: NetworkMonitoring
    private let workspace: WorkspaceMonitoring
    private let processes: ProcessListing
    private let now: () -> Date

    public init(
        powerSource: PowerSourceMonitoring = IOKitPowerSourceMonitor(),
        displays: DisplayMonitoring = CoreGraphicsDisplayMonitor(),
        network: NetworkMonitoring = CoreWLANNetworkMonitor(),
        workspace: WorkspaceMonitoring = NSWorkspaceMonitor(),
        processes: ProcessListing = PSProcessLister(),
        now: @escaping () -> Date = Date.init
    ) {
        self.powerSource = powerSource
        self.displays = displays
        self.network = network
        self.workspace = workspace
        self.processes = processes
        self.now = now
    }

    /// Build the live trigger for one rule.
    public func makeTrigger(for rule: TriggerRule) -> Trigger {
        switch rule {
        case .powerSource(let match):
            return PowerSourceTrigger(match: match, monitor: powerSource)
        case .externalDisplay:
            return ExternalDisplayTrigger(monitor: displays)
        case .wifiSSID(let ssid):
            return WiFiSSIDTrigger(ssid: ssid, monitor: network)
        case .app(let rule):
            let trigger = AppTrigger(bundleID: rule.bundleID, match: rule.match, monitor: workspace)
            return rule.grace > 0
                ? GracePeriodTrigger(wrapping: trigger, grace: rule.grace, now: now)
                : trigger
        case .process(let query):
            return ProcessTrigger(query: query, monitor: processes)
        }
    }

    /// Build a combined engine for a whole rule set.
    public func makeEngine(from ruleSet: RuleSet) -> TriggerEngine {
        TriggerEngine(combine: ruleSet.combine, triggers: ruleSet.rules.map(makeTrigger))
    }
}
