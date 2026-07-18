import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Watchdog command shape

@Test func sleepWatchdogCommandIsFlagFollowingPidScopedAndSelfRestoring() {
    let command = OsascriptSleepWatchdog.watchdogCommand(
        flagPath: "/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag",
        appPID: 4242
    )
    // The helper must live with the app's pid, validate fixed mode literals,
    // acknowledge a generation only after readback, and keep retrying restore
    // after the app exits until the original value is confirmed.
    #expect(command.contains("kill -0 4242"))
    #expect(command.contains("if [ -f '/Users/g/Library/Application Support/Keepresso/sleep-watchdog.flag' ]"))
    #expect(command.contains("IFS=' ' read -r GEN WANT"))
    #expect(command.contains("active|thermallySuspended|released"))
    #expect(command.contains("OUT=$(/usr/bin/pmset -g"))
    #expect(command.contains("OBS=; OUT=$(/usr/bin/pmset -g"))
    #expect(command.contains("tolower($1) == \"sleepdisabled\""))
    #expect(command.contains("tolower($1) == \"disablesleep\""))
    #expect(command.contains("if (!found) exit 1"))
    #expect(command.contains("else APPLIED=; fi"))
    #expect(command.contains("WANT\" = thermallySuspended"))
    #expect(command.contains("TARGET=0"))
    #expect(command.contains("printf '%s %s\\n' \"$GEN\" \"$WANT\""))
    #expect(command.contains("if [ -z \"$ALIVE\" ] && [ -z \"$SET\" ]; then break"))
    #expect(command.hasSuffix("&"))
    #expect(command.contains("/var/run/sh.gyorgy.keepresso.sleep-4242.ack"))
    #expect(command.contains("chmod 644"))
}

@Test func sleepWatchdogShellQuotesPathsThatContainSyntax() {
    let command = OsascriptSleepWatchdog.watchdogCommand(
        flagPath: "/tmp/keepresso '$(touch injected)' flag",
        ackPath: "/var/run/keepresso 'ack'",
        appPID: 4242
    )
    #expect(command.contains("'/tmp/keepresso '\"'\"'$(touch injected)'\"'\"' flag'"))
    #expect(command.contains("'/var/run/keepresso '\"'\"'ack'\"'\"''"))
    #expect(!command.contains("\"/tmp/keepresso '$(touch injected)' flag\""))
}

@Test func sleepWatchdogRejectsStaleOrWrongModeAcknowledgements() {
    let expected = "generation-b thermallySuspended"
    #expect(OsascriptSleepWatchdog.acknowledgementMatches(
        "generation-b thermallySuspended\n",
        expected: expected
    ))
    #expect(!OsascriptSleepWatchdog.acknowledgementMatches(
        "generation-a thermallySuspended\n",
        expected: expected
    ))
    #expect(!OsascriptSleepWatchdog.acknowledgementMatches(
        "generation-b active\n",
        expected: expected
    ))
}

// MARK: - Controller

@Test func scopedSleepModesHaveStableProtocolValues() {
    #expect(SleepHoldMode(rawValue: 0) == .released)
    #expect(SleepHoldMode(rawValue: 1) == .active)
    #expect(SleepHoldMode(rawValue: 2) == .thermallySuspended)
}

@Test func activeAgentReadinessRequiresAConfirmedScopedHold() {
    #expect(ClosedLidProtectionReadiness.resolve(
        hasUnattendedDemand: false,
        helperReady: true,
        automaticHoldActive: false
    ))
    #expect(!ClosedLidProtectionReadiness.resolve(
        hasUnattendedDemand: true,
        helperReady: true,
        automaticHoldActive: false
    ))
    #expect(ClosedLidProtectionReadiness.resolve(
        hasUnattendedDemand: true,
        helperReady: true,
        automaticHoldActive: true
    ))
    #expect(!ClosedLidProtectionReadiness.resolve(
        hasUnattendedDemand: true,
        helperReady: false,
        automaticHoldActive: false,
        manualProtectionActive: true
    ))
}

private final class FakeSleepWatchdogLauncher: SleepWatchdogLaunching, @unchecked Sendable {
    var flagPresent = false
    var result: SleepSettingResult = .applied
    var createFlagSucceeds = true
    var engageFailureMessage = "backend says no"
    private(set) var modes: [SleepHoldMode] = []
    private var started = false
    /// Helper spawns, i.e. how often the user was asked for a password.
    var startCalls = 0
    var removeCalls = 0

