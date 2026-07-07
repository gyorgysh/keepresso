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
