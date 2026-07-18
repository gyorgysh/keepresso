import Foundation
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

private let discoveryRoot = URL(fileURLWithPath: "/synthetic/automations")

private func discoveryIssue(
    _ reason: CodexAutomationDiscoveryIssue.Reason
) -> CodexAutomationDiscoveryIssue {
    CodexAutomationDiscoveryIssue(sourceURL: discoveryRoot, reason: reason)
}

@Test func transientUnreadableRootPreservesTheExistingWake() {
    let result = CodexAutomationDiscoveryResult(
        issues: [discoveryIssue(.rootUnreadable)]
    )

    let disposition = CodexDiscoverySchedulePolicy.disposition(for: result)
    var freshness = CodexWakeApplyFreshness(
        codexEnabled: true,
        hasCurrentDiscovery: true
    )
    freshness.recordDiscovery(disposition)

    #expect(disposition == .preserveExistingScheduleAndRetry)
    #expect(!freshness.hasCurrentDiscovery)
    #expect(!freshness.permitsSystemReconcile)
}

@Test func transientUnreadableFilePreservesTheExistingWake() {
    let result = CodexAutomationDiscoveryResult(
        issues: [discoveryIssue(.fileUnreadable)]
    )

    #expect(CodexDiscoverySchedulePolicy.disposition(for: result)
        == .preserveExistingScheduleAndRetry)
}

@Test func malformedOrPartialMetadataPreservesTheExistingWake() throws {
    let valid = CodexAutomation(
        id: "valid",
        name: "Valid",
        rrule: "FREQ=DAILY;BYHOUR=9",
        recurrence: try CodexRecurrenceRule("FREQ=DAILY;BYHOUR=9"),
        sourceURL: discoveryRoot.appendingPathComponent("valid/automation.toml")
    )
    let result = CodexAutomationDiscoveryResult(
        automations: [valid],
        issues: [discoveryIssue(.missingField("rrule"))]
    )

    #expect(CodexDiscoverySchedulePolicy.disposition(for: result)
        == .preserveExistingScheduleAndRetry)
}

@Test func cleanEmptyDiscoveryMayClearADeletedAutomationWake() {
    let result = CodexAutomationDiscoveryResult()
    let disposition = CodexDiscoverySchedulePolicy.disposition(for: result)
    var freshness = CodexWakeApplyFreshness(codexEnabled: true)
    freshness.recordDiscovery(disposition)

    #expect(disposition == .applyCurrentResult)
    #expect(freshness.hasCurrentDiscovery)
    #expect(freshness.permitsSystemReconcile)
}
