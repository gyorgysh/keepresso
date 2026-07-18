import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Fakes

private final class FakeRunner: HelperCommandRunning, SleepSettingReading, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [String] = []
    var failNext = false
    var dropNextSuccessfulSleepWrite = false
    private var storedSleepValue: Bool?

    init(sleepValue: Bool? = false) {
        storedSleepValue = sleepValue
    }

    var sleepValue: Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSleepValue
        }
        set {
            lock.lock()
            storedSleepValue = newValue
            lock.unlock()
        }
    }

    func run(_ path: String, _ arguments: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        commands.append(([path] + arguments).joined(separator: " "))
        if failNext {
            failNext = false
            return false
        }
        if path == "/usr/bin/pmset",
           arguments.count >= 3,
           arguments[arguments.count - 2] == "disablesleep",
           let value = Int(arguments.last ?? "") {
            if dropNextSuccessfulSleepWrite {
                dropNextSuccessfulSleepWrite = false
            } else {
                storedSleepValue = value == 1
            }
        }
        return true
    }

    func sleepIsDisabled() -> Bool? { sleepValue }
}

private final class BlockingRunner: HelperCommandRunning, SleepSettingReading, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommands: [String] = []
    private var storedSleepValue: Bool
    private var blockedCommand: String?
    private var shouldBlockRead = false
    let commandStarted = DispatchSemaphore(value: 0)
    let allowCommand = DispatchSemaphore(value: 0)
    let readStarted = DispatchSemaphore(value: 0)
    let allowRead = DispatchSemaphore(value: 0)

    init(sleepValue: Bool) {
        storedSleepValue = sleepValue
    }

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedCommands
    }

    var sleepValue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedSleepValue
    }

    func blockNextCommand(_ command: String) {
        lock.lock()
        blockedCommand = command
        lock.unlock()
    }

    func blockNextSleepRead() {
        lock.lock()
        shouldBlockRead = true
        lock.unlock()
    }

    func run(_ path: String, _ arguments: [String]) -> Bool {
        let command = ([path] + arguments).joined(separator: " ")
        lock.lock()
        storedCommands.append(command)
        let block = blockedCommand == command
        if block { blockedCommand = nil }
        lock.unlock()
        if block {
            commandStarted.signal()
            allowCommand.wait()
        }
        if path == "/usr/bin/pmset",
           arguments.count >= 3,
           arguments[arguments.count - 2] == "disablesleep",
           let value = Int(arguments.last ?? "") {
            lock.lock()
            storedSleepValue = value == 1
            lock.unlock()
        }
        return true
    }

    func sleepIsDisabled() -> Bool? {
        lock.lock()
        let block = shouldBlockRead
        if block { shouldBlockRead = false }
        lock.unlock()
        if block {
            readStarted.signal()
            allowRead.wait()
        }
        return sleepValue
    }
}

private final class FakeRestoreState: HelperSleepRestoreValuePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<HelperRestoreMarker> = []
    private var storedSleepValue: Bool?
    var failMarkerWrites = false
    var failSleepValueWrites = false

    init(_ initial: Set<HelperRestoreMarker> = [], sleepRestoreValue: Bool? = nil) {
        stored = initial
        storedSleepValue = sleepRestoreValue
    }

    func markers() -> Set<HelperRestoreMarker> {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func set(_ marker: HelperRestoreMarker, present: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !failMarkerWrites else { return false }
        if present { stored.insert(marker) } else { stored.remove(marker) }
        return true
    }

    func sleepRestoreValue() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedSleepValue
    }

    @discardableResult
    func setSleepRestoreValue(_ value: Bool?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !failSleepValueWrites else { return false }
        storedSleepValue = value
        return true
    }
}

private final class FakeFanControl: FanControlling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var forcedPercents: [Int] = []
    private(set) var restoreCalls = 0
    private(set) var unlockCalls = 0
    /// Scripted results for successive setForced calls; empty = keep .ok.
    var results: [FanWriteResult] = []
    var unlockSucceeds = true
    var restoreSucceeds = true
    private var shouldBlockForcedWrite = false
    let forcedWriteStarted = DispatchSemaphore(value: 0)
    let allowForcedWrite = DispatchSemaphore(value: 0)

    func blockNextForcedWrite() {
        lock.lock()
        shouldBlockForcedWrite = true
        lock.unlock()
    }

    func fanCount() -> Int? { 2 }

    func setForced(percent: Int) -> FanWriteResult {
        lock.lock()
        forcedPercents.append(percent)
        let result = results.isEmpty ? FanWriteResult.ok : results.removeFirst()
        let block = shouldBlockForcedWrite
        if block { shouldBlockForcedWrite = false }
        lock.unlock()
        if block {
            forcedWriteStarted.signal()
            allowForcedWrite.wait()
        }
        return result
    }

    func unlock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        unlockCalls += 1
        return unlockSucceeds
    }

    func restoreAuto() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        restoreCalls += 1
        return restoreSucceeds
    }
}

