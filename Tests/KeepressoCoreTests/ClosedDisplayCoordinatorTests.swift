import Testing
import Foundation
@testable import KeepressoCore

private func conditions(
    onlyWhileBrewing: Bool = true,
    brewing: Bool = false,
    helperInstalled: Bool = true,
    automationHolding: Bool = false,
    automationAuthorized: Bool = true,
    automationFailed: Bool = false,
    settingIsOn: Bool? = false,
    settingIsBusy: Bool = false
) -> ClosedDisplayCoordinator.Conditions {
    .init(
        onlyWhileBrewing: onlyWhileBrewing,
        brewing: brewing,
        helperInstalled: helperInstalled,
        automationHolding: automationHolding,
        automationAuthorized: automationAuthorized,
        automationFailed: automationFailed,
        settingIsOn: settingIsOn,
        settingIsBusy: settingIsBusy
    )
}

@MainActor
@Test func tickDoesNothingWhileTheFeatureIsOff() {
    let coordinator = ClosedDisplayCoordinator()
    #expect(coordinator.tick(conditions(onlyWhileBrewing: false, brewing: true)).isEmpty)
}

@MainActor
@Test func tickPulsesTheAutomationWithTheSessionState() {
    let coordinator = ClosedDisplayCoordinator()
    #expect(coordinator.tick(conditions(brewing: true)).contains(.runAutoTick(brewing: true)))
    #expect(coordinator.tick(conditions(brewing: false)).contains(.runAutoTick(brewing: false)))
}

@MainActor
@Test func engagePromptIsAnnouncedOnceOnTheSessionEdge() {
    let coordinator = ClosedDisplayCoordinator()
    let start = conditions(brewing: true, helperInstalled: false, automationAuthorized: false)
    #expect(coordinator.tick(start).contains(.announceEngagePrompt))
    #expect(!coordinator.tick(start).contains(.announceEngagePrompt))
}

@MainActor
@Test func engagePromptIsSilentWithTheHelperOrAnExistingAuthorization() {
    let withHelper = ClosedDisplayCoordinator()
    #expect(!withHelper.tick(
        conditions(brewing: true, helperInstalled: true, automationAuthorized: false)
    ).contains(.announceEngagePrompt))

    let alreadyAuthorized = ClosedDisplayCoordinator()
    #expect(!alreadyAuthorized.tick(
        conditions(brewing: true, helperInstalled: false, automationAuthorized: true)
    ).contains(.announceEngagePrompt))
}

@MainActor
@Test func aFailedEngageChecksTheHelperOnceForEachFailure() {
    let coordinator = ClosedDisplayCoordinator()
    let failing = conditions(automationFailed: true)
    #expect(coordinator.tick(failing).contains(.verifyHelper))
    #expect(!coordinator.tick(failing).contains(.verifyHelper))
    _ = coordinator.tick(conditions(automationFailed: false))
    #expect(coordinator.tick(failing).contains(.verifyHelper))
}

@MainActor
@Test func aFailedEngageWithoutTheHelperIsNotTheDaemonsFault() {
    let coordinator = ClosedDisplayCoordinator()
    #expect(!coordinator.tick(
        conditions(helperInstalled: false, automationFailed: true)
    ).contains(.verifyHelper))
}

@MainActor
@Test func engageAndReleaseAreMirroredAfterTheHelperHasACycle() {
    let coordinator = ClosedDisplayCoordinator()
    _ = coordinator.tick(conditions())
    let engaged = coordinator.tick(conditions(brewing: true, automationHolding: true))
    #expect(engaged.contains(.refreshThenEnforce(delay: ClosedDisplayCoordinator.mirrorDelay)))
    let held = coordinator.tick(conditions(brewing: true, automationHolding: true, settingIsOn: true))
    #expect(!held.contains(.refreshThenEnforce(delay: ClosedDisplayCoordinator.mirrorDelay)))
    let released = coordinator.tick(conditions(automationHolding: false, settingIsOn: true))
    #expect(released.contains(.refreshThenEnforce(delay: ClosedDisplayCoordinator.mirrorDelay)))
    #expect(!released.contains(.clearForeignHold(announce: false)))
}

@MainActor
@Test func idleTicksReReadTheSettingOnTheirOwnCadence() {
    let coordinator = ClosedDisplayCoordinator(pollInterval: 3)
    for _ in 0..<2 {
        #expect(!coordinator.tick(conditions()).contains(.refreshThenEnforce(delay: nil)))
    }
    #expect(coordinator.tick(conditions()).contains(.refreshThenEnforce(delay: nil)))
    #expect(!coordinator.tick(conditions()).contains(.refreshThenEnforce(delay: nil)))
}

@MainActor
@Test func theUnattendedReReadWaitsForAnIdleMac() {
    let coordinator = ClosedDisplayCoordinator(pollInterval: 2)
    for _ in 0..<5 {
        #expect(!coordinator.tick(conditions(brewing: true)).contains(.refreshThenEnforce(delay: nil)))
    }
}

