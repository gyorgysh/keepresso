import Testing
import Foundation
@testable import KeepressoCore

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
            if case .applied = _result { _disabled = disabled }
            return _result
        }
    }
}

@MainActor
@Test func refreshReflectsSystemState() async {
    let fake = FakeSleepControl(initial: true)
    let controller = ClosedDisplayController(control: fake)
    #expect(controller.isEnabled == nil)
    await controller.refresh()
    #expect(controller.isEnabled == true)
}

@MainActor
@Test func refreshSkipsPmsetWhenCacheIsFresh() async {
    let fake = FakeSleepControl(initial: false)
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let controller = ClosedDisplayController(control: fake, now: { clock })
    await controller.refresh(force: true)
    #expect(controller.isEnabled == false)

    _ = fake.setSleepDisabled(true)
    await controller.refresh()
    #expect(controller.isEnabled == false)

    clock = clock.addingTimeInterval(ClosedDisplayController.refreshFreshness + 1)
    await controller.refresh()
    #expect(controller.isEnabled == true)

    _ = fake.setSleepDisabled(false)
    await controller.refresh(force: true)
    #expect(controller.isEnabled == false)
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
    #expect(controller.isEnabled == false)
    #expect(controller.lastError == nil)
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
    #expect(PMSetSleepControl.parseSleepDisabled(from: output) == false)
}

@Test func parsesSleepDisabledExplicitZero() {
    #expect(PMSetSleepControl.parseSleepDisabled(from: " SleepDisabled        0\n") == false)
}

@Test func parseReturnsNilWithoutOutput() {
    #expect(PMSetSleepControl.parseSleepDisabled(from: nil) == nil)
}


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
    private(set) var sleepNowCallCount = 0
    func sleepNow() { sleepNowCallCount += 1 }
}

private final class FakeDisplayPower: DisplayPowerReading, @unchecked Sendable {
    var asleep: Bool?
    init(asleep: Bool? = true) { self.asleep = asleep }
    func builtInIsAsleep() -> Bool? { asleep }
}

@MainActor
@Test func lidTickDoesNothingWhenModeOff() async {
    let sleepControl = FakeSleepControl(initial: false)
    let lid = FakeLidState(closed: true)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: false)
    let sleeper = FakeDisplaySleeper()
    let controller = ClosedDisplayController(
        control: sleepControl, lid: lid, externalDisplay: externalDisplay, displaySleeper: sleeper
    )
    await controller.refresh()
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 0)
}

@MainActor
@Test func lidTickSleepsOnceOnCloseTransition() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: false)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: false)
    let sleeper = FakeDisplaySleeper()
    let controller = ClosedDisplayController(
        control: sleepControl, lid: lid, externalDisplay: externalDisplay, displaySleeper: sleeper
    )
    await controller.refresh()

    controller.tick()
    lid.closed = true
    controller.tick()
    controller.tick()
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
    #expect(sleeper.sleepNowCallCount == 0)
}

@MainActor
@Test func lidTickSleepsWhenExternalDisplayDetachesWithLidClosed() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: true)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: true)
    let sleeper = FakeDisplaySleeper()
    let controller = ClosedDisplayController(
        control: sleepControl, lid: lid, externalDisplay: externalDisplay, displaySleeper: sleeper
    )
    await controller.refresh()

    controller.tick()
    #expect(sleeper.sleepNowCallCount == 0)
    externalDisplay.snapshot = DisplaySnapshot(externalDisplayCount: 0, totalDisplayCount: 1)
    controller.tick()
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)
}

@MainActor
@Test func lidTickIgnoresTransientNilRead() async {
    // AppleClamshellState can momentarily return nil. A nil read must not clear
    // the once-per-transition edge flag, or the next good read would re-issue
    // `displaysleepnow` on an already-sleeping panel.
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: false)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: false)
    let sleeper = FakeDisplaySleeper()
    let controller = ClosedDisplayController(
        control: sleepControl, lid: lid, externalDisplay: externalDisplay, displaySleeper: sleeper
    )
    await controller.refresh()

    lid.closed = true
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)
    lid.closed = nil
    controller.tick()
    lid.closed = true
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)
}

