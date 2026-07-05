import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Interface state parsing

@Test func awdlParserReadsTheUpFlag() {
    let up = """
    awdl0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tether 96:49:75:46:f0:6a
    """
    #expect(IfconfigAWDLReader.parseIsUp(from: up) == true)

    let down = "awdl0: flags=8862<BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500"
    #expect(IfconfigAWDLReader.parseIsUp(from: down) == false)
}

@Test func awdlParserRefusesToGuess() {
    #expect(IfconfigAWDLReader.parseIsUp(from: nil) == nil)
    #expect(IfconfigAWDLReader.parseIsUp(from: "") == nil)
    #expect(IfconfigAWDLReader.parseIsUp(from: "ifconfig: interface awdl0 does not exist") == nil)
}

// MARK: - Watchdog command shape

@Test func watchdogCommandIsFlagFollowingPidScopedAndSelfRestoring() {
    let command = OsascriptAWDLWatchdog.watchdogCommand(
        flagPath: "/Users/g/Library/Application Support/Keepresso/awdl-watchdog.flag",
        appPID: 4242
    )
    // The helper must live with the app's pid (so a crash tears it down),
    // follow the flag file (down while present, restore once when gone, then
    // idle so re-enabling needs no new prompt), keep re-downing the interface
    // (macOS re-raises it), and background itself so the admin prompt returns.
    #expect(command.contains("kill -0 4242"))
    #expect(command.contains("if [ -f \"/Users/g/Library/Application Support/Keepresso/awdl-watchdog.flag\" ]"))
    #expect(command.contains("/sbin/ifconfig awdl0 down"))
    #expect(command.contains("elif [ -n \"$DOWNED\" ]; then /sbin/ifconfig awdl0 up"))
    #expect(command.contains("sleep 3"))
    #expect(command.hasSuffix("&"))
    #expect(command.contains("rm -f"))
}

