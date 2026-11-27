import Testing
import Foundation
@testable import KeepressoCore


@Test func sleepWatchdogCommandIsFlagFollowingPidScopedAndSelfRestoring() {
    let command = OsascriptSleepWatchdog.watchdogCommand(
        flagPath: "/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag",
        appPID: 4242
    )
    #expect(command.contains("kill -0 4242"))
    #expect(command.contains("if [ -f '/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag' ]"))
    #expect(command.contains("if [ -z \"$SET\" ]; then /usr/bin/pmset -a disablesleep 1"))
    #expect(command.contains("elif [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0"))
    #expect(command.hasSuffix("&"))
    #expect(command.contains(
        "if [ \"$(cat '/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag' 2>/dev/null)\" = \"4242\" ]; "
            + "then rm -f '/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag'; fi; "))
    #expect(command.contains("if [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0; fi )"))
}

private struct WatchdogHarness {
    let dir: URL
    let flagURL: URL
    let logURL: URL
    let app = Process()

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepresso-watchdog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        flagURL = dir.appendingPathComponent("sleep-watchdog.flag")
        logURL = dir.appendingPathComponent("pmset.log")
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["60"]
        try app.run()
    }

    var appPID: Int32 { app.processIdentifier }

    func startLoop() throws {
        let command = OsascriptSleepWatchdog.watchdogCommand(flagPath: flagURL.path, appPID: appPID)
            .replacingOccurrences(
                of: "/usr/bin/pmset -a disablesleep",
                with: "/bin/echo >>\(OsascriptAWDLWatchdog.shellSingleQuoted(logURL.path))")
            .replacingOccurrences(of: "sleep 2", with: "sleep 0.1")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        try shell.run()
        shell.waitUntilExit()
    }

    var writes: [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func waitForWrites(_ expected: [String]) async -> Bool {
        for _ in 0..<100 {
            if writes == expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func quitApp() {
        app.terminate()
        app.waitUntilExit()
    }

    func cleanUp() {
        if app.isRunning { quitApp() }
        try? FileManager.default.removeItem(at: dir)
    }
}

@Test func sleepWatchdogLeavesARelaunchedAppsFlagAloneOnExit() async throws {
    let harness = try WatchdogHarness()
    defer { harness.cleanUp() }
    let oldRun = OsascriptSleepWatchdog(flagURL: harness.flagURL, ownerPID: harness.appPID)
    #expect(oldRun.createFlag())
    try harness.startLoop()
    #expect(await harness.waitForWrites(["1"]))

    harness.quitApp()
    let newRun = OsascriptSleepWatchdog(flagURL: harness.flagURL, ownerPID: harness.appPID + 1)
    #expect(newRun.createFlag())

    #expect(await harness.waitForWrites(["1", "0"]))
    #expect(newRun.isFlagPresent())
}

@Test func sleepWatchdogRemovesItsOwnFlagOnExit() async throws {
    let harness = try WatchdogHarness()
    defer { harness.cleanUp() }
    let run = OsascriptSleepWatchdog(flagURL: harness.flagURL, ownerPID: harness.appPID)
    #expect(run.createFlag())
    try harness.startLoop()
    #expect(await harness.waitForWrites(["1"]))

    harness.quitApp()
    #expect(await harness.waitForWrites(["1", "0"]))
    #expect(!run.isFlagPresent())
}

@Test func sleepWatchdogSingleQuotesAHostileFlagPath() {
    let hostile = #"/tmp/$(touch /tmp/pwned)/".flag"#
    let command = OsascriptSleepWatchdog.watchdogCommand(flagPath: hostile, appPID: 1)
    #expect(command.contains(OsascriptAWDLWatchdog.shellSingleQuoted(hostile)))
    #expect(!command.contains("[ -f \""))
}


private final class FakeSleepWatchdogLauncher: SleepWatchdogLaunching, @unchecked Sendable {
    var flagPresent = false
    var result: SleepSettingResult = .applied
    var createFlagSucceeds = true
    var removeClearsFlag = true
    var engageFailureMessage = "backend says no"
    var startCalls = 0

    func isFlagPresent() -> Bool { flagPresent }
    func createFlag() -> Bool {
        guard createFlagSucceeds else { return false }
        flagPresent = true
        return true
    }
    func removeFlag() {
        if removeClearsFlag { flagPresent = false }
    }
    func startHelper(appPID: Int32) -> SleepSettingResult {
        startCalls += 1
        return result
    }
}

@MainActor
@Test func closedDisplayAutoRetakesAHoldWhoseFlagWentMissing() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true
    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)

    launcher.flagPresent = false
    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
    #expect(launcher.flagPresent)
    #expect(launcher.startCalls == 1)
}

