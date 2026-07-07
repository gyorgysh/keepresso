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
    #expect(command.contains("if [ -f \"/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag\" ]"))
    #expect(command.contains("if [ -z \"$SET\" ]; then /usr/bin/pmset -a disablesleep 1"))
    #expect(command.contains("elif [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0"))
    #expect(command.hasSuffix("&"))
    #expect(command.contains("rm -f"))
    #expect(command.contains("if [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0; fi )"))
}

// MARK: - Controller

private final class FakeSleepWatchdogLauncher: SleepWatchdogLaunching, @unchecked Sendable {
    var flagPresent = false
    var result: SleepSettingResult = .applied
    /// Helper spawns, i.e. how often the user was asked for a password.
    var startCalls = 0

    func isFlagPresent() -> Bool { flagPresent }
    func createFlag() -> Bool {
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