    func isFlagPresent() -> Bool { flagPresent }
    func createFlag() -> Bool {
        guard createFlagSucceeds else { return false }
        flagPresent = true
        return true
    }
    func removeFlag() {
        flagPresent = false
        removeCalls += 1
    }
    func setMode(_ mode: SleepHoldMode) -> Bool {
        modes.append(mode)
        guard createFlagSucceeds else { return false }
        flagPresent = mode != .released
        if mode == .released { removeCalls += 1 }
        return true
    }
    func startHelper(appPID: Int32) -> SleepSettingResult {
        if started { return .applied }
        startCalls += 1
        if result == .applied { started = true }
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
@Test func closedDisplayAutoScopesVerifiedManualProtectionAsRestoreBaseline() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true, sleepAlreadyDisabled: true)
    #expect(controller.isHolding)
    #expect(!controller.isUsingManualProtection)
    #expect(launcher.startCalls == 1)

    // Once scoped, a transiently unreadable global state cannot drop the
    // automatic owner or create a manual-to-automatic handoff gap.
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: nil)
    #expect(controller.isHolding)
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(controller.isHolding)
    #expect(!controller.isUsingManualProtection)
}

@MainActor
@Test func thermalSuspensionHardGatesAutomaticReengage() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(controller.confirmedMode == .active)

    controller.requestThermalSuspend()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(!controller.isHolding)
    #expect(controller.confirmedMode == .thermallySuspended)

    let activeRequestsBefore = launcher.modes.count { $0 == .active }
    for _ in 0..<100 {
        await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    }
    #expect(launcher.modes.count { $0 == .active } == activeRequestsBefore)

    controller.requestThermalResume()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(controller.isHolding)
}

@MainActor
@Test func thermalSuspensionCanCaptureManualOnlyStateAndRestoreIt() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)

    controller.requestThermalSuspend()
    await controller.autoTick(brewing: false, sleepAlreadyDisabled: true)
    #expect(controller.confirmedMode == .thermallySuspended)

    controller.requestThermalResume()
    await controller.autoTick(brewing: false, sleepAlreadyDisabled: false)
    #expect(controller.confirmedMode == .released)
    #expect(Array(launcher.modes.suffix(2)) == [.thermallySuspended, .released])
}

@MainActor
@Test func batterySafetySuspendsAgentDemandUntilBackendRecovery() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(controller.hasConfirmedAutomaticProtection)
    controller.requestBatterySuspend()
    #expect(!controller.hasConfirmedAutomaticProtection)
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: true)
    #expect(controller.isBatterySuspended)
    #expect(controller.confirmedMode == .thermallySuspended)

    controller.requestBatteryResume()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(!controller.isBatterySuspended)
    #expect(controller.confirmedMode == .active)
    #expect(Array(launcher.modes.suffix(3)) == [
        .active, .thermallySuspended, .active
    ])
}

@MainActor
@Test func batteryAndThermalSafetyComposeBeforeAgentDemandResumes() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    controller.requestBatterySuspend()
    controller.requestThermalSuspend()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: true)

    controller.requestBatteryResume()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(controller.isSafetySuspended)
    #expect(controller.confirmedMode == .thermallySuspended)

    controller.requestThermalResume()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(!controller.isSafetySuspended)
    #expect(controller.confirmedMode == .active)
}

@MainActor
@Test func batteryRecoveryFailureKeepsTheSafetyLatchClosed() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    controller.requestBatterySuspend()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: true)

    launcher.createFlagSucceeds = false
    controller.requestBatteryResume()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(controller.isBatterySuspended)
    #expect(controller.confirmedMode == .thermallySuspended)
    #expect(controller.hasScopedTransaction)

    launcher.createFlagSucceeds = true
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(!controller.isBatterySuspended)
    #expect(controller.confirmedMode == .active)
}

@MainActor
@Test func renewedHeatSupersedesAPendingThermalResume() async {
    let launcher = FakeSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)
    #expect(controller.hasConfirmedAutomaticProtection)
    controller.requestThermalSuspend()
    #expect(!controller.hasConfirmedAutomaticProtection)
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: true)
    controller.requestThermalResume()
    controller.requestThermalSuspend()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)

    #expect(controller.isThermallySuspended)
    #expect(controller.confirmedMode == .thermallySuspended)
}

private final class BlockingSleepWatchdogLauncher: SleepWatchdogLaunching, @unchecked Sendable {
    let activeEntered = DispatchSemaphore(value: 0)
    let allowActiveToFinish = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var modes: [SleepHoldMode] = []