@MainActor
@Test func closedDisplayAutoFollowsTheSession() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
    #expect(launcher.flagPresent)
    #expect(launcher.startCalls == 1)

    await controller.autoTick(brewing: true)
    #expect(launcher.startCalls == 1)

    await controller.autoTick(brewing: false)
    #expect(!controller.isHolding)
    #expect(!launcher.flagPresent)
}

@MainActor
@Test func closedDisplayAutoKeepsHoldingWhenReleaseDoesNotClearTheFlag() async {
    let launcher = FakeSleepWatchdogLauncher()
    launcher.removeClearsFlag = false
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
    #expect(launcher.flagPresent)

    await controller.autoTick(brewing: false)
    #expect(controller.isHolding)
    #expect(launcher.flagPresent)
}

@MainActor
@Test func closedDisplayAutoPromptsOnlyOncePerAppRun() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    await controller.autoTick(brewing: false)
    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
    #expect(launcher.startCalls == 1)
}

@MainActor
@Test func primeAuthorizesWithoutDisablingSleep() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true
    #expect(!controller.isAuthorized)

    let result = await controller.prime()
    #expect(result == .applied)
    #expect(controller.isAuthorized)
    #expect(controller.isHolding == false)
    #expect(launcher.flagPresent == false)
    #expect(launcher.startCalls == 1)

    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
    #expect(launcher.startCalls == 1)

    _ = await controller.prime()
    #expect(launcher.startCalls == 1)
}

@MainActor
@Test func aCancelledPromptHoldsOffUntilTheSessionEnds() async {
    let launcher = FakeSleepWatchdogLauncher()
    launcher.result = .cancelled
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    await controller.autoTick(brewing: true)
    #expect(launcher.startCalls == 1)
    #expect(!launcher.flagPresent)

    await controller.autoTick(brewing: false)
    launcher.result = .applied
    await controller.autoTick(brewing: true)
    #expect(launcher.startCalls == 2)
    #expect(controller.isHolding)
}

@MainActor
@Test func closedDisplayAutoSurfacesFailuresButNotCancellations() async {
    let launcher = FakeSleepWatchdogLauncher()
    launcher.result = .failed("no admin rights")
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    #expect(controller.lastError == "no admin rights")
    #expect(!controller.isHolding)

    launcher.result = .cancelled
    await controller.autoTick(brewing: false)
    await controller.autoTick(brewing: true)
    #expect(controller.lastError == nil)
    #expect(!controller.isHolding)
}

@MainActor
@Test func aFailedEngageSurfacesTheLaunchersOwnMessage() async {
    let launcher = FakeSleepWatchdogLauncher()
    launcher.createFlagSucceeds = false
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    #expect(controller.lastError == "backend says no")
    #expect(!controller.isHolding)
}

@MainActor
@Test func retryEngageLeavesACancelledPromptAlone() async {
    let launcher = FakeSleepWatchdogLauncher()
    launcher.result = .cancelled
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    #expect(!controller.isHolding)
    #expect(launcher.startCalls == 1)

    launcher.result = .applied
    controller.retryEngage()
    await controller.autoTick(brewing: true)
    #expect(!controller.isHolding)
    #expect(launcher.startCalls == 1)

    await controller.autoTick(brewing: false)
    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
}

@MainActor
@Test func retryEngageLetsAFailedEngageTryAgainMidSession() async {
    let launcher = FakeSleepWatchdogLauncher()
    launcher.createFlagSucceeds = false
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    await controller.autoTick(brewing: true)
    #expect(!controller.isHolding)

    launcher.createFlagSucceeds = true
    await controller.autoTick(brewing: true)
    #expect(!controller.isHolding)

    controller.retryEngage()
    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
    #expect(controller.lastError == nil)
}

@MainActor
@Test func stopIfHoldingReleasesAndIsSafeWhenIdle() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.stopIfHolding()
    #expect(launcher.startCalls == 0)

    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
    await controller.stopIfHolding()
    #expect(!controller.isHolding)
    #expect(!launcher.flagPresent)
}

@MainActor
@Test func closedDisplayAutoDoesNothingWhenOff() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    await controller.autoTick(brewing: true)
    #expect(launcher.startCalls == 0)
    #expect(!launcher.flagPresent)
}

@MainActor
@Test func cleanupAtLaunchRemovesAStaleFlag() async {
    let launcher = FakeSleepWatchdogLauncher()
    launcher.flagPresent = true
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    await controller.cleanupAtLaunch()
    #expect(!launcher.flagPresent)
}


@Test func idleClearsAHoldTheAutomationDidntTake() {
    #expect(ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: false, automationHolding: false,
        settingIsOn: true, canApply: true
    ))
}

