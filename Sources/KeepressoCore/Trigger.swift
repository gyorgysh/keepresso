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

    /// Advance any internal state by one tick. The host calls this exactly once
    /// per reconcile on every registered trigger, unconditionally, so a stateful
    /// trigger (grace window, smoothing average) steps at a fixed cadence
    /// regardless of how the engine combines the results. Stateless triggers
    /// leave this as the default no-op. See ``TriggerEngine`` for why decoupling
    /// the state advance from the gating read matters.
    func tick()

    /// Whether the condition currently holds. A pure, side-effect-free read of
    /// already-advanced state, so the engine and the menu's live rule list can
    /// both call it any number of times per tick without disturbing a stateful
    /// trigger. Call ``tick()`` once per reconcile to move state forward.
    func isSatisfied() -> Bool
}

public extension Trigger {
    /// Stateless triggers have nothing to advance.
    func tick() {}
}

/// Something that produces a single live on/off signal: the abstraction the
/// ``SessionController`` gates on. A lone ``Trigger`` is one; a ``TriggerEngine``
/// combining several is another. Kept separate from ``Trigger`` so the
/// controller need not know how the decision is composed.
public protocol TriggerEvaluating: AnyObject {
    /// Advance internal state by one tick, once per reconcile. Default no-op for
    /// stateless evaluators.
    func tick()

    /// Whether the combined condition currently wants the session ON.
    func isSatisfied() -> Bool
}

public extension TriggerEvaluating {
    func tick() {}
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
            case .onACPower: return L("On AC power")
            case .onBattery: return L("On battery")
            case .charging:  return L("Charging")
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

    /// Pure decision function, exposed for direct unit testing.
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

    public var label: String { L("External display connected") }

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

    public var label: String { L("On Wi-Fi \u{201C}%@\u{201D}", ssid) }

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
        case .running:   return L("is running")
        case .frontmost: return L("is frontmost")
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

    public var label: String { "\(L("App %@", bundleID)) \(match.label)" }

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

    public var label: String { L("Process \u{201C}%@\u{201D} running", query) }

    public func isSatisfied() -> Bool {
        Self.matches(query, in: monitor.current)
    }

    /// Pure decision function, exposed for direct unit testing. An empty query
    /// never matches (so a half-typed rule doesn't pin the Mac awake).
    static func matches(_ query: String, in processes: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        return processes.contains { $0.lowercased().contains(needle) }
    }
}

/// Wraps another trigger and keeps reporting satisfied for `grace` seconds after
/// the wrapped condition goes false: the "linger before deactivating" of v0.3.
///
/// Time-aware by necessity, so the grace window is advanced in ``tick()`` (the
/// once-per-reconcile step) rather than in the gating read. This matters because
/// the engine short-circuits its combine: if the read advanced the window, an
/// OR-sibling firing first would starve this trigger's ``tick()`` and silently
/// lose the grace. ``isSatisfied()`` stays a pure read of the recorded window. A
/// non-positive grace makes it a transparent pass-through.
public final class GracePeriodTrigger: Trigger {
    private let wrapped: Trigger
    /// The linger window. Mutable so a host can retune it live (the AWDL auto
    /// grace is user-configurable); an in-flight linger simply measures against
    /// the new value on the next read.
    public var grace: TimeInterval
    private let now: () -> Date
    private var lastSatisfiedAt: Date?

    public init(wrapping wrapped: Trigger, grace: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.wrapped = wrapped
        self.grace = grace
        self.now = now
    }

    public var label: String { wrapped.label }

    public func tick() {
        wrapped.tick()
        if wrapped.isSatisfied() { lastSatisfiedAt = now() }
    }

    public func isSatisfied() -> Bool {
        if wrapped.isSatisfied() { return true }
        guard grace > 0, let last = lastSatisfiedAt else { return false }
        return now().timeIntervalSince(last) < grace
    }

