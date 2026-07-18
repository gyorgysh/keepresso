/// Gates system wake-schedule reconciliation until Codex automation discovery
/// has produced a plan for the currently enabled policy.
///
/// Keeping the gate closed preserves an already installed system wake while
/// startup helper verification or repair is running. Disabling Codex bypasses
/// the gate so an explicit user clear is never delayed.
public struct CodexWakeApplyFreshness: Equatable, Sendable {
    public private(set) var codexEnabled: Bool
    public private(set) var hasCurrentDiscovery: Bool

    public init(
        codexEnabled: Bool = false,
        hasCurrentDiscovery: Bool = false
    ) {
        self.codexEnabled = codexEnabled
        self.hasCurrentDiscovery = hasCurrentDiscovery
    }

    /// A disabled policy may always clear. An enabled policy may reconcile only
    /// after discovery explicitly completed for its current inputs.
    public var permitsSystemReconcile: Bool {
        !codexEnabled || hasCurrentDiscovery
    }

    /// Any policy replacement invalidates the prior plan. This includes a fresh
    /// enable after disable, even if the restored values happen to match.
    public mutating func policyDidChange(codexEnabled: Bool) {
        self.codexEnabled = codexEnabled
        hasCurrentDiscovery = false
    }

    /// A forced discovery follows an input or lifecycle edge that makes the
    /// previous plan unsuitable for a new system write. The system's existing
    /// schedule remains untouched until the replacement result arrives.
    public mutating func invalidateIfEnabled() {
        if codexEnabled { hasCurrentDiscovery = false }
    }

    public mutating func markDiscoveryCompleted() {
        if codexEnabled { hasCurrentDiscovery = true }
    }
}

/// Whether one discovery pass is complete enough to replace the system wake
/// schedule. A clean empty result is authoritative because every automation
/// may have been deleted. Any issue makes the result incomplete, so the last
/// installed wake remains untouched while discovery retries.
public enum CodexDiscoveryScheduleDisposition: Equatable, Sendable {
    case applyCurrentResult
    case preserveExistingScheduleAndRetry
}

public enum CodexDiscoverySchedulePolicy {
    public static func disposition(
        for result: CodexAutomationDiscoveryResult
    ) -> CodexDiscoveryScheduleDisposition {
        result.issues.isEmpty
            ? .applyCurrentResult
            : .preserveExistingScheduleAndRetry
    }
}

public extension CodexWakeApplyFreshness {
    /// Record whether the latest pass is authoritative for the enabled policy.
    /// Incomplete discovery explicitly closes the apply gate even when an
    /// earlier clean pass was current.
    mutating func recordDiscovery(
        _ disposition: CodexDiscoveryScheduleDisposition
    ) {
        guard codexEnabled else { return }
        hasCurrentDiscovery = disposition == .applyCurrentResult
    }
}
