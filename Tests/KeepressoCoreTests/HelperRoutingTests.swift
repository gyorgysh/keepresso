import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Fakes

final class HelperRoutingTestClient: PrivilegedHelperCalling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    var pingSucceeds = true
    var holdSucceeds = true
    var fanDropped = false
    var lowPowerBarrier: BlockingLowPowerTestCall?

    func ping() -> Bool {
        record("ping")
        return pingSucceeds
    }

    func pingVersion() -> Int? {
        record("pingVersion")
        return pingSucceeds ? HelperService.protocolVersion : nil
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        record("setSleepDisabled(\(disabled))")
        return holdSucceeds
    }

    func setSleepHold(_ holding: Bool) -> Bool {
        record("setSleepHold(\(holding))")
        return holdSucceeds
    }

    func setAWDLHold(_ holding: Bool) -> Bool {
        record("setAWDLHold(\(holding))")
        return holdSucceeds
    }

    func setPriorityHold(_ holding: Bool, pid: Int) -> Bool {
        record("setPriorityHold(\(holding), \(pid))")
        return holdSucceeds
    }

    func setFanHold(_ holding: Bool, percent: Int) -> Bool {
        record("setFanHold(\(holding), \(percent))")
        return holdSucceeds
    }

    func fanHoldDropped() -> Bool? {
        record("fanHoldDropped")
        return fanDropped
    }

    func sleepNow() -> Bool {
        record("sleepNow")
        return holdSucceeds
    }

    func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool {
        record("applyWakeSchedule(\(oneShot ?? "-"), \(repeatDays ?? "-"), \(repeatTime ?? "-"))")
        return holdSucceeds
    }

    func flushDNS() -> Bool {
        record("flushDNS")
        return holdSucceeds
    }

    func setLowPowerHold(_ holding: Bool) -> Bool {
        record("setLowPowerHold(\(holding))")
        if holding { lowPowerBarrier?.waitForRelease() }
        return holdSucceeds
    }
    func setAdapterLowPowerHold(_ holding: Bool) -> Bool {
        record("setAdapterLowPowerHold(\(holding))")
        return holdSucceeds
    }

    func setKeyboardLock(_ holding: Bool) -> Bool {
        record("setKeyboardLock(\(holding))")
        return holdSucceeds
    }

    private func record(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }
}

final class BlockingLowPowerTestCall: @unchecked Sendable {
    private let lock = NSLock()
    private var onStarted: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
    private let permit = DispatchSemaphore(value: 0)
    init(onStarted: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.onStarted = onStarted
    }
    func waitForRelease() {
        lock.lock()
        let callback = onStarted
        onStarted = nil
        lock.unlock()
        callback?({ self.release() })
        // Ordering is controlled by the test, not runner speed. The test's
        // defer always releases this barrier even if it throws or is cancelled.
        permit.wait()
    }
    func release() { permit.signal() }
}

private final class FakeFallbackSleepWatchdog: SleepWatchdogLaunching, @unchecked Sendable {
    var flagPresent = false
    private(set) var startCalls = 0
    private(set) var removeCalls = 0

    func isFlagPresent() -> Bool { flagPresent }
    func createFlag() -> Bool {
        flagPresent = true
        return true
    }
    func removeFlag() {
        flagPresent = false
        removeCalls += 1
    }
    func startHelper(appPID: Int32) -> SleepSettingResult {
        startCalls += 1
        return .applied
    }
}

private final class FakeFallbackSleepControl: SleepSettingControlling, @unchecked Sendable {
    var reading: Bool? = false
    private(set) var writes: [Bool] = []

    func isSleepDisabled() -> Bool? { reading }
    func setSleepDisabled(_ disabled: Bool) -> SleepSettingResult {
        writes.append(disabled)
        return .applied
    }
}

// MARK: - Watchdog routing

@Test func routedSleepWatchdogUsesDaemonWithoutAnyPromptWhenInstalled() {
    let client = HelperRoutingTestClient()
    let fallback = FakeFallbackSleepWatchdog()
    let routed = RoutedSleepWatchdog(
        daemon: HelperDaemonSleepWatchdog(helper: client),
        fallback: fallback,
        helperInstalled: { true }
    )

    #expect(routed.createFlag())
    // "Starting the helper" is a version-checked ping: nothing spawns, no prompt.
    #expect(routed.startHelper(appPID: 1) == .applied)
    #expect(routed.isFlagPresent())
    routed.removeFlag()
    #expect(!routed.isFlagPresent())

    #expect(client.calls == ["setSleepHold(true)", "ping", "setSleepHold(false)"])
    #expect(fallback.startCalls == 0)
    #expect(!fallback.flagPresent)
}

