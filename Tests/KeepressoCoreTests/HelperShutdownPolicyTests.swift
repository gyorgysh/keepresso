import Testing
@testable import KeepressoCore

@Test func ordinaryIdleExitNeedsTwoConsecutiveIdleChecks() {
    #expect(!HelperShutdownPolicy.shouldExit(
        clientCount: 0, holdsIdle: true, terminateRequested: false, consecutiveIdleChecks: 1
    ))
    #expect(HelperShutdownPolicy.shouldExit(
        clientCount: 0, holdsIdle: true, terminateRequested: false, consecutiveIdleChecks: 2
    ))
}

@Test func aConnectedClientBlocksTheOrdinaryIdleExit() {
    #expect(!HelperShutdownPolicy.shouldExit(
        clientCount: 1, holdsIdle: true, terminateRequested: false, consecutiveIdleChecks: 5
    ))
}

@Test func retirementSkipsTheIdleGraceButNotTheLiveConnectionCheck() {
    // The post-update handoff: exit at the first fully idle moment (the
    // client lets go of its connection between calls to make one), without
    // waiting out the two-check grace of the ordinary idle exit.
    #expect(HelperShutdownPolicy.shouldExit(
        clientCount: 0, holdsIdle: true, terminateRequested: true, consecutiveIdleChecks: 0
    ))
    // But never cut a connected client's call off mid-flight.
    #expect(!HelperShutdownPolicy.shouldExit(
        clientCount: 1, holdsIdle: true, terminateRequested: true, consecutiveIdleChecks: 0
    ))
}

@Test func liveHoldsBlockEveryExit() {
    // Dropping a sleep hold for even a moment (lid closed) could sleep the
    // Mac before the app's re-assert lands; retirement waits for release.
    #expect(!HelperShutdownPolicy.shouldExit(
        clientCount: 0, holdsIdle: false, terminateRequested: true, consecutiveIdleChecks: 9
    ))
    #expect(!HelperShutdownPolicy.shouldExit(
        clientCount: 0, holdsIdle: false, terminateRequested: false, consecutiveIdleChecks: 9
    ))
}
