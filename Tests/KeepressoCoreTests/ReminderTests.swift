import Testing
import Foundation
@testable import KeepressoCore

private final class FakeReminder: ReminderNotifying {
    private(set) var notices: [(title: String, body: String, sound: Bool)] = []
    private(set) var cancelCount = 0
    func notify(title: String, body: String, sound: Bool) { notices.append((title, body, sound)) }
    func cancelPending() { cancelCount += 1 }
}

private final class FakeAssertions: PowerAsserting {
    private(set) var held: Set<PowerAssertionKind> = []
    func apply(_ kinds: Set<PowerAssertionKind>, reason: String) { held = kinds }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

@MainActor
private func makeController() -> (SessionController, FakeReminder, Clock) {
    let reminder = FakeReminder()
    let clock = Clock()
    let controller = SessionController(
        assertions: FakeAssertions(),
        reminder: reminder,
        now: { clock.now }
    )
    return (controller, reminder, clock)
}

@MainActor
@Test func noReminderWhenIntervalUnset() {
    let (controller, reminder, clock) = makeController()
    controller.start()
    clock.advance(10 * 60)
    controller.reconcile()
    #expect(reminder.notices.isEmpty)
}

@MainActor
@Test func reminderFiresOnceAfterInterval() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 30 * 60
    controller.start()

    clock.advance(29 * 60)
    controller.reconcile()
    #expect(reminder.notices.isEmpty)

    clock.advance(2 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)
    #expect(reminder.notices.first?.body.contains(SessionController.humanDuration(30 * 60)) == true)

    clock.advance(60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)
}

@MainActor
@Test func recurringReminderFiresEachInterval() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 60 * 60
    controller.reminderRepeats = true
    controller.start()

    clock.advance(60 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)

    clock.advance(60 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 2)
    #expect(reminder.notices.last?.body.contains(SessionController.humanDuration(2 * 60 * 60)) == true)
}

@MainActor
@Test func recurringDoesNotFloodAfterLongGap() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 60 * 60
    controller.reminderRepeats = true
    controller.start()

    clock.advance(5 * 60 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)
}

@MainActor
@Test func reminderSoundFlagIsForwarded() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 60
    controller.reminderSound = false
    controller.start()
    clock.advance(120)
    controller.reconcile()
    #expect(reminder.notices.first?.sound == false)
}

@MainActor
@Test func restartingResetsTheReminder() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 60
    controller.start()
    clock.advance(120)
    controller.reconcile()
    #expect(reminder.notices.count == 1)

    controller.start()
    clock.advance(120)
    controller.reconcile()
    #expect(reminder.notices.count == 2)
}

@MainActor
@Test func stoppingCancelsPendingReminder() {
    let (controller, reminder, _) = makeController()
    controller.reminderAfter = 60
    controller.start()
    controller.stop()
    #expect(reminder.cancelCount == 1)
}

@MainActor
@Test func gatedSessionFiresAndResetsReminder() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 60
    let gate = StubReminderGate(true)
    controller.triggerGate = gate

    controller.reconcile()
    clock.advance(120)
    controller.reconcile()
    #expect(reminder.notices.count == 1)

    gate.satisfied = false
    controller.reconcile()
    #expect(reminder.cancelCount == 1)

    gate.satisfied = true
    controller.reconcile()
    clock.advance(120)
    controller.reconcile()
    #expect(reminder.notices.count == 2)
}

private final class StubReminderGate: TriggerEvaluating {
    var satisfied: Bool
    init(_ satisfied: Bool) { self.satisfied = satisfied }
    func isSatisfied() -> Bool { satisfied }
}


private final class FakeEndActor: SessionEndActing {
    private(set) var performed: [SessionEndAction] = []
    func perform(_ action: SessionEndAction) { performed.append(action) }
}

@MainActor
private func makeEndController() -> (SessionController, FakeReminder, FakeEndActor, Clock) {
    let reminder = FakeReminder()
    let endActor = FakeEndActor()
    let clock = Clock()
    let controller = SessionController(
        assertions: FakeAssertions(),
        reminder: reminder,
        endActor: endActor,
        now: { clock.now }
    )
    return (controller, reminder, endActor, clock)
}