private let sleepOn = "/usr/bin/pmset -a disablesleep 1"
private let sleepOff = "/usr/bin/pmset -a disablesleep 0"
private let awdlDown = "/sbin/ifconfig awdl0 down"
private let awdlUp = "/sbin/ifconfig awdl0 up"

// MARK: - Holds

@Test func sleepModeGenerationRegistryRejectsReconnectReplay() {
    let registry = SleepModeGenerationRegistry()
    var applied: [Int] = []

    #expect(registry.apply(streamID: "app-instance", generation: 2) {
        applied.append(2)
        return true
    })
    #expect(!registry.apply(streamID: "app-instance", generation: 1) {
        applied.append(1)
        return true
    })
    // An idempotent retry of the newest generation remains allowed.
    #expect(registry.apply(streamID: "app-instance", generation: 2) {
        applied.append(22)
        return true
    })
    #expect(applied == [2, 22])
}

@Test func sleepModeGenerationRegistryBoundsUntrustedStreamKeys() {
    let registry = SleepModeGenerationRegistry(maximumStreams: 1)
    #expect(registry.apply(streamID: "first", generation: 1) { true })
    #expect(!registry.apply(streamID: "second", generation: 1) { true })
    #expect(!registry.apply(streamID: "", generation: 1) { true })
    #expect(!registry.apply(streamID: String(repeating: "x", count: 129), generation: 1) { true })
}

@Test func sleepSettingReaderParsesRealAndLegacyPMSetKeys() {
    #expect(PMSetSleepSettingReader.parse("System-wide power settings:\n SleepDisabled 1\n") == true)
    #expect(PMSetSleepSettingReader.parse(" disablesleep 0\n") == false)
    #expect(PMSetSleepSettingReader.parse(" sleepdisabled 1\n") == true)
    #expect(PMSetSleepSettingReader.parse(" SleepDisabled unknown\n") == nil)
    #expect(PMSetSleepSettingReader.parse(" displaysleep 10\n") == nil)
}

@Test func sleepHoldWritesOnlyOnUnionEdges() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    #expect(engine.setSleepHold(client: 1, holding: true))
    #expect(runner.commands == [sleepOn])
    #expect(state.markers() == [.sleepDisabled])

    // A second holder joins and leaves: no extra writes.
    #expect(engine.setSleepHold(client: 2, holding: true))
    #expect(engine.setSleepHold(client: 2, holding: false))
    #expect(runner.commands == [sleepOn])

    // The last holder leaving restores sleep and clears the marker.
    #expect(engine.setSleepHold(client: 1, holding: false))
    #expect(runner.commands == [sleepOn, sleepOff])
    #expect(state.markers().isEmpty)
}

@Test func awdlHoldDownsUpsAndReassertsOnTick() {
    let runner = FakeRunner(sleepValue: false)
    let engine = HelperEngine(runner: runner, state: FakeRestoreState())

    // Idle ticks are no-ops.
    engine.awdlTick()
    #expect(runner.commands.isEmpty)

    #expect(engine.setAWDLHold(client: 7, holding: true))
    engine.awdlTick()
    engine.awdlTick()
    #expect(runner.commands == [awdlDown, awdlDown, awdlDown])

    #expect(engine.setAWDLHold(client: 7, holding: false))
    #expect(runner.commands.last == awdlUp)
    engine.awdlTick()
    #expect(runner.commands.last == awdlUp)
}

@Test func awdlEngageRefusesSystemWriteWhenItsMarkerCannotPersist() {
    let runner = FakeRunner()
    let state = FakeRestoreState()
    state.failMarkerWrites = true
    let engine = HelperEngine(runner: runner, state: state)

    #expect(!engine.setAWDLHold(client: 7, holding: true))
    #expect(runner.commands.isEmpty)
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)

    state.failMarkerWrites = false
    #expect(engine.setAWDLHold(client: 7, holding: true))
    #expect(runner.commands == [awdlDown])
}

