import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Watchdog command shape

@Test func sleepWatchdogCommandIsFlagFollowingPidScopedAndSelfRestoring() {
    let command = OsascriptSleepWatchdog.watchdogCommand(
        flagPath: "/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag",
        appPID: 4242
    )
    // The helper must live with the app's pid (so a crash restores normal
    // sleep), follow the flag file, and background itself so the admin prompt
    // returns. Unlike the AWDL loop it must be edge-triggered: it writes
    // `disablesleep` only on a flag transition, so it never fights the user's
    // own manual toggle, and on exit restores sleep only if it disabled it.
    #expect(command.contains("kill -0 4242"))
    // The flag path is single-quoted so it stays one literal word to /bin/sh.
    #expect(command.contains("if [ -f '/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag' ]"))
    #expect(command.contains("if [ -z \"$SET\" ]; then /usr/bin/pmset -a disablesleep 1"))
    #expect(command.contains("elif [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0"))
    #expect(command.hasSuffix("&"))
    #expect(command.contains("rm -f '/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag'"))
    #expect(command.contains("if [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0; fi )"))
}

@Test func sleepWatchdogSingleQuotesAHostileFlagPath() {
    let hostile = #"/tmp/$(touch /tmp/pwned)/".flag"#
    let command = OsascriptSleepWatchdog.watchdogCommand(flagPath: hostile, appPID: 1)
    #expect(command.contains(OsascriptAWDLWatchdog.shellSingleQuoted(hostile)))
    #expect(!command.contains("[ -f \"")) // never double-quoted around the path
}

// MARK: - Controller

private final class FakeSleepWatchdogLauncher: SleepWatchdogLaunching, @unchecked Sendable {
    var flagPresent = false
    var result: SleepSettingResult = .applied
    var createFlagSucceeds = true
    var engageFailureMessage = "backend says no"
    /// Helper spawns, i.e. how often the user was asked for a password.
    var startCalls = 0

    func isFlagPresent() -> Bool { flagPresent }
    func createFlag() -> Bool {
        guard createFlagSucceeds else { return false }
        flagPresent = true
        return true
    }
    func removeFlag() { flagPresent = false }
    func startHelper(appPID: Int32) -> SleepSettingResult {
        startCalls += 1
        return result
    }
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

    // Further brewing ticks don't re-prompt.
    await controller.autoTick(brewing: true)
    #expect(launcher.startCalls == 1)

    await controller.autoTick(brewing: false)
    #expect(!controller.isHolding)
    #expect(!launcher.flagPresent)
}

@MainActor
@Test func closedDisplayAutoPromptsOnlyOncePerAppRun() async {
    // The first engage spawns the helper (the password prompt); every later
    // session start and stop is flag-file-only.
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
    // Priming (from the Preferences toggle) spawns the helper but leaves the
    // sleep setting alone, so the engage at the next session start is a
    // prompt-free flag write.
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true
    #expect(!controller.isAuthorized)

    let result = await controller.prime()
    #expect(result == .applied)
    #expect(controller.isAuthorized)
    #expect(controller.isHolding == false)   // sleep setting left untouched
    #expect(launcher.flagPresent == false)
    #expect(launcher.startCalls == 1)         // one prompt

    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
    #expect(launcher.startCalls == 1)

    // Priming again is a no-op (already authorized): still no extra prompt.
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
    #expect(launcher.startCalls == 1) // cancelled once, not nagged again
    #expect(!launcher.flagPresent)    // no flag left for a later helper to obey

    // A new session may ask once more.
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
    // The daemon-backed launcher fails in XPC, not on a file write; the
    // controller must not claim a flag file was the problem.
    let launcher = FakeSleepWatchdogLauncher()
    launcher.createFlagSucceeds = false
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    #expect(controller.lastError == "backend says no")
    #expect(!controller.isHolding)
}

@MainActor
@Test func retryEngageLetsAFailedEngageTryAgainMidSession() async {
    // A failed engage normally holds off until the session ends; after an
    // external fix (the helper daemon was repaired) retryEngage lets the next
    // tick try again within the same session.
    let launcher = FakeSleepWatchdogLauncher()
    launcher.createFlagSucceeds = false
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    await controller.autoTick(brewing: true)
    #expect(!controller.isHolding)

    launcher.createFlagSucceeds = true
    await controller.autoTick(brewing: true) // still held off, no engage
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

    await controller.stopIfHolding() // nothing held: a no-op
    #expect(launcher.startCalls == 0)

    await controller.autoTick(brewing: true)
    #expect(controller.isHolding)
    await controller.stopIfHolding() // the feature was switched off mid-session
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

// MARK: - Authority over a hold the automation didn't take

@Test func idleClearsAHoldTheAutomationDidntTake() {
    // The setting is on with no automation hold and no session: "only while
    // brewing" owns it, so idle must mean off.
    #expect(ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: false, automationHolding: false,
        settingIsOn: true, canApply: true
    ))
}

@Test func nothingIsClearedWhileTheAutomationOwnsTheHold() {
    // Mid-session the automation's own hold is released the normal way.
    #expect(!ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: true, automationHolding: true,
        settingIsOn: true, canApply: true
    ))
    // Idle with our own hold still up: the release is what drops it.
    #expect(!ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: false, automationHolding: true,
        settingIsOn: true, canApply: true
    ))
}

@Test func aForeignHoldSurvivesUntilTheSessionEnds() {
    // During a session a foreign hold is doing the same job; clearing it there
    // would drop clamshell protection mid-brew. The next idle tick gets it.
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
    // The host has already spent its one password prompt for this app run and
    // has no helper daemon to write silently: nothing to do until it can.
    #expect(!ClosedDisplayAuthority.shouldClearForeignHold(
        onlyWhileBrewing: true, brewing: false, automationHolding: false,
        settingIsOn: true, canApply: false
    ))
}

// MARK: - Battery pause lifts sticky closed-display

@Test func batteryPauseLiftsStickyClosedDisplay() {
    #expect(BatteryPauseClosedDisplay.decide(
        paused: true, onlyWhileBrewing: false, settingIsOn: true,
        alreadyLifted: false, helperInstalled: true
    ) == .lift)
}

@Test func batteryPauseLeavesOnlyWhileBrewingAlone() {
    // Session-tied closed-display already releases with the pause.
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
    // A failed write or another feature restoring the setting mid-pause must
    // not leave disablesleep on for the rest of the battery pause.
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
    // Once the host has explained, don't nag every tick.
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

// MARK: - Settings

@Test func closedDisplayOnlyWhileBrewingDefaultsOffAndRoundTrips() throws {
    let empty = try JSONDecoder().decode(KeepressoSettings.self, from: "{}".data(using: .utf8)!)
    #expect(!empty.closedDisplayOnlyWhileBrewing)

    var settings = KeepressoSettings.default
    settings.closedDisplayOnlyWhileBrewing = true
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.closedDisplayOnlyWhileBrewing)
}