@MainActor
@Test func endEffectsFireWhenATimedSessionExpires() {
    let (controller, reminder, endActor, clock) = makeEndController()
    controller.notifyOnEnd = true
    controller.endAction = .sleepDisplay
    controller.start(mode: .timed(duration: 60))

    clock.advance(61)
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(reminder.notices.contains { $0.title == "Keepresso stopped" })
    #expect(endActor.performed.isEmpty)

    clock.advance(SessionController.endActionDebounce)
    controller.reconcile()
    #expect(endActor.performed == [.sleepDisplay])
}

@MainActor
@Test func aManualStopDoesNotFireEndEffects() {
    let (controller, reminder, endActor, _) = makeEndController()
    controller.notifyOnEnd = true
    controller.endAction = .sleepDisplay
    controller.start()
    controller.stop()
    #expect(reminder.notices.isEmpty)
    #expect(endActor.performed.isEmpty)
}

@MainActor
@Test func endEffectsFireWhenTriggerConditionsDrop() {
    let (controller, reminder, endActor, clock) = makeEndController()
    controller.notifyOnEnd = true
    controller.endAction = .startScreensaver
    let gate = StubReminderGate(true)
    controller.triggerGate = gate

    controller.reconcile()
    #expect(controller.isActive)
    gate.satisfied = false
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(reminder.notices.contains { $0.title == "Keepresso stopped" })
    #expect(endActor.performed.isEmpty)

    clock.advance(SessionController.endActionDebounce)
    controller.reconcile()
    #expect(endActor.performed == [.startScreensaver])
}

@MainActor
@Test func aTriggerFlapCancelsThePendingEndAction() {
    let (controller, _, endActor, clock) = makeEndController()
    controller.endAction = .sleepDisplay
    let gate = StubReminderGate(true)
    controller.triggerGate = gate

    controller.reconcile()
    gate.satisfied = false
    controller.reconcile()
    #expect(controller.isActive == false)

    gate.satisfied = true
    clock.advance(1)
    controller.reconcile()
    #expect(controller.isActive)
    clock.advance(SessionController.endActionDebounce)
    controller.reconcile()
    #expect(endActor.performed.isEmpty)
}

@MainActor
@Test func pauseDoesNotRefireOneShotReminderOnResume() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 30 * 60
    controller.pauseBelowBatteryPercent = 20
    controller.start()

    clock.advance(31 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)

    controller.reconcile(battery: .discharging(15))
    #expect(controller.isActive == false)
    controller.reconcile(battery: .onAC)
    #expect(controller.isActive)
    controller.reconcile()
    #expect(reminder.notices.filter { $0.title == "Keepresso is still brewing" }.count == 1)
}

@MainActor
@Test func batteryPauseDoesNotRunTheEndAction() {
    let (controller, reminder, endActor, _) = makeEndController()
    controller.endAction = .sleepDisplay
    controller.pauseBelowBatteryPercent = 20
    controller.start()
    controller.reconcile(battery: .discharging(10))
    #expect(controller.isActive == false)
    #expect(reminder.notices.contains { $0.title == "Paused on low battery" })
    #expect(endActor.performed.isEmpty)
}

@MainActor
@Test func aStaleTimedExpirySuppressesTheEndAction() {
    let (controller, reminder, endActor, clock) = makeEndController()
    controller.notifyOnEnd = true
    controller.endAction = .lockScreen
    controller.start(mode: .timed(duration: 60))

    clock.advance(60 + SessionController.endActionStaleGrace + 1)
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(reminder.notices.contains { $0.title == "Keepresso stopped" })
    clock.advance(SessionController.endActionDebounce)
    controller.reconcile()
    #expect(endActor.performed.isEmpty)
}