@Test func failedAWDLRestoreAndMarkerClearRemainRetryableDebts() {
    let runner = FakeRunner()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: runner, state: state)
    #expect(engine.setAWDLHold(client: 7, holding: true))

    runner.failNext = true
    #expect(!engine.setAWDLHold(client: 7, holding: false))
    #expect(state.markers() == [.awdlDown])
    #expect(!engine.isIdle)
    engine.awdlTick()
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)

    // A successful interface restore is still a debt until marker removal
    // succeeds, and the next tick safely repeats the idempotent restore.
    #expect(engine.setAWDLHold(client: 8, holding: true))
    state.failMarkerWrites = true
    #expect(!engine.setAWDLHold(client: 8, holding: false))
    #expect(state.markers() == [.awdlDown])
    #expect(!engine.isIdle)
    state.failMarkerWrites = false
    engine.awdlTick()
    #expect(state.markers().isEmpty)
    #expect(runner.commands.suffix(2) == [awdlUp, awdlUp])
}

@Test func launchAWDLRecoveryRetriesUntilTheMarkerClears() {
    let runner = FakeRunner()
    runner.failNext = true
    let state = FakeRestoreState([.awdlDown])
    let engine = HelperEngine(runner: runner, state: state)

    engine.restoreAtLaunch()
    #expect(state.markers() == [.awdlDown])
    #expect(!engine.isIdle)
    engine.awdlTick()
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)
}

@Test func awdlReassertCannotLandAfterTheLastRelease() {
    let runner = BlockingRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: runner, state: state)
    #expect(engine.setAWDLHold(client: 7, holding: true))
    runner.blockNextCommand(awdlDown)
    let tickFinished = DispatchSemaphore(value: 0)
    let releaseStarted = DispatchSemaphore(value: 0)
    let releaseFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        engine.awdlTick()
        tickFinished.signal()
    }
    #expect(runner.commandStarted.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
        releaseStarted.signal()
        _ = engine.setAWDLHold(client: 7, holding: false)
        releaseFinished.signal()
    }
    #expect(releaseStarted.wait(timeout: .now() + 2) == .success)
    runner.allowCommand.signal()
    #expect(tickFinished.wait(timeout: .now() + 2) == .success)
    #expect(releaseFinished.wait(timeout: .now() + 2) == .success)

    #expect(runner.commands.last == awdlUp)
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)
}

@Test func clientDisconnectReleasesEverythingItHeld() {
    let runner = FakeRunner()
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    _ = engine.setSleepHold(client: 1, holding: true)
    _ = engine.setAWDLHold(client: 1, holding: true)
    _ = engine.setSleepHold(client: 2, holding: true)
    #expect(!engine.isIdle)

    // Client 1 dies: its AWDL hold ends, but client 2 still holds sleep.
    engine.clientDisconnected(1)
    #expect(runner.commands.contains(awdlUp))
    #expect(!runner.commands.contains(sleepOff))
    #expect(state.markers() == [.sleepDisabled])

    engine.clientDisconnected(2)
    #expect(runner.commands.contains(sleepOff))
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)
}

@Test func failedWriteKeepsAConservativeRestoreDebt() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    runner.failNext = true
    #expect(!engine.setSleepHold(client: 1, holding: true))
    // A failed command may have changed state before returning an error. The
    // saved snapshot makes a later restore safe either way.
    #expect(state.markers() == [.sleepDisabled])
    #expect(state.sleepRestoreValue() == false)
}

@Test func sleepHoldRestoresAnOriginallyDisabledSleepSetting() {
    let runner = FakeRunner(sleepValue: true)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    #expect(engine.setSleepHold(client: 1, holding: true))
    #expect(runner.commands.isEmpty)
    #expect(state.sleepRestoreValue() == true)

    #expect(engine.setSleepHold(client: 1, holding: false))
    #expect(runner.commands.isEmpty)
    #expect(state.markers().isEmpty)
    #expect(state.sleepRestoreValue() == nil)
}

@Test func sleepHoldRefusesToGuessWhenOriginalSettingIsUnreadable() {
    let runner = FakeRunner(sleepValue: nil)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    #expect(!engine.setSleepHold(client: 1, holding: true))
    #expect(engine.isIdle)
    #expect(runner.commands.isEmpty)
    #expect(state.markers().isEmpty)
    #expect(state.sleepRestoreValue() == nil)
}

