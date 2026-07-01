import Testing
import Foundation
@testable import KeepressoCore

/// Programmable fake for the sleep-setting seam. `@unchecked Sendable` with a
/// lock because the controller invokes ``setSleepDisabled(_:)`` off the main
/// actor; the tests run serially so the lock is just to satisfy concurrency.
private final class FakeSleepControl: SleepSettingControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _disabled: Bool?
    private var _result: SleepSettingResult
    private(set) var setCalls: [Bool] = []

    init(initial: Bool? = false, result: SleepSettingResult = .applied) {
        _disabled = initial
        _result = result
    }

    func isSleepDisabled() -> Bool? { lock.withLock { _disabled } }

    func setSleepDisabled(_ disabled: Bool) -> SleepSettingResult {
        lock.withLock {
            setCalls.append(disabled)
            if case .applied = _result { _disabled = disabled } // cancel/fail leave it unchanged
            return _result
        }
    }
}

@MainActor
@Test func refreshReflectsSystemState() async {
    let fake = FakeSleepControl(initial: true)
    let controller = ClosedDisplayController(control: fake)
    #expect(controller.isEnabled == nil) // not read yet
    await controller.refresh()
    #expect(controller.isEnabled == true)
}

@MainActor
@Test func enablingAppliesAndClearsError() async {
    let fake = FakeSleepControl(initial: false, result: .applied)
    let controller = ClosedDisplayController(control: fake)
    let result = await controller.set(true)
    #expect(result == .applied)
    #expect(controller.isEnabled == true)
    #expect(controller.lastError == nil)
    #expect(fake.setCalls == [true])
}

@MainActor
@Test func cancellingLeavesStateAndDoesNotError() async {
    let fake = FakeSleepControl(initial: false, result: .cancelled)
    let controller = ClosedDisplayController(control: fake)
    let result = await controller.set(true)
    #expect(result == .cancelled)
    #expect(controller.isEnabled == false) // unchanged: prompt was dismissed
    #expect(controller.lastError == nil)   // cancelling is not a nagging error
}

@MainActor
@Test func failureSurfacesMessage() async {
    let fake = FakeSleepControl(initial: false, result: .failed("nope"))
    let controller = ClosedDisplayController(control: fake)
    let result = await controller.set(true)
    #expect(result == .failed("nope"))
    #expect(controller.isEnabled == false)
    #expect(controller.lastError == "nope")
}

@Test func parsesSleepDisabledOn() {
    let output = """
     System-wide power settings:
     Currently in use:
     standby              1
     SleepDisabled        1
     hibernatefile        /var/vm/sleepimage
     displaysleep         180
    """
    #expect(PMSetSleepControl.parseSleepDisabled(from: output) == true)
}

@Test func parsesSleepDisabledOffWhenLineAbsent() {
    let output = """
     System-wide power settings:
     sleep                1
     displaysleep         180
    """
    // No SleepDisabled line means the flag is off (the default).
    #expect(PMSetSleepControl.parseSleepDisabled(from: output) == false)
}

@Test func parsesSleepDisabledExplicitZero() {
    #expect(PMSetSleepControl.parseSleepDisabled(from: " SleepDisabled        0\n") == false)
}

@Test func parseReturnsNilWithoutOutput() {
    #expect(PMSetSleepControl.parseSleepDisabled(from: nil) == nil)
}

// MARK: - Lid-closed display sleep

private final class FakeLidState: LidStateReading, @unchecked Sendable {
    var closed: Bool?
    init(closed: Bool? = false) { self.closed = closed }
    func isClosed() -> Bool? { closed }
}

private final class FakeDisplayMonitor: DisplayMonitoring, @unchecked Sendable {
    var snapshot: DisplaySnapshot
    init(hasExternalDisplay: Bool = false) {
        snapshot = DisplaySnapshot(externalDisplayCount: hasExternalDisplay ? 1 : 0, totalDisplayCount: hasExternalDisplay ? 2 : 1)
    }
    var current: DisplaySnapshot { snapshot }
}

private final class FakeDisplaySleeper: DisplaySleepCommanding, @unchecked Sendable {
    private let lock = NSLock()
    private var _sleepNowCallCount = 0
    var sleepNowCallCount: Int { lock.withLock { _sleepNowCallCount } }
    func sleepNow() { lock.withLock { _sleepNowCallCount += 1 } }
}

@MainActor
@Test func lidTickDoesNothingWhenModeOff() async {
    let sleepControl = FakeSleepControl(initial: false)
    let lid = FakeLidState(closed: true)
    let sleeper = FakeDisplaySleeper()
    let controller = ClosedDisplayController(control: sleepControl, lid: lid, displaySleeper: sleeper)
    await controller.refresh() // isEnabled becomes false
    controller.tick()
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(sleeper.sleepNowCallCount == 0)
}

@MainActor
@Test func lidTickSleepsOnceOnCloseTransition() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: false)
    let sleeper = FakeDisplaySleeper()
    let controller = ClosedDisplayController(control: sleepControl, lid: lid, displaySleeper: sleeper)
    await controller.refresh() // isEnabled becomes true

    controller.tick() // still open: no-op
    lid.closed = true
    controller.tick() // closes: should sleep
    controller.tick() // still closed: should not sleep again
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(sleeper.sleepNowCallCount == 1)
}

@MainActor
@Test func lidTickIgnoresExternalDisplay() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: true)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: true)
    let sleeper = FakeDisplaySleeper()
    let controller = ClosedDisplayController(
        control: sleepControl, lid: lid, externalDisplay: externalDisplay, displaySleeper: sleeper
    )
    await controller.refresh()
    controller.tick()
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(sleeper.sleepNowCallCount == 0)
}

@MainActor
@Test func lidTickReArmsAfterReopening() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: false)
    let sleeper = FakeDisplaySleeper()
    let controller = ClosedDisplayController(control: sleepControl, lid: lid, displaySleeper: sleeper)
    await controller.refresh()

    lid.closed = true
    controller.tick() // close #1
    lid.closed = false
    controller.tick() // reopen
    lid.closed = true
    controller.tick() // close #2
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(sleeper.sleepNowCallCount == 2)
}
