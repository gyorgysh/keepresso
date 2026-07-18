import Foundation
import Testing
@testable import KeepressoCore

private let demandTestDate = Date(timeIntervalSince1970: 1_000)

private func demandSession(
    active: Bool = false,
    userGate: Bool = false
) -> ExternalWakeSessionObservation {
    ExternalWakeSessionObservation(
        isSessionActive: active,
        isUserTriggerGateInstalled: userGate
    )
}

@Test func firstLeaseFromIdleOwnsAndStartsTheSession() {
    var coordinator = ExternalWakeDemandCoordinator()
    let lease = UUID()

    let decision = coordinator.update(
        ExternalWakeDemandSnapshot(activeLeaseIDs: [lease]),
        session: demandSession(),
        at: demandTestDate
    )

    let expectedOwnership = ExternalWakeDemandOwnership(
        baseline: .idle,
        beganAt: demandTestDate
    )
    #expect(decision == ExternalWakeDemandDecision(
        lifecycle: .began(expectedOwnership),
        sessionAction: .ensureSessionActive
    ))
    #expect(coordinator.ownership == expectedOwnership)
    #expect(coordinator.demand.activeLeaseIDs == [lease])
}

@Test func concurrentLeasesHoldUntilTheLastLeaseLeaves() {
    var coordinator = ExternalWakeDemandCoordinator()
    let first = UUID()
    let second = UUID()

    _ = coordinator.update(
        ExternalWakeDemandSnapshot(activeLeaseIDs: [first, second]),
        session: demandSession(),
        at: demandTestDate
    )

    let oneRemaining = coordinator.update(
        ExternalWakeDemandSnapshot(activeLeaseIDs: [second]),
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(1)
    )
    #expect(oneRemaining.lifecycle == .sourcesChanged)
    #expect(oneRemaining.sessionAction == .none)
    #expect(coordinator.ownership?.baseline == .idle)
    #expect(coordinator.demand.requiresSystemSleepPrevention)

    let allFinished = coordinator.update(
        ExternalWakeDemandSnapshot(),
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(2)
    )
    #expect(allFinished.lifecycle == .ended)
    #expect(allFinished.sessionAction == .finishUnattendedSession)
    #expect(!coordinator.demand.requiresSystemSleepPrevention)
}

@Test func scheduledAndAgentDemandBothRequireSystemSleepPrevention() {
    let scheduled = ExternalWakeDemandSnapshot(scheduled: [
        ScheduledWakeDemand(id: "nightly", phase: .preparation),
    ])
    let leased = ExternalWakeDemandSnapshot(activeLeaseIDs: [UUID()])

    #expect(scheduled.requiresSystemSleepPrevention)
    #expect(leased.requiresSystemSleepPrevention)
    #expect(!ExternalWakeDemandSnapshot().requiresSystemSleepPrevention)
}

@Test func scheduledPreparationHandsOffToLeaseWithoutEndingOwnership() {
    var coordinator = ExternalWakeDemandCoordinator()
    let schedule = ScheduledWakeDemand(id: "nightly", phase: .preparation)
    let lease = UUID()

    let began = coordinator.update(
        ExternalWakeDemandSnapshot(scheduled: [schedule]),
        session: demandSession(),
        at: demandTestDate
    )
    #expect(began.lifecycle == .began(ExternalWakeDemandOwnership(
        baseline: .idle,
        beganAt: demandTestDate
    )))

    let handoff = coordinator.update(
        ExternalWakeDemandSnapshot(activeLeaseIDs: [lease]),
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(10)
    )

    #expect(handoff.lifecycle == .sourcesChanged)
    #expect(handoff.sessionAction == .none)
    #expect(coordinator.ownership?.beganAt == demandTestDate)

    let ended = coordinator.update(
        ExternalWakeDemandSnapshot(),
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(20)
    )
    #expect(ended.sessionAction == .finishUnattendedSession)
}

@Test func scheduledPhaseCanAdvanceWithoutReleasingDemand() {
    var coordinator = ExternalWakeDemandCoordinator()
    let preparation = ScheduledWakeDemand(id: "daily", phase: .preparation)
    let handoff = ScheduledWakeDemand(id: "daily", phase: .handoff)

    _ = coordinator.update(
        ExternalWakeDemandSnapshot(scheduled: [preparation]),
        session: demandSession(),
        at: demandTestDate
    )
    let decision = coordinator.update(
        ExternalWakeDemandSnapshot(scheduled: [handoff]),
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(1)
    )

    #expect(decision.lifecycle == .sourcesChanged)
    #expect(decision.sessionAction == .none)
    #expect(coordinator.ownership?.beganAt == demandTestDate)
}