@Test func failedSleepRestoreKeepsSnapshotForNextLaunch() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )
    #expect(engine.setSleepHold(client: 1, holding: true))

    runner.failNext = true
    #expect(!engine.setSleepHold(client: 1, holding: false))
    #expect(state.markers() == [.sleepDisabled])
    #expect(state.sleepRestoreValue() == false)

    engine.restoreAtLaunch()
    #expect(runner.commands == [sleepOn, sleepOff, sleepOff])
    #expect(state.markers().isEmpty)
    #expect(state.sleepRestoreValue() == nil)
}

@Test func successfulExitWithoutSleepReadbackKeepsDebtAndRetries() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    runner.dropNextSuccessfulSleepWrite = true
    #expect(!engine.setSleepHoldMode(client: 1, mode: .active))
    #expect(state.markers() == [.sleepDisabled])
    #expect(runner.sleepValue == false)

    engine.sleepTick()
    #expect(runner.sleepValue == true)
    #expect(engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(state.markers().isEmpty)
}

@Test func successfulRestoreExitWithoutReadbackCannotClearJournal() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    #expect(engine.setSleepHoldMode(client: 1, mode: .active))
    runner.dropNextSuccessfulSleepWrite = true
    #expect(!engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(runner.sleepValue == true)
    #expect(state.markers() == [.sleepDisabled])
    #expect(!engine.isIdle)

    engine.sleepTick()
    #expect(runner.sleepValue == false)
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)
}

@Test func thermalSleepModesPreserveFalseOriginalAcrossTheWholeTransaction() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    #expect(engine.setSleepHoldMode(client: 1, mode: .active))
    #expect(engine.setSleepHoldMode(client: 1, mode: .thermallySuspended))
    #expect(state.markers() == [.sleepDisabled])
    #expect(state.sleepRestoreValue() == false)
    #expect(engine.setSleepHoldMode(client: 1, mode: .active))
    #expect(engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(runner.commands == [sleepOn, sleepOff, sleepOn, sleepOff])
    #expect(state.markers().isEmpty)
}

@Test func thermalSleepModesPreserveTrueManualOriginal() {
    let runner = FakeRunner(sleepValue: true)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    // This covers both manual-only released-to-suspended and a mixed
    // automatic hold whose original snapshot was already true.
    #expect(engine.setSleepHoldMode(client: 1, mode: .thermallySuspended))
    #expect(runner.commands == [sleepOff])
    #expect(engine.setSleepHoldMode(client: 1, mode: .active))
    #expect(engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(runner.commands == [sleepOff, sleepOn])
    #expect(state.sleepRestoreValue() == nil)
}

@Test func activeClientWinsOverSuspendedClients() {
    let runner = FakeRunner(sleepValue: false)
    let engine = HelperEngine(
        runner: runner,
        state: FakeRestoreState(),
        sleepSettingReader: runner
    )

    #expect(engine.setSleepHoldMode(client: 1, mode: .thermallySuspended))
    #expect(engine.setSleepHoldMode(client: 2, mode: .active))
    #expect(engine.setSleepHoldMode(client: 2, mode: .released))
    #expect(engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(runner.commands == [sleepOn, sleepOff])
}

@Test func failedThermalTransitionAndRestoreRetryOnSleepTick() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    #expect(engine.setSleepHoldMode(client: 1, mode: .active))
    runner.failNext = true
    #expect(!engine.setSleepHoldMode(client: 1, mode: .thermallySuspended))
    #expect(state.markers() == [.sleepDisabled])
    engine.sleepTick()
    #expect(runner.commands.suffix(2) == [sleepOff, sleepOff])

    #expect(engine.setSleepHoldMode(client: 1, mode: .active))
    runner.failNext = true
    #expect(!engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(!engine.isIdle)
    engine.sleepTick()
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)
}

@Test func manualChoiceDuringScopedHoldUpdatesTheRestoreBaseline() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    #expect(engine.setSleepHoldMode(client: 1, mode: .active))
    #expect(engine.setSleepDisabled(true))
    #expect(state.sleepRestoreValue() == true)
    #expect(engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(runner.commands == [sleepOn])
    #expect(state.markers().isEmpty)
}

@Test func manualChoiceOwnsAHolderlessFailedRestoreDebtImmediately() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    #expect(engine.setSleepHoldMode(client: 1, mode: .active))
    runner.failNext = true
    #expect(!engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(state.markers() == [.sleepDisabled])
    #expect(state.sleepRestoreValue() == false)
    #expect(runner.sleepValue == true)

    // There is no holder now, but the marker still defines the transaction.
    // The manual choice replaces its baseline and settles it immediately.
    #expect(engine.setSleepDisabled(true))
    #expect(state.markers().isEmpty)
    #expect(state.sleepRestoreValue() == nil)
    #expect(runner.sleepValue == true)

    let commands = runner.commands
    engine.sleepTick()
    #expect(runner.commands == commands)
    #expect(runner.sleepValue == true)
}

