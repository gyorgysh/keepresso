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
