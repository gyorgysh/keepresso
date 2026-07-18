/// What the app should do when the helper did not answer a wake-schedule
/// request. Registration state is considered separately from the failed ping:
/// an enabled, updating, or approval-pending helper can recover, while a
/// confirmed missing helper requires user installation.
public enum WakeApplyRecoveryAction: Equatable, Sendable {
    case verifyAndRetry
    case notifyMissingAndStop
}

public enum WakeApplyRecoveryPolicy {
    public static func action(
        helperInstalled: Bool,
        helperGateNeedsInstallation: Bool
    ) -> WakeApplyRecoveryAction {
        if helperInstalled || !helperGateNeedsInstallation {
            return .verifyAndRetry
        }
        return .notifyMissingAndStop
    }
}