@Test func manualWriteCompletesBeforeConcurrentTransactionSamplesItsBaseline() {
    let runner = BlockingRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )
    runner.blockNextCommand(sleepOn)
    let finished = DispatchGroup()
    let holdStarted = DispatchSemaphore(value: 0)

    finished.enter()
    DispatchQueue.global().async {
        _ = engine.setSleepDisabled(true)
        finished.leave()
    }
    #expect(runner.commandStarted.wait(timeout: .now() + 2) == .success)

    finished.enter()
    DispatchQueue.global().async {
        holdStarted.signal()
        _ = engine.setSleepHoldMode(client: 1, mode: .active)
        finished.leave()
    }
    #expect(holdStarted.wait(timeout: .now() + 2) == .success)
    runner.allowCommand.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)

    #expect(state.sleepRestoreValue() == true)
    #expect(engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(runner.sleepValue == true)
    #expect(runner.commands == [sleepOn])
}

@Test func concurrentManualChoiceUpdatesATransactionWhoseSnapshotStartedFirst() {
    let runner = BlockingRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )
    runner.blockNextSleepRead()
    let finished = DispatchGroup()
    let manualStarted = DispatchSemaphore(value: 0)

    finished.enter()
    DispatchQueue.global().async {
        _ = engine.setSleepHoldMode(client: 1, mode: .active)
        finished.leave()
    }
    #expect(runner.readStarted.wait(timeout: .now() + 2) == .success)

    finished.enter()
    DispatchQueue.global().async {
        manualStarted.signal()
        _ = engine.setSleepDisabled(true)
        finished.leave()
    }
    #expect(manualStarted.wait(timeout: .now() + 2) == .success)
    runner.allowRead.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)

    #expect(state.sleepRestoreValue() == true)
    #expect(engine.setSleepHoldMode(client: 1, mode: .released))
    #expect(runner.sleepValue == true)
    #expect(state.markers().isEmpty)
}

@Test func newSleepHoldPreservesAnUnsettledRestoreSnapshot() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )
    #expect(engine.setSleepHold(client: 1, holding: true))

    runner.failNext = true
    #expect(!engine.setSleepHold(client: 1, holding: false))
    #expect(state.sleepRestoreValue() == false)

    // The failed restore left the live setting at 1. A new hold must reuse the
    // saved original 0 instead of sampling that debt and replacing it with 1.
    runner.sleepValue = true
    #expect(engine.setSleepHold(client: 2, holding: true))
    #expect(state.sleepRestoreValue() == false)
    #expect(engine.setSleepHold(client: 2, holding: false))
    #expect(runner.commands == [sleepOn, sleepOff, sleepOn, sleepOff])
    #expect(state.markers().isEmpty)
    #expect(state.sleepRestoreValue() == nil)
}

@Test func sleepHoldRefusesPMSetWhenRestoreJournalCannotBePersisted() {
    for failSnapshot in [true, false] {
        let runner = FakeRunner(sleepValue: false)
        let state = FakeRestoreState()
        state.failSleepValueWrites = failSnapshot
        state.failMarkerWrites = !failSnapshot
        let engine = HelperEngine(
            runner: runner,
            state: state,
            sleepSettingReader: runner
        )

        #expect(!engine.setSleepHold(client: 1, holding: true))
        #expect(runner.commands.isEmpty)
        #expect(engine.isIdle)
        #expect(state.markers().isEmpty)
    }
}

// MARK: - Manual set and restore

@Test func manualSetIsPlainAndNeverMarked() {
    let runner = FakeRunner()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: runner, state: state)

    #expect(engine.setSleepDisabled(true))
    #expect(runner.commands == [sleepOn])
    // The manual toggle is meant to outlive the app; no restore marker.
    #expect(state.markers().isEmpty)

    #expect(engine.setSleepDisabled(false))
    #expect(runner.commands == [sleepOn, sleepOff])
}

@Test func sleepNowIsFireAndForgetPmset() {
    let runner = FakeRunner()
    let engine = HelperEngine(runner: runner, state: FakeRestoreState())
    #expect(engine.sleepNow())
    #expect(runner.commands == ["/usr/bin/pmset sleepnow"])
    // Not a hold: nothing to restore if the daemon dies after.
    #expect(FakeRestoreState().markers().isEmpty)
}

// MARK: - CLI symlink

