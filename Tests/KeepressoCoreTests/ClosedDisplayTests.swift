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
@Test func refreshSkipsPmsetWhenCacheIsFresh() async {
    let fake = FakeSleepControl(initial: false)
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let controller = ClosedDisplayController(control: fake, now: { clock })
    await controller.refresh(force: true)
    #expect(controller.isEnabled == false)

    // Flip the underlying setting; a non-forced refresh within the freshness
    // window must keep serving the cached value.
    _ = fake.setSleepDisabled(true)
    await controller.refresh()
    #expect(controller.isEnabled == false)

    clock = clock.addingTimeInterval(ClosedDisplayController.refreshFreshness + 1)
    await controller.refresh()
    #expect(controller.isEnabled == true)

    // Force always re-reads.
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

/// `sleepNow()` is only ever called synchronously on the main actor from
/// ``ClosedDisplayController/tick()``, so no locking is needed here.
private final class FakeDisplaySleeper: DisplaySleepCommanding, @unchecked Sendable {
    private(set) var sleepNowCallCount = 0
    func sleepNow() { sleepNowCallCount += 1 }
}

/// Read on the main actor from ``ClosedDisplayController/tick()`` only, like
/// ``FakeDisplaySleeper``.
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
    await controller.refresh() // isEnabled becomes false
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
    await controller.refresh() // isEnabled becomes true

    controller.tick() // still open: no-op
    lid.closed = true
    controller.tick() // closes: should sleep
    controller.tick() // still closed: should not sleep again
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

    controller.tick() // clamshell with monitor: no-op
    #expect(sleeper.sleepNowCallCount == 0)
    // Unplugging the monitor leaves the internal panel as the active display
    // inside the closed lid; that edge must sleep it too.
    externalDisplay.snapshot = DisplaySnapshot(externalDisplayCount: 0, totalDisplayCount: 1)
    controller.tick()
    controller.tick() // still closed and unplugged: not again
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
    controller.tick() // closes: sleeps once
    #expect(sleeper.sleepNowCallCount == 1)
    lid.closed = nil   // transient unreadable state mid-flutter
    controller.tick()
    lid.closed = true
    controller.tick() // still closed after the nil blip: must not re-sleep
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
    controller.tick() // close #1
    lid.closed = false
    controller.tick() // reopen
    lid.closed = true
    controller.tick() // close #2
    #expect(sleeper.sleepNowCallCount == 2)
}

// MARK: - Holding the panel dark through an outside wake

/// The panel gets lit from outside (a notification, a keypress on a paired
/// keyboard) while the lid stays shut: put it back to sleep instead of leaving
/// it on the lock screen inside the closed lid.
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
    controller.tick() // the closing edge
    #expect(sleeper.sleepNowCallCount == 1)

    // Panel asleep and lid still shut: nothing more to do, however long it runs.
    clock += 600
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 1)

    // Something lights it back up.
    power.asleep = false
    controller.tick()
    #expect(sleeper.sleepNowCallCount == 2)
}

/// A panel that reads lit right after a `displaysleepnow` is still on its way
/// down, not woken: don't fire again until the grace period is over.
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

/// An unreadable panel state must not turn the re-sleep into a `pmset` every
/// few seconds for as long as the lid is shut.
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

/// The re-sleep is scoped the same way the first one is: with an external
/// display attached, `displaysleepnow` would blank the monitor the user is
/// actually looking at.
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

/// A nil lid read mid-stretch must not restart the fire-once edge, and must not
/// stop the re-sleep once a good read comes back.
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
