import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Fakes

private final class FakeRunner: HelperCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [String] = []
    var failNext = false

    func run(_ path: String, _ arguments: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        commands.append(([path] + arguments).joined(separator: " "))
        if failNext {
            failNext = false
            return false
        }
        return true
    }
}

private final class FakeRestoreState: HelperRestoreStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<HelperRestoreMarker> = []

    init(_ initial: Set<HelperRestoreMarker> = []) {
        stored = initial
    }

    func markers() -> Set<HelperRestoreMarker> {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ marker: HelperRestoreMarker, present: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if present { stored.insert(marker) } else { stored.remove(marker) }
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
        return true
    }
}

private let sleepOn = "/usr/bin/pmset -a disablesleep 1"
private let sleepOff = "/usr/bin/pmset -a disablesleep 0"
private let awdlDown = "/sbin/ifconfig awdl0 down"
private let awdlUp = "/sbin/ifconfig awdl0 up"

// MARK: - Holds

@Test func sleepHoldWritesOnlyOnUnionEdges() {
    let runner = FakeRunner()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: runner, state: state)

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
    let runner = FakeRunner()
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
    let engine = HelperEngine(runner: runner, state: state)

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

@Test func failedWriteDoesNotRecordARestoreDebt() {
    let runner = FakeRunner()
    let state = FakeRestoreState()
    let engine = HelperEngine(runner: runner, state: state)

    runner.failNext = true
    #expect(!engine.setSleepHold(client: 1, holding: true))
    // The pmset write failed, so there is nothing to restore at next launch.
    #expect(state.markers().isEmpty)
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
    let runner = FakeRunner()
    let state = FakeRestoreState([.sleepDisabled, .awdlDown])
    let engine = HelperEngine(runner: runner, state: state)

    engine.restoreAtLaunch()
    #expect(runner.commands.contains(sleepOff))
    #expect(runner.commands.contains(awdlUp))
    #expect(state.markers().isEmpty)

    // A clean launch restores nothing.
    let cleanRunner = FakeRunner()
    HelperEngine(runner: cleanRunner, state: FakeRestoreState()).restoreAtLaunch()
    #expect(cleanRunner.commands.isEmpty)
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