/// A scratch directory standing in for /usr/local/bin plus a fake app bundle,
/// so the link logic runs against the real filesystem without touching it.
private struct CLILinkFixture {
    let engine = HelperEngine(runner: FakeRunner(), state: FakeRestoreState())
    let base: URL
    let cliPath: String
    let linkPath: String

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepresso-cli-link-\(UUID().uuidString)")
        let cli = base.appendingPathComponent("Keepresso.app/Contents/Helpers/keepresso")
        try FileManager.default.createDirectory(
            at: cli.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: cli)
        cliPath = cli.path
        linkPath = base.appendingPathComponent("bin/keepresso").path
    }

    var linkDestination: String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
    }
}

@Test func cliLinkIsCreatedWhenMissingAndHealedWhenStale() throws {
    let fixture = try CLILinkFixture()

    // No link yet (the DMG-install case): created, intermediate dir included.
    fixture.engine.ensureCLILink(cliPath: fixture.cliPath, linkPath: fixture.linkPath)
    #expect(fixture.linkDestination == fixture.cliPath)

    // Up to date: idempotent.
    fixture.engine.ensureCLILink(cliPath: fixture.cliPath, linkPath: fixture.linkPath)
    #expect(fixture.linkDestination == fixture.cliPath)

    // Stale (points into some other Keepresso.app, e.g. pre-move): replaced.
    try FileManager.default.removeItem(atPath: fixture.linkPath)
    try FileManager.default.createSymbolicLink(
        atPath: fixture.linkPath,
        withDestinationPath: "/Volumes/Old/Keepresso.app/Contents/Helpers/keepresso"
    )
    fixture.engine.ensureCLILink(cliPath: fixture.cliPath, linkPath: fixture.linkPath)
    #expect(fixture.linkDestination == fixture.cliPath)
}

@Test func cliLinkNeverTouchesSomeoneElsesFile() throws {
    let fixture = try CLILinkFixture()
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: fixture.linkPath).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    // A user's own regular file at the link path: left alone.
    try Data("mine".utf8).write(to: URL(fileURLWithPath: fixture.linkPath))
    fixture.engine.ensureCLILink(cliPath: fixture.cliPath, linkPath: fixture.linkPath)
    #expect(fixture.linkDestination == nil)
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.linkPath)) == Data("mine".utf8))

    // An unrelated symlink: also left alone.
    try FileManager.default.removeItem(atPath: fixture.linkPath)
    try FileManager.default.createSymbolicLink(
        atPath: fixture.linkPath, withDestinationPath: "/usr/bin/true"
    )
    fixture.engine.ensureCLILink(cliPath: fixture.cliPath, linkPath: fixture.linkPath)
    #expect(fixture.linkDestination == "/usr/bin/true")

    // And a missing CLI target creates nothing.
    try FileManager.default.removeItem(atPath: fixture.linkPath)
    fixture.engine.ensureCLILink(cliPath: fixture.cliPath + "-gone", linkPath: fixture.linkPath)
    #expect(fixture.linkDestination == nil)
}

@Test func restoreAtLaunchSettlesLeftoverMarkers() {
    let runner = FakeRunner(sleepValue: true)
    let state = FakeRestoreState([.sleepDisabled, .awdlDown])
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    engine.restoreAtLaunch()
    #expect(runner.commands.contains(sleepOff))
    #expect(runner.commands.contains(awdlUp))
    #expect(state.markers().isEmpty)

    // A clean launch restores nothing.
    let cleanRunner = FakeRunner(sleepValue: false)
    HelperEngine(
        runner: cleanRunner,
        state: FakeRestoreState(),
        sleepSettingReader: cleanRunner
    ).restoreAtLaunch()
    #expect(cleanRunner.commands.isEmpty)
}

@Test func restoreAtLaunchUsesThePersistedOriginalSleepValue() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState([.sleepDisabled], sleepRestoreValue: true)
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    engine.restoreAtLaunch()
    #expect(runner.commands == [sleepOn])
    #expect(state.markers().isEmpty)
    #expect(state.sleepRestoreValue() == nil)
}

@Test func failedLaunchRestoreLeavesMarkersForAnotherRetry() {
    let runner = FakeRunner(sleepValue: true)
    runner.failNext = true
    let state = FakeRestoreState([.sleepDisabled], sleepRestoreValue: false)
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    engine.restoreAtLaunch()
    #expect(state.markers() == [.sleepDisabled])
    #expect(state.sleepRestoreValue() == false)
}