    func isFlagPresent() -> Bool { true }
    func createFlag() -> Bool { setMode(.active) }
    func removeFlag() { _ = setMode(.released) }
    func startHelper(appPID: Int32) -> SleepSettingResult { .applied }
    func setMode(_ mode: SleepHoldMode) -> Bool {
        lock.lock()
        modes.append(mode)
        lock.unlock()
        if mode == .active {
            activeEntered.signal()
            _ = allowActiveToFinish.wait(timeout: .now() + 2)
        }
        return true
    }

    var recordedModes: [SleepHoldMode] {
        lock.lock()
        defer { lock.unlock() }
        return modes
    }
}

private final class BlockingReleaseSleepWatchdogLauncher: SleepWatchdogLaunching, @unchecked Sendable {
    let releaseEntered = DispatchSemaphore(value: 0)
    let allowReleaseToFinish = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var modes: [SleepHoldMode] = []

    func isFlagPresent() -> Bool { true }
    func createFlag() -> Bool { setMode(.active) }
    func removeFlag() { _ = setMode(.released) }
    func startHelper(appPID: Int32) -> SleepSettingResult { .applied }
    func setMode(_ mode: SleepHoldMode) -> Bool {
        lock.lock()
        modes.append(mode)
        lock.unlock()
        if mode == .released {
            releaseEntered.signal()
            _ = allowReleaseToFinish.wait(timeout: .now() + 2)
        }
        return true
    }

    var recordedModes: [SleepHoldMode] {
        lock.lock()
        defer { lock.unlock() }
        return modes
    }
}

@MainActor
@Test func inFlightEngageConvergesToAConcurrentThermalSuspend() async {
    let launcher = BlockingSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    controller.updateAutomaticDemand(brewing: true, sleepAlreadyDisabled: false)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(launcher.activeEntered.wait(timeout: .now() + 1) == .success)
    controller.requestThermalSuspend()
    launcher.allowActiveToFinish.signal()
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)

    #expect(controller.confirmedMode == .thermallySuspended)
    #expect(Array(launcher.recordedModes.suffix(2)) == [.active, .thermallySuspended])
}

@MainActor
@Test func staleInFlightEngageIsCompensatedWhenDemandReturnsToReleased() async {
    let launcher = BlockingSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    controller.updateAutomaticDemand(brewing: true, sleepAlreadyDisabled: false)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(launcher.activeEntered.wait(timeout: .now() + 1) == .success)

    // The cached confirmed mode is still released when demand ends. The old
    // active request nevertheless lands, so the controller must issue an
    // explicit compensating release instead of trusting its cached value.
    controller.updateAutomaticDemand(brewing: false, sleepAlreadyDisabled: false)
    launcher.allowActiveToFinish.signal()
    await controller.autoTick(brewing: false, sleepAlreadyDisabled: false)

    #expect(controller.confirmedMode == .released)
    #expect(Array(launcher.recordedModes.suffix(2)) == [.active, .released])
    #expect(!controller.hasScopedTransaction)
}

@MainActor
@Test func launchCleanupCannotOverwriteConcurrentNewDemand() async {
    let launcher = BlockingReleaseSleepWatchdogLauncher()
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)

    let cleanup = Task { @MainActor in
        await controller.cleanupAtLaunch()
    }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(launcher.releaseEntered.wait(timeout: .now() + 1) == .success)
    controller.updateAutomaticDemand(brewing: true, sleepAlreadyDisabled: false)
    launcher.allowReleaseToFinish.signal()
    await cleanup.value
    await controller.autoTick(brewing: true, sleepAlreadyDisabled: false)

    #expect(controller.confirmedMode == .active)
    #expect(Array(launcher.recordedModes.suffix(2)) == [.released, .active])
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
    #expect(launcher.modes.isEmpty)
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
    // A timed-out backend may still have recorded the desired state. Do not
    // issue an unsafe reverse compensation; retry the same desired mode.
    #expect(launcher.removeCalls == 0)
}

@MainActor
@Test func aFailedModeApplicationRetriesTheSameIntentMidSession() async {
    let launcher = FakeSleepWatchdogLauncher()
    launcher.createFlagSucceeds = false
    let controller = ClosedDisplayAutoController(launcher: launcher, appPID: 1)
    controller.onlyWhileBrewing = true

    await controller.autoTick(brewing: true)
    await controller.autoTick(brewing: true)
    #expect(!controller.isHolding)

    launcher.createFlagSucceeds = true
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