@Test func routedSleepWatchdogFallsBackWhenHelperMissing() {
    let client = HelperRoutingTestClient()
    let fallback = FakeFallbackSleepWatchdog()
    let routed = RoutedSleepWatchdog(
        daemon: HelperDaemonSleepWatchdog(helper: client),
        fallback: fallback,
        helperInstalled: { false }
    )

    #expect(routed.createFlag())
    #expect(routed.startHelper(appPID: 1) == .applied)
    #expect(routed.isFlagPresent())
    routed.removeFlag()

    #expect(fallback.startCalls == 1)
    // Not installed and never held via the daemon: no XPC traffic at all.
    #expect(client.calls.isEmpty)
}

@Test func routedWatchdogFailureMessageNamesTheActiveBackend() {
    // A failed engage through the daemon is an XPC failure, not a file-write
    // one; the message must match whichever backend is actually in use.
    let client = HelperRoutingTestClient()
    let installed = LockedFlag(true)
    let routed = RoutedSleepWatchdog(
        daemon: HelperDaemonSleepWatchdog(helper: client),
        fallback: FakeFallbackSleepWatchdog(),
        helperInstalled: { installed.value }
    )

    #expect(routed.engageFailureMessage == "The Keepresso helper isn't responding.")
    installed.value = false
    #expect(routed.engageFailureMessage == "Couldn't create the sleep watchdog flag file.")
}

@Test func routedWatchdogReleasesADaemonHoldEvenAfterUninstall() {
    let client = HelperRoutingTestClient()
    let installed = LockedFlag(true)
    let routed = RoutedSleepWatchdog(
        daemon: HelperDaemonSleepWatchdog(helper: client),
        fallback: FakeFallbackSleepWatchdog(),
        helperInstalled: { installed.value }
    )

    #expect(routed.createFlag())
    // The helper is removed mid-hold: the release must still reach the daemon
    // side (its local hold bookkeeping), not silently route away.
    installed.value = false
    routed.removeFlag()
    #expect(client.calls.contains("setSleepHold(false)"))
    #expect(!routed.isFlagPresent())
}

@Test func routedSleepWatchdogKeepsHoldingWhenReleaseFails() {
    let client = HelperRoutingTestClient()
    let routed = RoutedSleepWatchdog(
        daemon: HelperDaemonSleepWatchdog(helper: client),
        fallback: FakeFallbackSleepWatchdog(),
        helperInstalled: { true }
    )
    #expect(routed.createFlag())
    client.holdSucceeds = false
    routed.removeFlag()
    #expect(routed.isFlagPresent())
    #expect(client.calls.contains("setSleepHold(false)"))
}

@Test func routedAWDLWatchdogMirrorsTheSleepRouting() {
    let client = HelperRoutingTestClient()
    let routed = RoutedAWDLWatchdog(
        daemon: HelperDaemonAWDLWatchdog(helper: client),
        fallback: OsascriptAWDLWatchdog(
            flagURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("keepresso-test-\(UUID().uuidString).flag")
        ),
        helperInstalled: { true }
    )

    #expect(routed.createFlag())
    #expect(routed.startHelper(appPID: 1) == .started)
    routed.removeFlag()
    #expect(client.calls == ["setAWDLHold(true)", "ping", "setAWDLHold(false)"])

    // A dead daemon surfaces as a failure, not a hang or a false start.
    client.pingSucceeds = false
    #expect(routed.startHelper(appPID: 1) == .failed("The Keepresso helper isn't responding."))
}

// MARK: - Sleep-setting routing

@Test func routedSleepControlReadsLocallyAndWritesThroughTheHelper() {
    let client = HelperRoutingTestClient()
    let fallback = FakeFallbackSleepControl()
    let routed = RoutedSleepControl(
        helper: client,
        fallback: fallback,
        helperInstalled: { true }
    )

    // Reads never need privileges; they stay on the plain pmset backend.
    fallback.reading = true
    #expect(routed.isSleepDisabled() == true)

    #expect(routed.setSleepDisabled(true) == .applied)
    #expect(client.calls == ["setSleepDisabled(true)"])
    #expect(fallback.writes.isEmpty)

    client.holdSucceeds = false
    #expect(routed.setSleepDisabled(false) == .failed("The Keepresso helper couldn't change the setting."))
}

