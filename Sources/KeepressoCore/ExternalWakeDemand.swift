import Foundation

/// A scheduler-owned reason to keep the Mac awake before an Agent lease exists.
///
/// Preparation covers wake, readiness checks, and task launch. Handoff covers
/// the interval after launch while Keepresso waits for the task to acquire its
/// own lease. Keeping both phases explicit makes that boundary observable
/// without coupling Core to a particular scheduler implementation.
public struct ScheduledWakeDemand: Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case preparation
        case handoff
    }

    /// Stable automation or launch identifier.
    public var id: String
    public var phase: Phase

    public init(id: String, phase: Phase) {
        self.id = id
        self.phase = phase
    }
}

/// The complete external keep-awake demand observed in one coordinator tick.
///
/// This deliberately excludes ordinary user triggers. Pausing or disabling
/// those triggers must not weaken an active Agent lease or scheduled launch.
public struct ExternalWakeDemandSnapshot: Equatable, Sendable {
    public var activeLeaseIDs: Set<UUID>
    public var scheduled: Set<ScheduledWakeDemand>

    public init(
        activeLeaseIDs: Set<UUID> = [],
        scheduled: Set<ScheduledWakeDemand> = []
    ) {
        self.activeLeaseIDs = activeLeaseIDs
        self.scheduled = scheduled
    }

    public var isEmpty: Bool {
        activeLeaseIDs.isEmpty && scheduled.isEmpty
    }

    public var sourceCount: Int {
        activeLeaseIDs.count + scheduled.count
    }

    /// Explicit Agent and scheduled demand always requires a system assertion,
    /// independently of the user's interactive session options.
    public var requiresSystemSleepPrevention: Bool { !isEmpty }
}

/// Session state sampled in the same tick as ``ExternalWakeDemandSnapshot``.
/// The host supplies this value, so Core never reaches into AppKit or global
/// process state.
public struct ExternalWakeSessionObservation: Equatable, Sendable {
    public var isSessionActive: Bool
    public var isUserTriggerGateInstalled: Bool

    public init(
        isSessionActive: Bool,
        isUserTriggerGateInstalled: Bool
    ) {
        self.isSessionActive = isSessionActive
        self.isUserTriggerGateInstalled = isUserTriggerGateInstalled
    }
}

/// Who controlled the keep-awake session before external work first arrived.
public enum ExternalWakeSessionBaseline: Equatable, Sendable {
    /// A manual session was already active and must remain active afterward.
    case manualSession
    /// Ordinary user triggers owned the gate, whether it was on or off.
    case userTriggerGate
    /// Keepresso was idle, so the external work owns the whole session.
    case idle
}

/// Captured ownership for one uninterrupted nonempty demand interval.
public struct ExternalWakeDemandOwnership: Equatable, Sendable {
    public let baseline: ExternalWakeSessionBaseline
    public let beganAt: Date

    public init(baseline: ExternalWakeSessionBaseline, beganAt: Date) {
        self.baseline = baseline
        self.beganAt = beganAt
    }
}

/// What changed in the external source union during an update.
public enum ExternalWakeDemandLifecycle: Equatable, Sendable {
    case unchanged
    case began(ExternalWakeDemandOwnership)
    case sourcesChanged
    case ended
}

/// The one session ownership action the App host should take after an update.
public enum ExternalWakeSessionAction: Equatable, Sendable {
    case none

    /// External demand exists but the session is not active. The host should
    /// activate its external gate, subject to battery and thermal safety.
    case ensureSessionActive

    /// Remove external gating without stopping the session that was already
    /// active when external work began.
    case preserveManualSession

    /// Remove external gating and let the current ordinary trigger gate decide
    /// whether the session remains active.
    case returnToUserTriggerGate

    /// End the externally owned session as a natural completion, allowing the
    /// configured unattended sleep end action to run.
    case finishUnattendedSession
}

/// Result of one atomic coordinator update.
public struct ExternalWakeDemandDecision: Equatable, Sendable {
    public let lifecycle: ExternalWakeDemandLifecycle
    public let sessionAction: ExternalWakeSessionAction

    public init(
        lifecycle: ExternalWakeDemandLifecycle,
        sessionAction: ExternalWakeSessionAction
    ) {
        self.lifecycle = lifecycle
        self.sessionAction = sessionAction
    }
}

/// Owns the boundary between durable Agent work and the existing session gate.
///
/// The host passes the complete source union in one call. This is important for
/// scheduler handoff: removing a scheduled source and adding its resulting
/// lease in the same update stays inside one uninterrupted ownership interval.
/// The coordinator never treats ordinary trigger settings as external demand.
public struct ExternalWakeDemandCoordinator: Sendable {
    public private(set) var demand = ExternalWakeDemandSnapshot()
    public private(set) var ownership: ExternalWakeDemandOwnership?
    public private(set) var lastChangedAt: Date?

    public init() {}

    /// Reconcile one atomic demand snapshot.
    ///
    /// - Parameters:
    ///   - nextDemand: All active leases and scheduled preparation sources.
    ///   - session: Session and ordinary-gate state sampled for this update.
    ///   - date: Injected timestamp used only for ownership and diagnostics.
    /// - Returns: Lifecycle information plus the session action for the host.
    public mutating func update(
        _ nextDemand: ExternalWakeDemandSnapshot,
        session: ExternalWakeSessionObservation,
        at date: Date
    ) -> ExternalWakeDemandDecision {
        let previousDemand = demand

        if previousDemand.isEmpty, !nextDemand.isEmpty {
            let captured = ExternalWakeDemandOwnership(
                baseline: Self.baseline(for: session),
                beganAt: date
            )
            demand = nextDemand
            ownership = captured
            lastChangedAt = date
            return ExternalWakeDemandDecision(
                lifecycle: .began(captured),
                sessionAction: session.isSessionActive ? .none : .ensureSessionActive
            )
        }

        if !previousDemand.isEmpty, nextDemand.isEmpty {
            let releaseAction = Self.releaseAction(for: ownership?.baseline ?? .idle)
            demand = nextDemand
            ownership = nil
            lastChangedAt = date
            return ExternalWakeDemandDecision(
                lifecycle: .ended,
                sessionAction: releaseAction
            )
        }

        if !nextDemand.isEmpty {
            let lifecycle: ExternalWakeDemandLifecycle
            if previousDemand == nextDemand {
                lifecycle = .unchanged
            } else {
                lifecycle = .sourcesChanged
                lastChangedAt = date
            }
            demand = nextDemand
            return ExternalWakeDemandDecision(
                lifecycle: lifecycle,
                sessionAction: session.isSessionActive ? .none : .ensureSessionActive
            )
        }

        // Both snapshots are empty. Clear impossible stale ownership so a
        // decoded or manually reconstructed coordinator remains conservative.
        demand = nextDemand
        ownership = nil
        return ExternalWakeDemandDecision(
            lifecycle: .unchanged,
            sessionAction: .none
        )
    }

    private static func baseline(
        for session: ExternalWakeSessionObservation
    ) -> ExternalWakeSessionBaseline {
        if session.isUserTriggerGateInstalled { return .userTriggerGate }
        if session.isSessionActive { return .manualSession }
        return .idle
    }

    private static func releaseAction(
        for baseline: ExternalWakeSessionBaseline
    ) -> ExternalWakeSessionAction {
        switch baseline {
        case .manualSession:
            return .preserveManualSession
        case .userTriggerGate:
            return .returnToUserTriggerGate
        case .idle:
            return .finishUnattendedSession
        }
    }
}