@MainActor
@Test func lidTickReArmsAfterReopening() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: false)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: false)
    let sleeper = FakeDisplaySleeper()
    let controller = ClosedDisplayController(
        control: sleepControl, lid: lid, externalDisplay: externalDisplay, displaySleeper: sleeper
    )
    await controller.refresh()

    lid.closed = true
    controller.tick()
    lid.closed = false
    controller.tick()
    lid.closed = true
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 2)
}


@MainActor
@Test func lidTickResleepsPanelWokenInsideClosedLid() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: false)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: false)
    let sleeper = FakeDisplaySleeper()
    let power = FakeDisplayPower(asleep: true)
    var clock = Date(timeIntervalSince1970: 0)
    let controller = ClosedDisplayController(
        control: sleepControl,
        lid: lid,
        externalDisplay: externalDisplay,
        displaySleeper: sleeper,
        displayPower: power,
        now: { clock }
    )
    await controller.refresh()

    lid.closed = true
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)

    clock += 600
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)

    power.asleep = false
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 2)
}

@MainActor
@Test func lidTickGivesThePanelTimeToGoDark() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: false)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: false)
    let sleeper = FakeDisplaySleeper()
    let power = FakeDisplayPower(asleep: false)
    var clock = Date(timeIntervalSince1970: 0)
    let controller = ClosedDisplayController(
        control: sleepControl,
        lid: lid,
        externalDisplay: externalDisplay,
        displaySleeper: sleeper,
        displayPower: power,
        now: { clock }
    )
    await controller.refresh()

    lid.closed = true
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)

    clock += 1
    controller.tick()
    clock += 1
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)

    clock += ClosedDisplayController.resleepGrace
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 2)
}

@MainActor
@Test func lidTickDoesNotResleepOnAnUnreadablePanel() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: false)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: false)
    let sleeper = FakeDisplaySleeper()
    let power = FakeDisplayPower(asleep: nil)
    var clock = Date(timeIntervalSince1970: 0)
    let controller = ClosedDisplayController(
        control: sleepControl,
        lid: lid,
        externalDisplay: externalDisplay,
        displaySleeper: sleeper,
        displayPower: power,
        now: { clock }
    )
    await controller.refresh()

    lid.closed = true
    controller.tick()
    for _ in 0..<10 {
        clock += 60
        controller.tick()
    }
    #expect(sleeper.sleepNowCallCount == 1)
}

@MainActor
@Test func lidTickDoesNotResleepWithAnExternalDisplay() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: true)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: true)
    let sleeper = FakeDisplaySleeper()
    let power = FakeDisplayPower(asleep: false)
    var clock = Date(timeIntervalSince1970: 0)
    let controller = ClosedDisplayController(
        control: sleepControl,
        lid: lid,
        externalDisplay: externalDisplay,
        displaySleeper: sleeper,
        displayPower: power,
        now: { clock }
    )
    await controller.refresh()

    for _ in 0..<10 {
        clock += 60
        controller.tick()
    }
    #expect(sleeper.sleepNowCallCount == 0)
}

@MainActor
@Test func lidTickResleepsAfterATransientNilLidRead() async {
    let sleepControl = FakeSleepControl(initial: true)
    let lid = FakeLidState(closed: false)
    let externalDisplay = FakeDisplayMonitor(hasExternalDisplay: false)
    let sleeper = FakeDisplaySleeper()
    let power = FakeDisplayPower(asleep: true)
    var clock = Date(timeIntervalSince1970: 0)
    let controller = ClosedDisplayController(
        control: sleepControl,
        lid: lid,
        externalDisplay: externalDisplay,
        displaySleeper: sleeper,
        displayPower: power,
        now: { clock }
    )
    await controller.refresh()

    lid.closed = true
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)

    lid.closed = nil
    clock += 30
    power.asleep = false
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)

    lid.closed = true
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 2)
}