@Test func preexistingManualSessionIsPreservedAfterExternalWork() {
    var coordinator = ExternalWakeDemandCoordinator()
    let lease = UUID()

    let began = coordinator.update(
        ExternalWakeDemandSnapshot(activeLeaseIDs: [lease]),
        session: demandSession(active: true),
        at: demandTestDate
    )
    #expect(began.lifecycle == .began(ExternalWakeDemandOwnership(
        baseline: .manualSession,
        beganAt: demandTestDate
    )))
    #expect(began.sessionAction == .none)

    let ended = coordinator.update(
        ExternalWakeDemandSnapshot(),
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(1)
    )
    #expect(ended.sessionAction == .preserveManualSession)
}

@Test func userGateRegainsControlAfterExternalWork() {
    var coordinator = ExternalWakeDemandCoordinator()
    let lease = UUID()

    let began = coordinator.update(
        ExternalWakeDemandSnapshot(activeLeaseIDs: [lease]),
        session: demandSession(userGate: true),
        at: demandTestDate
    )
    #expect(began.lifecycle == .began(ExternalWakeDemandOwnership(
        baseline: .userTriggerGate,
        beganAt: demandTestDate
    )))
    #expect(began.sessionAction == .ensureSessionActive)

    // Pausing or removing the ordinary gate while demand remains does not
    // remove the captured external ownership or its active-session request.
    let heldAfterPause = coordinator.update(
        ExternalWakeDemandSnapshot(activeLeaseIDs: [lease]),
        session: demandSession(),
        at: demandTestDate.addingTimeInterval(1)
    )
    #expect(heldAfterPause.lifecycle == .unchanged)
    #expect(heldAfterPause.sessionAction == .ensureSessionActive)
    #expect(coordinator.ownership?.baseline == .userTriggerGate)

    let ended = coordinator.update(
        ExternalWakeDemandSnapshot(),
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(2)
    )
    #expect(ended.sessionAction == .returnToUserTriggerGate)
}

@Test func restartWithPersistedLeaseTreatsIdleSessionAsExternallyOwned() {
    var coordinator = ExternalWakeDemandCoordinator()

    let recovered = coordinator.update(
        ExternalWakeDemandSnapshot(activeLeaseIDs: [UUID()]),
        session: demandSession(),
        at: demandTestDate
    )

    #expect(coordinator.ownership?.baseline == .idle)
    #expect(recovered.sessionAction == .ensureSessionActive)

    let release = coordinator.update(
        ExternalWakeDemandSnapshot(),
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(1)
    )
    #expect(release.sessionAction == .finishUnattendedSession)
}

@Test func identicalUpdatesAreIdempotent() {
    var coordinator = ExternalWakeDemandCoordinator()
    let snapshot = ExternalWakeDemandSnapshot(activeLeaseIDs: [UUID()])

    _ = coordinator.update(
        snapshot,
        session: demandSession(),
        at: demandTestDate
    )
    let firstOwnership = coordinator.ownership
    let firstChange = coordinator.lastChangedAt

    let duplicate = coordinator.update(
        snapshot,
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(60)
    )

    #expect(duplicate == ExternalWakeDemandDecision(
        lifecycle: .unchanged,
        sessionAction: .none
    ))
    #expect(coordinator.ownership == firstOwnership)
    #expect(coordinator.lastChangedAt == firstChange)

    _ = coordinator.update(
        ExternalWakeDemandSnapshot(),
        session: demandSession(active: true),
        at: demandTestDate.addingTimeInterval(61)
    )
    let duplicateEmpty = coordinator.update(
        ExternalWakeDemandSnapshot(),
        session: demandSession(),
        at: demandTestDate.addingTimeInterval(120)
    )
    #expect(duplicateEmpty == ExternalWakeDemandDecision(
        lifecycle: .unchanged,
        sessionAction: .none
    ))
}

@Test func activeDemandRepairsAnUnexpectedInactiveSession() {
    var coordinator = ExternalWakeDemandCoordinator()
    let snapshot = ExternalWakeDemandSnapshot(activeLeaseIDs: [UUID()])

    _ = coordinator.update(
        snapshot,
        session: demandSession(active: true),
        at: demandTestDate
    )
    let repair = coordinator.update(
        snapshot,
        session: demandSession(),
        at: demandTestDate.addingTimeInterval(1)
    )

    #expect(repair.lifecycle == .unchanged)
    #expect(repair.sessionAction == .ensureSessionActive)
}
