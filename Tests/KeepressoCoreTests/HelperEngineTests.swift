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

    func fanCount() -> Int? { 2 }

    func setForced(percent: Int) -> FanWriteResult {
        lock.lock()
        defer { lock.unlock() }
        forcedPercents.append(percent)
        return results.isEmpty ? .ok : results.removeFirst()
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

@Test func streamOwnershipMigrationRejectsTheOldConnectionsSameGeneration() {
    let registry = SleepModeGenerationRegistry()
    var previousOwners: [Int?] = []
    var oldDisconnectCleanups = 0

    #expect(registry.apply(
        streamID: "process-stream",
        generation: 4,
        clientID: 10
    ) { previousClientID in
        previousOwners.append(previousClientID)
        return true
    })
    #expect(registry.apply(
        streamID: "process-stream",
        generation: 4,
        clientID: 11
    ) { previousClientID in
        previousOwners.append(previousClientID)
        return true
    })

    // A delayed request on old connection 10 cannot reclaim generation 4.
    #expect(!registry.apply(
        streamID: "process-stream",
        generation: 4,
        clientID: 10
    ) { _ in
        Issue.record("the old connection operation must not run")
        return true
    })
    registry.clientDisconnected(10) { oldDisconnectCleanups += 1 }

    #expect(previousOwners.count == 2)
    #expect(previousOwners[0] == nil)
    #expect(previousOwners[1] == 10)
    #expect(oldDisconnectCleanups == 0)
}

@Test func disconnectedOwnerTombstoneStillRejectsAnOlderSameGenerationReplay() {
    let registry = SleepModeGenerationRegistry()
    var cleanups = 0
    var previousOwnerForC: Int?

    #expect(registry.apply(
        streamID: "process-stream",
        generation: 4,
        clientID: 10
    ) { _ in true })
    #expect(registry.apply(
        streamID: "process-stream",
        generation: 4,
        clientID: 11
    ) { previousClientID in
        previousClientID == 10
    })
    registry.clientDisconnected(11) { cleanups += 1 }

    #expect(cleanups == 1)
    #expect(!registry.apply(
        streamID: "process-stream",
        generation: 4,
        clientID: 10
    ) { _ in
        Issue.record("older connection A must remain fenced by B's tombstone")
        return true
    })
    #expect(!registry.apply(
        streamID: "process-stream",
        generation: 4,
        clientID: 11
    ) { _ in
        Issue.record("disconnected owner B must not retry its tombstoned generation")
        return true
    })

    // A genuinely newer reconnect C may retry generation 4. It receives B as
    // the previous logical owner, whose engine holder cleanup is idempotent.
    #expect(registry.apply(
        streamID: "process-stream",
        generation: 4,
        clientID: 12
    ) { previousClientID in
        previousOwnerForC = previousClientID
        return true
    })
    #expect(previousOwnerForC == 11)
    #expect(registry.apply(
        streamID: "process-stream",
        generation: 4,
        clientID: 12
    ) { previousClientID in
        previousClientID == 12
    })

    // A higher generation starts a new connection-order epoch, so its first
    // accepted request need not have a client ID above generation 4's C.
    #expect(registry.apply(
        streamID: "process-stream",
        generation: 5,
        clientID: 10
    ) { previousClientID in
        previousClientID == 12
    })
    registry.clientDisconnected(10) { cleanups += 1 }
    #expect(!registry.apply(
        streamID: "process-stream",
        generation: 5,
        clientID: 10
    ) { _ in true })
    #expect(registry.apply(
        streamID: "process-stream",
        generation: 5,
        clientID: 11
    ) { previousClientID in
        previousClientID == 10
    })
    #expect(cleanups == 2)
}