@Test func launchRestoreRequiresMatchingReadbackBeforeClearingDebt() {
    let runner = FakeRunner(sleepValue: true)
    runner.dropNextSuccessfulSleepWrite = true
    let state = FakeRestoreState([.sleepDisabled], sleepRestoreValue: false)
    let engine = HelperEngine(
        runner: runner,
        state: state,
        sleepSettingReader: runner
    )

    engine.restoreAtLaunch()
    #expect(state.markers() == [.sleepDisabled])
    #expect(state.sleepRestoreValue() == false)
    #expect(!engine.isIdle)

    engine.sleepTick()
    #expect(runner.sleepValue == false)
    #expect(state.markers().isEmpty)
}

// MARK: - Fan holds

@Test func fanHoldWritesOnUnionEdgesWithMaxPercentWinning() {
    let fans = FakeFanControl()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)

    #expect(engine.setFanHold(client: 1, holding: true, percent: 60))
    #expect(fans.forcedPercents == [60])
    #expect(state.markers() == [.fanForced])

    // A hotter holder raises the target; the same target writes nothing new.
    #expect(engine.setFanHold(client: 2, holding: true, percent: 90))
    #expect(fans.forcedPercents == [60, 90])
    #expect(engine.setFanHold(client: 3, holding: true, percent: 50))
    #expect(fans.forcedPercents == [60, 90])

    // The hottest leaving steps the target back down; the last one out
    // restores auto and clears the marker.
    #expect(engine.setFanHold(client: 2, holding: false, percent: 0))
    #expect(fans.forcedPercents == [60, 90, 60])
    _ = engine.setFanHold(client: 1, holding: false, percent: 0)
    _ = engine.setFanHold(client: 3, holding: false, percent: 0)
    #expect(fans.restoreCalls == 1)
    #expect(state.markers().isEmpty)
}

@Test func fanEngageRefusesHardwareWriteWhenItsMarkerCannotPersist() {
    let fans = FakeFanControl()
    let state = FakeRestoreState()
    state.failMarkerWrites = true
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)

    #expect(!engine.setFanHold(client: 1, holding: true, percent: 80))
    #expect(fans.forcedPercents.isEmpty)
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)

    state.failMarkerWrites = false
    #expect(engine.setFanHold(client: 1, holding: true, percent: 80))
    #expect(fans.forcedPercents == [80])
}

@Test func fanHoldDisconnectRestoresAutoAndClearsTheMarker() {
    let fans = FakeFanControl()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)

    _ = engine.setFanHold(client: 1, holding: true, percent: 80)
    #expect(!engine.isIdle)
    engine.clientDisconnected(1)
    #expect(fans.restoreCalls == 1)
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)
}

@Test func failedFanEngageStillRecordsTheRestoreDebt() {
    let fans = FakeFanControl()
    fans.results = [.failed]
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)

    // The write failed, but it can partially land (per-fan mode writes) and
    // the tick retries it into success, so the debt exists from the first
    // attempt: a crash between here and the retry must still restore auto.
    #expect(!engine.setFanHold(client: 1, holding: true, percent: 80))
    #expect(state.markers() == [.fanForced])

    engine.fanTick() // retry succeeds; the debt naturally stays
    #expect(state.markers() == [.fanForced])
    #expect(fans.forcedPercents == [80, 80])
}

@Test func failedRestoreKeepsTheFanMarkerForTheNextLaunch() {
    let fans = FakeFanControl()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)
    _ = engine.setFanHold(client: 1, holding: true, percent: 80)

    // The release's restore write failed: the fans are still forced, so the
    // marker must survive for restoreAtLaunch to settle after the daemon
    // exits or crashes.
    fans.restoreSucceeds = false
    #expect(!engine.setFanHold(client: 1, holding: false, percent: 0))
    #expect(state.markers() == [.fanForced])
}

@Test func fanRestoreAndMarkerClearDebtsRetryWithoutAHold() {
    let fans = FakeFanControl()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)
    #expect(engine.setFanHold(client: 1, holding: true, percent: 80))

    fans.restoreSucceeds = false
    #expect(!engine.setFanHold(client: 1, holding: false, percent: 0))
    #expect(state.markers() == [.fanForced])
    #expect(!engine.isIdle)
    fans.restoreSucceeds = true
    engine.fanTick()
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)

    // Marker removal failure is also retryable after auto mode already won.
    #expect(engine.setFanHold(client: 2, holding: true, percent: 70))
    state.failMarkerWrites = true
    #expect(!engine.setFanHold(client: 2, holding: false, percent: 0))
    #expect(state.markers() == [.fanForced])
    state.failMarkerWrites = false
    engine.fanTick()
    #expect(state.markers().isEmpty)
    #expect(fans.restoreCalls == 4)
}