@MainActor
@Test func aMirroredChangeRestartsThePollCounter() {
    let coordinator = ClosedDisplayCoordinator(pollInterval: 3)
    _ = coordinator.tick(conditions())
    _ = coordinator.tick(conditions())
    _ = coordinator.tick(conditions(automationHolding: true))
    for _ in 0..<2 {
        #expect(!coordinator.tick(conditions(automationHolding: true))
            .contains(.refreshThenEnforce(delay: nil)))
    }
}

@MainActor
@Test func anIdleForeignHoldIsClearedOnce() {
    let coordinator = ClosedDisplayCoordinator()
    let foreign = conditions(settingIsOn: true)
    #expect(coordinator.tick(foreign).contains(.clearForeignHold(announce: false)))
    #expect(!coordinator.tick(foreign).contains(.clearForeignHold(announce: false)))
}

@MainActor
@Test func aForeignHoldIsLeftAloneDuringASession() {
    let coordinator = ClosedDisplayCoordinator()
    let brewingWithHold = conditions(brewing: true, settingIsOn: true)
    #expect(!coordinator.tick(brewingWithHold).contains(.clearForeignHold(announce: false)))
}

@MainActor
@Test func aSessionRearmsTheForeignHoldClear() {
    let coordinator = ClosedDisplayCoordinator()
    #expect(coordinator.tick(conditions(settingIsOn: true)).contains(.clearForeignHold(announce: false)))
    _ = coordinator.tick(conditions(brewing: true, settingIsOn: true))
    #expect(coordinator.tick(conditions(settingIsOn: true)).contains(.clearForeignHold(announce: false)))
}

@MainActor
@Test func withoutTheHelperTheClearIsAnnouncedAndOfferedOncePerRun() {
    let coordinator = ClosedDisplayCoordinator()
    let foreign = conditions(helperInstalled: false, settingIsOn: true)
    #expect(coordinator.tick(foreign).contains(.clearForeignHold(announce: true)))
    _ = coordinator.tick(conditions(brewing: true, helperInstalled: false, settingIsOn: true))
    #expect(!coordinator.tick(foreign).contains(.clearForeignHold(announce: true)))
}

@MainActor
@Test func aPromptTheUserIsAlreadyAnsweringNeedsNoNotice() {
    let coordinator = ClosedDisplayCoordinator()
    let action = coordinator.enforce(
        conditions(helperInstalled: false, settingIsOn: true),
        allowPrompt: true
    )
    #expect(action == .clearForeignHold(announce: false))
}

@MainActor
@Test func enforcementWaitsForAPendingReRead() {
    let coordinator = ClosedDisplayCoordinator()
    let foreign = conditions(settingIsOn: true)
    let token = coordinator.beginRefresh()
    #expect(coordinator.enforce(foreign) == nil)
    let ticked = coordinator.tick(foreign)
    #expect(ticked.contains(.runAutoTick(brewing: false)))
    #expect(!ticked.contains(.clearForeignHold(announce: false)))
    #expect(coordinator.endRefresh(token, settingIsOn: true))
    #expect(coordinator.enforce(foreign) == .clearForeignHold(announce: false))
}

@MainActor
@Test func enforcementWaitsWhileAPromptIsOnScreen() {
    let coordinator = ClosedDisplayCoordinator()
    #expect(coordinator.enforce(conditions(settingIsOn: true, settingIsBusy: true)) == nil)
}

@MainActor
@Test func asupersededReReadLeavesTheLatchForTheNewerOne() {
    let coordinator = ClosedDisplayCoordinator()
    let old = coordinator.beginRefresh()
    let new = coordinator.beginRefresh()
    #expect(!coordinator.refreshIsCurrent(old))
    #expect(coordinator.refreshIsCurrent(new))
    #expect(!coordinator.endRefresh(old, settingIsOn: false))
    #expect(coordinator.enforce(conditions(settingIsOn: true)) == nil)
    #expect(coordinator.endRefresh(new, settingIsOn: true))
    #expect(coordinator.enforce(conditions(settingIsOn: true)) == .clearForeignHold(announce: false))
}

@MainActor
@Test func aConfirmedOffSettingArmsTheClearAgain() {
    let coordinator = ClosedDisplayCoordinator()
    #expect(coordinator.tick(conditions(settingIsOn: true)).contains(.clearForeignHold(announce: false)))
    let token = coordinator.beginRefresh()
    #expect(coordinator.endRefresh(token, settingIsOn: false))
    #expect(coordinator.enforce(conditions(settingIsOn: true)) == .clearForeignHold(announce: false))
}

@MainActor
@Test func anUnreadableSettingLeavesTheLatchAlone() {
    let coordinator = ClosedDisplayCoordinator()
    #expect(coordinator.tick(conditions(settingIsOn: true)).contains(.clearForeignHold(announce: false)))
    let token = coordinator.beginRefresh()
    #expect(coordinator.endRefresh(token, settingIsOn: nil))
    #expect(coordinator.enforce(conditions(settingIsOn: true)) == nil)
}

@MainActor
@Test func turningTheFeatureOnArmsTheClear() {
    let coordinator = ClosedDisplayCoordinator()
    #expect(coordinator.tick(conditions(settingIsOn: true)).contains(.clearForeignHold(announce: false)))
    coordinator.rearmForeignHoldClear()
    #expect(coordinator.enforce(conditions(settingIsOn: true)) == .clearForeignHold(announce: false))
}