@Test func reconnectMigrationPreservesSleepAWDLAndFanLogicalHolders() {
    let runner = FakeRunner(sleepValue: false)
    let state = FakeRestoreState()
    let fans = FakeFanControl()
    let engine = HelperEngine(
        runner: runner,
        state: state,
        fans: fans,
        sleepSettingReader: runner
    )
    let sleepRegistry = SleepModeGenerationRegistry()
    let awdlRegistry = SleepModeGenerationRegistry()
    let fanRegistry = SleepModeGenerationRegistry()

    func setSleep(client: Int, generation: UInt64, mode: SleepHoldMode) -> Bool {
        sleepRegistry.apply(
            streamID: "sleep-stream",
            generation: generation,
            clientID: client
        ) { previousClientID in
            engine.setSleepHoldMode(
                client: client,
                replacing: previousClientID,
                mode: mode
            )
        }
    }
    func setAWDL(client: Int, generation: UInt64, holding: Bool) -> Bool {
        awdlRegistry.apply(
            streamID: "awdl-stream",
            generation: generation,
            clientID: client
        ) { previousClientID in
            engine.setAWDLHold(
                client: client,
                replacing: previousClientID,
                holding: holding
            )
        }
    }
    func setFan(client: Int, generation: UInt64, holding: Bool) -> Bool {
        fanRegistry.apply(
            streamID: "fan-stream",
            generation: generation,
            clientID: client
        ) { previousClientID in
            engine.setFanHold(
                client: client,
                replacing: previousClientID,
                holding: holding,
                percent: 80
            )
        }
    }

    #expect(setSleep(client: 1, generation: 1, mode: .active))
    #expect(setAWDL(client: 1, generation: 1, holding: true))
    #expect(setFan(client: 1, generation: 1, holding: true))
    #expect(runner.commands == [sleepOn, awdlDown])
    #expect(fans.forcedPercents == [80])

    // Reconnect B retries the same intent. Each logical holder moves from A
    // to B without a second union edge or a duplicate fan write.
    #expect(setSleep(client: 2, generation: 1, mode: .active))
    #expect(setAWDL(client: 2, generation: 1, holding: true))
    #expect(setFan(client: 2, generation: 1, holding: true))
    #expect(runner.commands == [sleepOn, awdlDown])
    #expect(fans.forcedPercents == [80])

    sleepRegistry.clientDisconnected(1) { engine.sleepClientDisconnected(1) }
    awdlRegistry.clientDisconnected(1) { engine.awdlClientDisconnected(1) }
    fanRegistry.clientDisconnected(1) { engine.fanClientDisconnected(1) }
    #expect(runner.commands == [sleepOn, awdlDown])
    #expect(fans.restoreCalls == 0)

    // The newest releases win. A delayed generation-1 replay cannot revive
    // any of the three privileged holds afterward.
    #expect(setSleep(client: 2, generation: 2, mode: .released))
    #expect(setAWDL(client: 2, generation: 2, holding: false))
    #expect(setFan(client: 2, generation: 2, holding: false))
    #expect(runner.commands == [sleepOn, awdlDown, sleepOff, awdlUp])
    #expect(fans.restoreCalls == 1)

    #expect(!setSleep(client: 1, generation: 1, mode: .active))
    #expect(!setAWDL(client: 1, generation: 1, holding: true))
    #expect(!setFan(client: 1, generation: 1, holding: true))
    #expect(runner.commands == [sleepOn, awdlDown, sleepOff, awdlUp])
    #expect(fans.forcedPercents == [80])
    #expect(engine.isIdle)
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

    // Another client gets a fresh chance, but cannot erase client 1's
    // surrendered status. Client 1 must explicitly release before retrying.
    fans.results = []
    #expect(engine.setFanHold(client: 2, holding: true, percent: 50))
    #expect(!engine.fanHoldDropped(client: 2))
    #expect(engine.fanHoldDropped(client: 1))
    #expect(engine.fanHoldDropped)
    #expect(!engine.setFanHold(client: 1, holding: true, percent: 80))
    #expect(engine.setFanHold(client: 1, holding: false, percent: 0))
    #expect(!engine.fanHoldDropped)
}

@Test func surrenderedFanStatusMigratesAcrossReconnectUntilExplicitRelease() {
    let fans = FakeFanControl()
    let engine = HelperEngine(runner: FakeRunner(), state: FakeRestoreState(), fans: fans)
    let registry = SleepModeGenerationRegistry()

    #expect(registry.apply(
        streamID: "fan-stream",
        generation: 1,
        clientID: 1
    ) { previousClientID in
        engine.setFanHold(
            client: 1,
            replacing: previousClientID,
            holding: true,
            percent: 80
        )
    })
    fans.results = Array(repeating: .failed, count: HelperEngine.maxFanFailures)
    for _ in 0..<HelperEngine.maxFanFailures { engine.fanTick() }
    #expect(engine.fanHoldDropped(client: 1))

    registry.clientDisconnected(1) { engine.fanClientDisconnected(1) }
    // Reconnect B replays the exact acquire generation. Registry ownership
    // migrates, but the engine refuses to revive the surrendered hold.
    #expect(!registry.apply(
        streamID: "fan-stream",
        generation: 1,
        clientID: 2
    ) { previousClientID in
        engine.setFanHold(
            client: 2,
            replacing: previousClientID,
            holding: true,
            percent: 80
        )
    })
    #expect(!engine.fanHoldDropped(client: 1))
    #expect(engine.fanHoldDropped(client: 2))

    #expect(registry.apply(
        streamID: "fan-stream",
        generation: 2,
        clientID: 2
    ) { previousClientID in
        engine.setFanHold(
            client: 2,
            replacing: previousClientID,
            holding: false,
            percent: 0
        )
    })
    #expect(!engine.fanHoldDropped(client: 2))

    fans.results = []
    #expect(registry.apply(
        streamID: "fan-stream",
        generation: 3,
        clientID: 2
    ) { previousClientID in
        engine.setFanHold(
            client: 2,
            replacing: previousClientID,
            holding: true,
            percent: 80
        )
    })
    #expect(!engine.fanHoldDropped(client: 2))
}

@Test func fanSurrenderTracksEveryHolderWithoutBlockingANewClient() {
    let fans = FakeFanControl()
    let engine = HelperEngine(runner: FakeRunner(), state: FakeRestoreState(), fans: fans)
    #expect(engine.setFanHold(client: 1, holding: true, percent: 60))
    #expect(engine.setFanHold(client: 2, holding: true, percent: 80))

    fans.results = Array(repeating: .failed, count: HelperEngine.maxFanFailures)
    for _ in 0..<HelperEngine.maxFanFailures { engine.fanTick() }
    #expect(engine.fanHoldDropped(client: 1))
    #expect(engine.fanHoldDropped(client: 2))

    fans.results = []
    #expect(engine.setFanHold(client: 3, holding: true, percent: 70))
    #expect(!engine.fanHoldDropped(client: 3))
    #expect(!engine.setFanHold(
        client: 4,
        replacing: 2,
        holding: true,
        percent: 80
    ))
    #expect(!engine.fanHoldDropped(client: 2))
    #expect(engine.fanHoldDropped(client: 4))

    #expect(engine.setFanHold(client: 4, holding: false, percent: 0))
    #expect(engine.setFanHold(client: 1, holding: false, percent: 0))
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