@Test func appleScriptEscapingSurvivesQuotedPaths() {
    let escaped = OsascriptAWDLWatchdog.appleScriptEscaped(#"[ -f "/tmp/a flag" ]"#)
    #expect(escaped == #"[ -f \"/tmp/a flag\" ]"#)
}

// MARK: - Controller

private final class FakeWatchdogLauncher: AWDLWatchdogLaunching, @unchecked Sendable {
    var flagPresent = false
    var result: AWDLWatchdogStartResult = .started
    /// Helper spawns, i.e. how often the user was asked for a password.
    var startCalls = 0

    func isFlagPresent() -> Bool { flagPresent }
    func createFlag() -> Bool {
        flagPresent = true
        return true
    }
    func removeFlag() { flagPresent = false }
    func startHelper(appPID: Int32) -> AWDLWatchdogStartResult {
        startCalls += 1
        return result
    }
}

private final class FakeAWDLReader: AWDLStateReading, @unchecked Sendable {
    var up: Bool?
    init(up: Bool?) { self.up = up }
    func isUp() -> Bool? { up }
}

@MainActor
@Test func watchdogControllerStartsAndStops() async {
    let launcher = FakeWatchdogLauncher()
    let controller = AWDLWatchdogController(launcher: launcher, reader: FakeAWDLReader(up: true), appPID: 1)
    #expect(!controller.isRunning)

    let result = await controller.start()
    #expect(result == .started)
    #expect(controller.isRunning)
    #expect(controller.lastError == nil)

    await controller.stop()
    #expect(!controller.isRunning)
    #expect(!launcher.flagPresent)
}

@MainActor
@Test func watchdogPromptsOnlyOncePerAppRun() async {
    // The first activation spawns the helper (the password prompt); every
    // later toggle is flag-file-only.
    let launcher = FakeWatchdogLauncher()
    let controller = AWDLWatchdogController(launcher: launcher, reader: FakeAWDLReader(up: true), appPID: 1)

    _ = await controller.start()
    await controller.stop()
    let again = await controller.start()
    #expect(again == .started)
    #expect(controller.isRunning)
    #expect(launcher.flagPresent)
    #expect(launcher.startCalls == 1)
}

@MainActor
@Test func primeAuthorizesWithoutPausingThenAutoStartIsPromptFree() async {
    // Priming spawns the helper (one prompt) but leaves AWDL up, so a later
    // automatic start during a game needs no prompt and never interrupts play.
    let launcher = FakeWatchdogLauncher()
    let controller = AWDLWatchdogController(launcher: launcher, reader: FakeAWDLReader(up: true), appPID: 1)
    controller.autoWithGaming = true
    #expect(!controller.isAuthorized)

    let result = await controller.prime()
    #expect(result == .started)
    #expect(controller.isAuthorized)
    #expect(controller.isRunning == false)   // AWDL left untouched by priming
    #expect(launcher.flagPresent == false)
    #expect(launcher.startCalls == 1)         // one prompt

    // A game comes forward: auto activation is now a flag write, no new prompt.
    await controller.autoTick(gamingActive: true)
    #expect(controller.isRunning)
    #expect(launcher.startCalls == 1)

    // Priming again is a no-op (already authorized): still no extra prompt.
    _ = await controller.prime()
    #expect(launcher.startCalls == 1)
}

@MainActor
@Test func aCancelledPromptLeavesNoFlagBehind() async {
    // The flag is written before the prompt (the helper reads it on its first
    // cycle); a cancel or failure must clean it up so the next helper start
    // doesn't instantly re-engage.
    let launcher = FakeWatchdogLauncher()
    launcher.result = .cancelled
    let controller = AWDLWatchdogController(launcher: launcher, reader: FakeAWDLReader(up: true), appPID: 1)
    _ = await controller.start()
    #expect(!launcher.flagPresent)
    #expect(!controller.isRunning)

    // The helper never started, so the next attempt prompts again.
    launcher.result = .started
    _ = await controller.start()
    #expect(launcher.startCalls == 2)
    #expect(controller.isRunning)
}

@MainActor
@Test func watchdogControllerSurfacesFailuresButNotCancellations() async {
    let launcher = FakeWatchdogLauncher()
    launcher.result = .failed("no admin rights")
    let controller = AWDLWatchdogController(launcher: launcher, reader: FakeAWDLReader(up: true), appPID: 1)
    _ = await controller.start()
    #expect(controller.lastError == "no admin rights")
    #expect(!controller.isRunning)

    launcher.result = .cancelled
    _ = await controller.start()
    #expect(controller.lastError == nil)
    #expect(!controller.isRunning)
}

@MainActor
@Test func watchdogRefreshReadsFlagAndInterface() async {
    let launcher = FakeWatchdogLauncher()
    launcher.flagPresent = true
    let reader = FakeAWDLReader(up: false)
    let controller = AWDLWatchdogController(launcher: launcher, reader: reader, appPID: 1)
    await controller.refresh()
    #expect(controller.isRunning)
    #expect(controller.isInterfaceUp == false)
}

@MainActor
@Test func autoModeStartsWithGamingAndStopsAfter() async {
    let launcher = FakeWatchdogLauncher()
    let controller = AWDLWatchdogController(launcher: launcher, reader: FakeAWDLReader(up: true), appPID: 1)
    controller.autoWithGaming = true

    await controller.autoTick(gamingActive: true)
    #expect(controller.isRunning)
    #expect(launcher.startCalls == 1)

    // Further gaming ticks don't re-prompt.
    await controller.autoTick(gamingActive: true)
    #expect(launcher.startCalls == 1)

    await controller.autoTick(gamingActive: false)
    #expect(!controller.isRunning)
}

@MainActor
@Test func autoModeRespectsACancelUntilTheBoutEnds() async {
    let launcher = FakeWatchdogLauncher()
    launcher.result = .cancelled
    let controller = AWDLWatchdogController(launcher: launcher, reader: FakeAWDLReader(up: true), appPID: 1)
    controller.autoWithGaming = true

    await controller.autoTick(gamingActive: true)
    await controller.autoTick(gamingActive: true)
    #expect(launcher.startCalls == 1) // cancelled once, not nagged again

    // A new bout may ask once more.
    await controller.autoTick(gamingActive: false)
    launcher.result = .started
    await controller.autoTick(gamingActive: true)
    #expect(launcher.startCalls == 2)
    #expect(controller.isRunning)
}

@MainActor
@Test func autoModeNeverStopsAManualRun() async {
    let launcher = FakeWatchdogLauncher()
    let controller = AWDLWatchdogController(launcher: launcher, reader: FakeAWDLReader(up: true), appPID: 1)
    controller.autoWithGaming = true

    _ = await controller.start() // manual
    await controller.autoTick(gamingActive: false)
    #expect(controller.isRunning)
}

@MainActor
@Test func autoModeDoesNothingWhenOff() async {
    let launcher = FakeWatchdogLauncher()
    let controller = AWDLWatchdogController(launcher: launcher, reader: FakeAWDLReader(up: true), appPID: 1)
    await controller.autoTick(gamingActive: true)
    #expect(launcher.startCalls == 0)
}

// MARK: - Settings

@Test func awdlAutoSettingDefaultsOffAndRoundTrips() throws {
    let empty = try JSONDecoder().decode(KeepressoSettings.self, from: "{}".data(using: .utf8)!)
    #expect(!empty.awdlAutoWithGaming)

    var settings = KeepressoSettings.default
    settings.awdlAutoWithGaming = true
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.awdlAutoWithGaming)
}