@Test func routedSleepControlPromptsViaFallbackWhenHelperMissing() {
    let client = HelperRoutingTestClient()
    let fallback = FakeFallbackSleepControl()
    let routed = RoutedSleepControl(
        helper: client,
        fallback: fallback,
        helperInstalled: { false }
    )

    #expect(routed.setSleepDisabled(true) == .applied)
    #expect(fallback.writes == [true])
    #expect(client.calls.isEmpty)
}

/// A tiny lock-guarded flag for simulating install-state flips mid-test.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ initial: Bool) {
        stored = initial
    }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

@Test @MainActor func closedLidLowPowerRestoresWhenItsConditionsEnd() async throws {
    let helper = HelperRoutingTestClient()
    let controller = ClosedLidLowPowerController(helper: helper)
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true, onBattery: true, helperAvailable: true)
    #expect(helper.calls.isEmpty)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: true, helperAvailable: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.holding)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: false, helperAvailable: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(!controller.holding)
    #expect(helper.calls == ["setLowPowerHold(true)", "setLowPowerHold(false)"])
}

@Test @MainActor func closedLidFanFloorIsInactiveOnFanlessDevicesAndReleasesOnOpening() async throws {
    let helper = HelperRoutingTestClient()
    let controller = ClosedLidFanFloorController(helper: helper)
    controller.tick(percent: 50, armed: true, supported: false)
    #expect(helper.calls.isEmpty)
    controller.tick(percent: 50, armed: false, supported: true)
    #expect(helper.calls.isEmpty)
    controller.tick(percent: 50, armed: true, supported: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.holdingPercent == 50)
    controller.tick(percent: 50, armed: false, supported: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.holdingPercent == nil)
    #expect(helper.calls == ["setFanHold(true, 50)", "setFanHold(false, 0)"])
}
@Test func closedLidFanFloorNeverChangesExistingThermalConfiguration() throws {
    let old = try JSONDecoder().decode(KeepressoSettings.self, from: Data(#"{"thermalSafety":{"sustainSeconds":60,"fanBoostPercent":80,"stopBrewing":true}}"#.utf8))
    #expect(old.closedLidMinimumFanPercent == nil)
    var enabled = old; enabled.closedLidMinimumFanPercent = 50
    #expect(enabled.thermalSafety == old.thermalSafety)
    #expect(try JSONDecoder().decode(KeepressoSettings.self, from: JSONEncoder().encode(enabled)) == enabled)
    #expect(ClosedLidFanFloor.requestedPercent(500, armed: true, supported: true) == 100)
    #expect(ClosedLidFanFloor.requestedPercent(50, armed: true, supported: false) == nil)
}

@Test @MainActor func fanFloorDoesNotFightFirmwareThatDroppedTheHold() async throws {
    let helper = HelperRoutingTestClient()
    let controller = ClosedLidFanFloorController(helper: helper)
    let now = Date()
    controller.tick(percent: 50, armed: true, supported: true, now: now)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    helper.fanDropped = true
    controller.tick(percent: 50, armed: true, supported: true, now: now.addingTimeInterval(3))
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.suspended)
    controller.tick(percent: 50, armed: true, supported: true, now: now.addingTimeInterval(4))
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.requestedPercent == nil)
    controller.tick(percent: 50, armed: true, supported: true, now: now.addingTimeInterval(30))
    #expect(helper.calls == ["setFanHold(true, 50)", "fanHoldDropped", "setFanHold(false, 0)"])
}
@Test @MainActor func fanFloorStopReleasesBeforeHelperRemovalAndStaysStopped() async throws {
    let helper = HelperRoutingTestClient()
    let controller = ClosedLidFanFloorController(helper: helper)
    controller.tick(percent: 50, armed: true, supported: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    await controller.stopAndWait()
    controller.tick(percent: 50, armed: true, supported: true)
    #expect(controller.requestedPercent == nil)
    #expect(helper.calls == ["setFanHold(true, 50)", "setFanHold(false, 0)"])
}

@Test @MainActor func lowPowerUnknownReadingsDoNotUndoAConfirmedClosedLidHold() async throws {
    let helper = HelperRoutingTestClient()
    let controller = ClosedLidLowPowerController(helper: helper)
    controller.tick(enabled: true, lidClosed: nil, closedDisplayActive: nil, onBattery: nil, helperAvailable: true)
    #expect(helper.calls.isEmpty)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: true, helperAvailable: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.holding)
    controller.tick(enabled: true, lidClosed: nil, closedDisplayActive: nil, onBattery: nil, helperAvailable: true)
    #expect(helper.calls == ["setLowPowerHold(true)"])
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: nil, onBattery: nil, helperAvailable: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(!controller.holding)
    #expect(helper.calls == ["setLowPowerHold(true)", "setLowPowerHold(false)"])
}

@Test @MainActor func lowPowerPluggedInOptInHoldsAndRestoresBothProfiles() async throws {
    let helper = HelperRoutingTestClient()
    let controller = ClosedLidLowPowerController(helper: helper)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: false, helperAvailable: true)
    #expect(controller.status == .waitingForBattery)
    #expect(helper.calls.isEmpty)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: false, helperAvailable: true, allowOnAC: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.batteryHolding && controller.adapterHolding)
    #expect(controller.status == .active)
    // Unplugging needs no profile rewrite when both profiles were opted in.
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: true, helperAvailable: true, allowOnAC: true)
    #expect(helper.calls == ["setLowPowerHold(true)", "setAdapterLowPowerHold(true)"])
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true, onBattery: true, helperAvailable: true, allowOnAC: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(!controller.holding && !controller.hasPendingRequests)
    #expect(helper.calls.suffix(2) == ["setAdapterLowPowerHold(false)", "setLowPowerHold(false)"])
}

