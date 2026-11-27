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
    #expect(HelperShutdownPolicy.shouldExit(
        clientCount: 0, holdsIdle: true, terminateRequested: true, consecutiveIdleChecks: 0
    ))
    #expect(!HelperShutdownPolicy.shouldExit(
        clientCount: 1, holdsIdle: true, terminateRequested: true, consecutiveIdleChecks: 0
    ))
}

@Test func liveHoldsBlockEveryExit() {
    #expect(!HelperShutdownPolicy.shouldExit(
        clientCount: 0, holdsIdle: false, terminateRequested: true, consecutiveIdleChecks: 9
    ))
    #expect(!HelperShutdownPolicy.shouldExit(
        clientCount: 0, holdsIdle: false, terminateRequested: false, consecutiveIdleChecks: 9
    ))
}