@Test func fanTickReassertsWhileHeldAndIdlesOtherwise() {
    let fans = FakeFanControl()
    let engine = HelperEngine(runner: FakeRunner(), state: FakeRestoreState(), fans: fans)

    engine.fanTick() // idle: no writes
    #expect(fans.forcedPercents.isEmpty)

    _ = engine.setFanHold(client: 1, holding: true, percent: 70)
    engine.fanTick()
    engine.fanTick()
    #expect(fans.forcedPercents == [70, 70, 70])
}

@Test func fanReassertCannotLandAfterTheLastRelease() {
    let fans = FakeFanControl()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)
    #expect(engine.setFanHold(client: 1, holding: true, percent: 80))
    fans.blockNextForcedWrite()
    let tickFinished = DispatchSemaphore(value: 0)
    let releaseStarted = DispatchSemaphore(value: 0)
    let releaseFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        engine.fanTick()
        tickFinished.signal()
    }
    #expect(fans.forcedWriteStarted.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
        releaseStarted.signal()
        _ = engine.setFanHold(client: 1, holding: false, percent: 0)
        releaseFinished.signal()
    }
    #expect(releaseStarted.wait(timeout: .now() + 2) == .success)
    fans.allowForcedWrite.signal()
    #expect(tickFinished.wait(timeout: .now() + 2) == .success)
    #expect(releaseFinished.wait(timeout: .now() + 2) == .success)

    #expect(fans.restoreCalls == 1)
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)
}

@Test func needsUnlockGetsExactlyOneFtstRetry() {
    let fans = FakeFanControl()
    fans.results = [.needsUnlock, .ok]
    let engine = HelperEngine(runner: FakeRunner(), state: FakeRestoreState(), fans: fans)

    #expect(engine.setFanHold(client: 1, holding: true, percent: 80))
    #expect(fans.unlockCalls == 1)
    #expect(fans.forcedPercents == [80, 80]) // rejected, unlocked, retried

    // When the unlock itself fails, there is no second retry.
    let stubborn = FakeFanControl()
    stubborn.results = [.needsUnlock]
    stubborn.unlockSucceeds = false
    let engine2 = HelperEngine(runner: FakeRunner(), state: FakeRestoreState(), fans: stubborn)
    #expect(!engine2.setFanHold(client: 1, holding: true, percent: 80))
    #expect(stubborn.forcedPercents == [80])
}

@Test func repeatedFanWriteFailuresSurrenderTheHold() {
    let fans = FakeFanControl()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)
    _ = engine.setFanHold(client: 1, holding: true, percent: 80)
    #expect(state.markers() == [.fanForced])

    // Every re-assert fails from here on; the engine gives up after the cap,
    // restores auto, clears the marker, and records the drop.
    fans.results = Array(repeating: .failed, count: 20)
    for _ in 0..<HelperEngine.maxFanFailures { engine.fanTick() }
    #expect(engine.fanHoldDropped)
    #expect(engine.isIdle)
    #expect(fans.restoreCalls == 1)
    #expect(state.markers().isEmpty)

    // Ticks after the surrender write nothing further.
    let writesAfterDrop = fans.forcedPercents.count
    engine.fanTick()
    #expect(fans.forcedPercents.count == writesAfterDrop)

    // A fresh hold gets a fresh chance and clears the dropped flag.
    _ = engine.setFanHold(client: 2, holding: true, percent: 50)
    #expect(!engine.fanHoldDropped)
}

@Test func restoreAtLaunchSettlesALeftoverFanMarker() {
    let fans = FakeFanControl()
    let state = FakeRestoreState([.fanForced])
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)
    engine.restoreAtLaunch()
    #expect(fans.restoreCalls == 1)
    #expect(state.markers().isEmpty)
}

@Test func failedLaunchFanRecoveryBlocksIdleAndRetriesOnTick() {
    let fans = FakeFanControl()
    fans.restoreSucceeds = false
    let state = FakeRestoreState([.fanForced])
    let engine = HelperEngine(runner: FakeRunner(), state: state, fans: fans)

    engine.restoreAtLaunch()
    #expect(state.markers() == [.fanForced])
    #expect(!engine.isIdle)
    fans.restoreSucceeds = true
    engine.fanTick()
    #expect(state.markers().isEmpty)
    #expect(engine.isIdle)
}
