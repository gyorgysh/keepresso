import Testing
@testable import KeepressoCore

@Test func installedButTemporarilyUnreachableHelperIsVerifiedAndRetried() {
    #expect(WakeApplyRecoveryPolicy.action(
        helperInstalled: true,
        helperGateNeedsInstallation: false
    ) == .verifyAndRetry)
}

@Test func transitionalHelperStatesRetryBeforeInstalledMirroringCatchesUp() {
    #expect(WakeApplyRecoveryPolicy.action(
        helperInstalled: false,
        helperGateNeedsInstallation: false
    ) == .verifyAndRetry)
}

@Test func confirmedMissingHelperStopsAndNotifies() {
    #expect(WakeApplyRecoveryPolicy.action(
        helperInstalled: false,
        helperGateNeedsInstallation: true
    ) == .notifyMissingAndStop)
}