@MainActor
@Test func aPendingEndActionGoneStaleIsDroppedAtFlush() {
    let (controller, _, endActor, clock) = makeEndController()
    controller.endAction = .sleepMac
    let gate = StubReminderGate(true)
    controller.triggerGate = gate

    controller.reconcile()
    gate.satisfied = false
    controller.reconcile()
    #expect(endActor.performed.isEmpty)

    clock.advance(3 * 3600)
    controller.reconcile()
    #expect(endActor.performed.isEmpty)
}

@MainActor
@Test func aSafetyPauseCancelsThePendingEndAction() {
    let (controller, _, endActor, clock) = makeEndController()
    controller.endAction = .sleepMac
    controller.pauseBelowBatteryPercent = 20
    let gate = StubReminderGate(true)
    controller.triggerGate = gate

    controller.reconcile(battery: .discharging(50))
    gate.satisfied = false
    controller.reconcile(battery: .discharging(50))
    clock.advance(1)
    controller.reconcile(battery: .discharging(10))
    clock.advance(2 * 3600)
    controller.reconcile(battery: .onAC)
    controller.reconcile(battery: .onAC)
    #expect(endActor.performed.isEmpty)
}

@MainActor
@Test func endEffectsStayQuietWhenTheOptionsAreOff() {
    let (controller, reminder, endActor, clock) = makeEndController()
    controller.start(mode: .timed(duration: 30))
    clock.advance(31)
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(reminder.notices.isEmpty)
    #expect(endActor.performed.isEmpty)
}


@MainActor
@Test func endingSoonFiresOnceInsideTheNoticeWindow() {
    let (controller, reminder, clock) = makeController()
    controller.endingSoonNotice = 5 * 60
    controller.start()
    controller.stopIn(15 * 60)

    clock.advance(9 * 60)
    controller.reconcile()
    #expect(reminder.notices.isEmpty)

    clock.advance(90)
    controller.reconcile()
    #expect(reminder.notices.count == 1)
    #expect(reminder.notices.first?.title == "Keepresso stops soon")

    clock.advance(60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)
}

@MainActor
@Test func endingSoonSuppressedWhenTheCountdownStartsInsideTheWindow() {
    let (controller, reminder, clock) = makeController()
    controller.endingSoonNotice = 5 * 60
    controller.start(mode: .timed(duration: 3 * 60))
    clock.advance(60)
    controller.reconcile()
    #expect(reminder.notices.isEmpty)

    controller.stop()
    controller.start()
    controller.stopIn(2 * 60)
    clock.advance(60)
    controller.reconcile()
    #expect(reminder.notices.isEmpty)
}

@MainActor
@Test func endingSoonReArmsWhenTheCountdownIsExtended() {
    let (controller, reminder, clock) = makeController()
    controller.endingSoonNotice = 5 * 60
    controller.start()
    controller.stopIn(6 * 60)
    clock.advance(2 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)

    controller.stopIn(20 * 60)
    clock.advance(16 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 2)
}

@MainActor
@Test func endingSoonBodyRoundsUpToTheNoticeMinute() {
    let (controller, reminder, clock) = makeController()
    controller.endingSoonNotice = 5 * 60
    controller.start()
    controller.stopIn(15 * 60)

    clock.advance(10 * 60 + 1)
    controller.reconcile()
    #expect(reminder.notices.count == 1)
    #expect(reminder.notices.first?.body.contains(SessionController.humanDuration(5 * 60)) == true)
}

@MainActor
@Test func endingSoonNeverFiresForAnIndefiniteSession() {
    let (controller, reminder, clock) = makeController()
    controller.endingSoonNotice = 5 * 60
    controller.start()
    clock.advance(60 * 60)
    controller.reconcile()
    #expect(reminder.notices.isEmpty)
}

@MainActor
@Test func denormalReminderAfterDoesNotTrap() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 1e-300
    controller.start()
    clock.advance(60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)
    clock.advance(60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)
}

@MainActor
@Test func stopInDoesNotResetTheReminderCounter() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 30 * 60
    controller.start()
    clock.advance(31 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)

    controller.stopIn(60 * 60)
    clock.advance(10 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1)
}
