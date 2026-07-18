import Testing
@testable import KeepressoCore

@Test func startupHelperHealthAndRepairPreserveWakeBeforeDiscovery() {
    let helperHealthy = CodexWakeApplyFreshness(codexEnabled: true)
    let helperRepaired = CodexWakeApplyFreshness(codexEnabled: true)

    // Both helper follow-up paths ask the app to reconcile. Neither may clear
    // the previously installed wake while the first discovery is outstanding.
    #expect(!helperHealthy.permitsSystemReconcile)
    #expect(!helperRepaired.permitsSystemReconcile)
}

@Test func stalledDiscoveryKeepsExistingWakeUntouched() {
    var freshness = CodexWakeApplyFreshness(
        codexEnabled: true,
        hasCurrentDiscovery: true
    )
    freshness.invalidateIfEnabled()

    // No completion arrives, so repeated helper follow-ups remain gated.
    #expect(!freshness.permitsSystemReconcile)
    #expect(!freshness.permitsSystemReconcile)
}

@Test func completedDiscoveryAllowsOneCurrentPlanToReconcile() {
    var freshness = CodexWakeApplyFreshness(codexEnabled: true)
    freshness.markDiscoveryCompleted()

    #expect(freshness.hasCurrentDiscovery)
    #expect(freshness.permitsSystemReconcile)
}

@Test func disablingCodexAlwaysAllowsImmediateClear() {
    var freshness = CodexWakeApplyFreshness(codexEnabled: true)
    #expect(!freshness.permitsSystemReconcile)

    freshness.policyDidChange(codexEnabled: false)
    #expect(freshness.permitsSystemReconcile)

    // A later re-enable needs a new discovery and cannot reuse the old plan.
    freshness.policyDidChange(codexEnabled: true)
    #expect(!freshness.permitsSystemReconcile)
}