    /// Whether the wrapped condition holds right now, ignoring the grace window.
    /// Lets the UI distinguish "condition active" from "lingering in grace".
    public var wrappedIsSatisfied: Bool { wrapped.isSatisfied() }

    /// Seconds left in the linger window after the wrapped condition went false,
    /// or `nil` when the wrapped condition holds now (no countdown) or the window
    /// has already lapsed. For a "resuming shortly" countdown in the UI.
    public var graceRemaining: TimeInterval? {
        guard !wrapped.isSatisfied(), grace > 0, let last = lastSatisfiedAt else { return nil }
        let remaining = grace - now().timeIntervalSince(last)
        return remaining > 0 ? remaining : nil
    }

    /// Forget the linger window, so ``isSatisfied()`` reflects only the wrapped
    /// condition until it next holds. Lets a caller cancel an in-flight grace,
    /// e.g. the user manually overriding an auto-pause that's still counting down.
    public func resetGrace() { lastSatisfiedAt = nil }

    /// The trigger inside the grace wrapper, so a host can reach capabilities
    /// the wrapper doesn't forward (per-instance detail rows).
    public var wrappedTrigger: Trigger { wrapped }
}

/// One live sub-row under a rule in the menu's condition list: an instance the
/// rule detected (an agent session) and whether it's currently active.
public struct RuleDetail: Equatable {
    public let label: String
    public let active: Bool
    /// Whether the row's status dot should animate (an agent session that is
    /// actively working); plain conditions keep the static dot.
    public let animated: Bool
    /// The agent behind this row ("claude"), or `nil` for non-agent rows.
    /// Lets the UI tint a row in the agent's own accent color.
    public let agent: String?

    public init(label: String, active: Bool, animated: Bool = false, agent: String? = nil) {
        self.label = label
        self.active = active
        self.animated = animated
        self.agent = agent
    }
}

/// A trigger that can break its verdict down into per-instance rows, so the
/// menu can list what was detected ("claude (s003), working") under the rule.
public protocol TriggerDetailProviding {
    /// The instances behind the current verdict, in display order. A pure read
    /// of already-ticked state, like ``Trigger/isSatisfied()``.
    var detailRows: [RuleDetail] { get }
}

/// How a rule set combines its triggers into a single on/off decision.
public enum CombineMode: String, Codable, Sendable, CaseIterable {
    /// OR: satisfied when *any* trigger fires. The default.
    case any
    /// AND: satisfied only when *every* trigger fires.
    case all
}

/// Combines a set of triggers into one live on/off signal, the seam the
/// ``SessionController`` gates on when running in trigger-driven mode.
///
/// An empty engine is never satisfied, so enabling trigger gating with no
/// rules configured leaves the Mac free to sleep rather than holding it awake.
public final class TriggerEngine: TriggerEvaluating {
    /// How ``triggers`` are combined. Mutable so the UI can flip OR/AND live.
    public var combine: CombineMode

    /// The conditions in this rule set. Fixed at construction: the app rebuilds
    /// a fresh engine (carrying over live triggers) rather than mutating one.
    public let triggers: [Trigger]

    public init(combine: CombineMode = .any, triggers: [Trigger] = []) {
        self.combine = combine
        self.triggers = triggers
    }

    /// Advance every trigger once, unconditionally. Called once per reconcile
    /// before ``isSatisfied()`` so a stateful trigger steps at a fixed cadence
    /// even when the short-circuiting combine below wouldn't have read it.
    public func tick() {
        for trigger in triggers { trigger.tick() }
    }

    /// The combined decision, a pure read of the state ``tick()`` advanced. Safe
    /// to short-circuit: every trigger already stepped in ``tick()``.
    public func isSatisfied() -> Bool {
        guard !triggers.isEmpty else { return false }
        switch combine {
        case .any: return triggers.contains { $0.isSatisfied() }
        case .all: return triggers.allSatisfy { $0.isSatisfied() }
        }
    }
}