@Test @MainActor func lowPowerTurningOffAfterFailedEngageStillReleasesRestoreDebt() async throws {
    let helper = HelperRoutingTestClient(); helper.holdSucceeds = false
    let controller = ClosedLidLowPowerController(helper: helper)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: true, helperAvailable: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.failed && controller.hasPendingRequests)
    helper.holdSucceeds = true
    controller.tick(enabled: false, lidClosed: true, closedDisplayActive: true, onBattery: true, helperAvailable: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(!controller.hasPendingRequests && !controller.failed)
    #expect(helper.calls == ["setLowPowerHold(true)", "setLowPowerHold(false)"])
}

@Test func fanFloorTenPercentSurvivesSettingsRoundTripWithoutChangingBoostRange() throws {
    let settings = KeepressoSettings(closedLidMinimumFanPercent: 10)
    #expect(try JSONDecoder().decode(KeepressoSettings.self, from: JSONEncoder().encode(settings)).closedLidMinimumFanPercent == 10)
    #expect(ClosedLidFanFloor.clampedPercent(1) == 10)
    #expect(ThermalSafetyConfig.clampedBoostPercent(10) == 30)
    #expect(!settings.closedLidLowPowerOnAC)
    let old = try JSONDecoder().decode(KeepressoSettings.self, from: Data(#"{"closedLidLowPower":true}"#.utf8))
    #expect(old.closedLidLowPower && !old.closedLidLowPowerOnAC)
}

@Test @MainActor func lowPowerDisarmBeforeWorkerStartsDoesNotWriteEitherProfile() async throws {
    let helper = HelperRoutingTestClient()
    let controller = ClosedLidLowPowerController(helper: helper)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: true, helperAvailable: true, allowOnAC: true)
    controller.tick(enabled: false, lidClosed: false, closedDisplayActive: false, onBattery: true, helperAvailable: true, allowOnAC: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(helper.calls.isEmpty)
    #expect(controller.status == .off)
}

@Test @MainActor func helperReplacementRearmsStoppedClosedLidControllersWithoutChangingTheirOptions() async throws {
    let helper = HelperRoutingTestClient()
    let lowPower = ClosedLidLowPowerController(helper: helper)
    let floor = ClosedLidFanFloorController(helper: helper)
    lowPower.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: true, helperAvailable: true, allowOnAC: true)
    floor.tick(percent: 10, armed: true, supported: true)
    for _ in 0..<100 { if !lowPower.busy && !floor.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    await lowPower.stopAndWait(); await floor.stopAndWait()
    #expect(!lowPower.hasPendingRequests && floor.requestedPercent == nil)
    lowPower.resumeAfterHelperReplacement(); floor.resumeAfterHelperReplacement()
    lowPower.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: true, helperAvailable: true, allowOnAC: true)
    floor.tick(percent: 10, armed: true, supported: true)
    for _ in 0..<100 { if !lowPower.busy && !floor.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(lowPower.batteryHolding && lowPower.adapterHolding)
    #expect(floor.holdingPercent == 10)
    #expect(helper.calls.filter { $0 == "setAdapterLowPowerHold(true)" }.count == 2)
    #expect(helper.calls.filter { $0 == "setFanHold(true, 10)" }.count == 2)
}