@Test func nothingIsClearedWhileTheAutomationOwnsTheHold() {
    #expect(!ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: true, automationHolding: true,
        settingIsOn: true, canApply: true
    ))
    #expect(!ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: false, automationHolding: true,
        settingIsOn: true, canApply: true
    ))
}

@Test func aForeignHoldSurvivesUntilTheSessionEnds() {
    #expect(!ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: true, automationHolding: false,
        settingIsOn: true, canApply: true
    ))
}

@Test func nothingIsClearedWithTheFeatureOffOrTheSettingAlreadyOff() {
    #expect(!ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: false, brewing: false, automationHolding: false,
        settingIsOn: true, canApply: true
    ))
    #expect(!ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: false, automationHolding: false,
        settingIsOn: false, canApply: true
    ))
}

@Test func noWayToWriteMeansNoClear() {
    #expect(!ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: false, automationHolding: false,
        settingIsOn: true, canApply: false
    ))
}


@Test func batteryPauseLiftsStickyClosedDisplay() {
    #expect(BatteryPauseClosedDisplay.decide(
        paused: true, onlyWhileBrewing: false, settingIsOn: true,
        alreadyLifted: false, helperInstalled: true
    ) == .lift)
}

@Test func batteryPauseLeavesOnlyWhileBrewingAlone() {
    #expect(BatteryPauseClosedDisplay.decide(
        paused: true, onlyWhileBrewing: true, settingIsOn: true,
        alreadyLifted: false, helperInstalled: true
    ) == .idle)
}

@Test func batteryPauseIsIdleOnceClosedDisplayIsOff() {
    #expect(BatteryPauseClosedDisplay.decide(
        paused: true, onlyWhileBrewing: false, settingIsOn: false,
        alreadyLifted: true, helperInstalled: true
    ) == .idle)
}

@Test func batteryPauseReassertsLiftIfClosedDisplayComesBackOn() {
    #expect(BatteryPauseClosedDisplay.decide(
        paused: true, onlyWhileBrewing: false, settingIsOn: true,
        alreadyLifted: true, helperInstalled: true
    ) == .lift)
}

@Test func batteryPauseWithoutHelperAsksTheHostToExplain() {
    #expect(BatteryPauseClosedDisplay.decide(
        paused: true, onlyWhileBrewing: false, settingIsOn: true,
        alreadyLifted: false, helperInstalled: false
    ) == .skipLiftNeedsHelper)
    #expect(BatteryPauseClosedDisplay.decide(
        paused: true, onlyWhileBrewing: false, settingIsOn: true,
        alreadyLifted: true, helperInstalled: false
    ) == .idle)
}

@Test func batteryPauseRestoresStickyClosedDisplayWhenItLifts() {
    #expect(BatteryPauseClosedDisplay.decide(
        paused: false, onlyWhileBrewing: false, settingIsOn: false,
        alreadyLifted: true, helperInstalled: true
    ) == .restore)
    #expect(BatteryPauseClosedDisplay.decide(
        paused: false, onlyWhileBrewing: false, settingIsOn: false,
        alreadyLifted: false, helperInstalled: true
    ) == .idle)
}

@Test func batteryPauseDoesNothingWhenClosedDisplayIsAlreadyOff() {
    #expect(BatteryPauseClosedDisplay.decide(
        paused: true, onlyWhileBrewing: false, settingIsOn: false,
        alreadyLifted: false, helperInstalled: true
    ) == .idle)
}


@Test func closedDisplayOnlyWhileBrewingDefaultsOffAndRoundTrips() throws {
    let empty = try JSONDecoder().decode(KeepressoSettings.self, from: "{}".data(using: .utf8)!)
    #expect(!empty.closedDisplayOnlyWhileBrewing)

    var settings = KeepressoSettings.default
    settings.closedDisplayOnlyWhileBrewing = true
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.closedDisplayOnlyWhileBrewing)
}


@Test func quitModalCoversWhatQuittingWouldOrphan() {
    typealias Q = QuitSleepCheck
    #expect(Q.coverage(brewing: false, overrideLive: false) == .none)
    #expect(Q.coverage(brewing: true, overrideLive: false) == .session)
    #expect(Q.coverage(brewing: false, overrideLive: true) == .overrideLive)
    #expect(Q.coverage(brewing: true, overrideLive: true) == .sessionAndOverride)
}

@Test func quitModalTreatsAScopedHoldAsNothingToAskAbout() {
    typealias Q = QuitSleepCheck
    #expect(Q.coverage(brewing: true, overrideLive: false) == .session)
    #expect(Q.coverage(brewing: false, overrideLive: false) == .none)
}
