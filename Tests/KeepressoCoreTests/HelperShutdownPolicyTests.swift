import Testing
import Foundation
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

@Test func shutdownGateCountsIdleChecksAndLiveConnections() {
    let gate = HelperShutdownGate()
    #expect(!gate.claimExitIfAllowed { true })

    let clientID = gate.acceptConnection()
    #expect(clientID == 1)
    #expect(!gate.claimExitIfAllowed { true })
    gate.connectionEnded()

    // Accepting a connection reset the ordinary two-check grace.
    #expect(!gate.claimExitIfAllowed { true })
    #expect(gate.claimExitIfAllowed { true })
    #expect(gate.isShuttingDown)
    #expect(gate.acceptConnection() == nil)
}

@Test func retirementStillWaitsForEngineIdle() {
    let gate = HelperShutdownGate()
    gate.requestTermination()
    #expect(!gate.claimExitIfAllowed { false })
    #expect(gate.claimExitIfAllowed { true })
    #expect(gate.acceptConnection() == nil)
}

@Test func shutdownClaimAtomicallyRejectsARacingConnection() {
    let gate = HelperShutdownGate()
    gate.requestTermination()
    let idleCheckStarted = DispatchSemaphore(value: 0)
    let allowIdleCheck = DispatchSemaphore(value: 0)
    let claimFinished = DispatchSemaphore(value: 0)
    let acceptStarted = DispatchSemaphore(value: 0)
    let acceptFinished = DispatchSemaphore(value: 0)
    let results = ShutdownRaceResults()

    DispatchQueue.global().async {
        results.claimed = gate.claimExitIfAllowed {
            idleCheckStarted.signal()
            allowIdleCheck.wait()
            return true
        }
        claimFinished.signal()
    }
    #expect(idleCheckStarted.wait(timeout: .now() + 2) == .success)

    DispatchQueue.global().async {
        acceptStarted.signal()
        results.acceptedClientID = gate.acceptConnection()
        acceptFinished.signal()
    }
    // Acceptance is blocked behind the same gate lock while the final engine
    // idle check is in progress.
    #expect(acceptStarted.wait(timeout: .now() + 2) == .success)
    #expect(acceptFinished.wait(timeout: .now() + 0.05) == .timedOut)
    allowIdleCheck.signal()
    #expect(claimFinished.wait(timeout: .now() + 2) == .success)
    #expect(acceptFinished.wait(timeout: .now() + 2) == .success)
    #expect(results.claimed)
    #expect(results.acceptedClientID == nil)
}

private final class ShutdownRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedClaimed = false
    private var storedAcceptedClientID: Int?

    var claimed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedClaimed }
        set { lock.lock(); storedClaimed = newValue; lock.unlock() }
    }

    var acceptedClientID: Int? {
        get { lock.lock(); defer { lock.unlock() }; return storedAcceptedClientID }
        set { lock.lock(); storedAcceptedClientID = newValue; lock.unlock() }
    }
}
