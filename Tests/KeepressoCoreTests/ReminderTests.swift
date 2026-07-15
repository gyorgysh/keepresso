import Testing
import Foundation
@testable import KeepressoCore

/// In-memory reminder backend that records what was delivered and cancelled.
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
    controller.start() // reminderAfter stays nil
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
    #expect(reminder.notices.isEmpty) // before the interval

    clock.advance(2 * 60) // 31 min elapsed
    controller.reconcile()
    #expect(reminder.notices.count == 1) // fired
    #expect(reminder.notices.first?.body.contains("30 minutes") == true)

    clock.advance(60)
    controller.reconcile()
    #expect(reminder.notices.count == 1) // not again this session (one-shot)
}

@MainActor
@Test func recurringReminderFiresEachInterval() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 60 * 60 // 1 hour
    controller.reminderRepeats = true
    controller.start()

    clock.advance(60 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1) // first hour

    clock.advance(60 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 2) // second hour, fires again
    #expect(reminder.notices.last?.body.contains("2 hours") == true)
}

@MainActor
@Test func recurringDoesNotFloodAfterLongGap() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 60 * 60
    controller.reminderRepeats = true
    controller.start()

    clock.advance(5 * 60 * 60) // 5 intervals at once (e.g. across a sleep)
    controller.reconcile()
    #expect(reminder.notices.count == 1) // one nudge, not five
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

    controller.start() // new session
    clock.advance(120)
    controller.reconcile()
    #expect(reminder.notices.count == 2) // fires again for the fresh session
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

    controller.reconcile() // gate activates
    clock.advance(120)
    controller.reconcile()
    #expect(reminder.notices.count == 1)

    gate.satisfied = false
    controller.reconcile() // gate deactivates → cancel + reset
    #expect(reminder.cancelCount == 1)

    gate.satisfied = true
    controller.reconcile() // reactivates with a fresh clock baseline
    clock.advance(120)
    controller.reconcile()
    #expect(reminder.notices.count == 2)
}

/// A gate whose decision the test flips directly.
private final class StubReminderGate: TriggerEvaluating {
    var satisfied: Bool
    init(_ satisfied: Bool) { self.satisfied = satisfied }
    func isSatisfied() -> Bool { satisfied }
}

// MARK: - Session-end notification and action

/// Records the actions performed when a session ends.
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
    #expect(endActor.performed == [.sleepDisplay])
}

@MainActor
@Test func aManualStopDoesNotFireEndEffects() {
    let (controller, reminder, endActor, _) = makeEndController()
    controller.notifyOnEnd = true
    controller.endAction = .sleepDisplay
    controller.start()
    controller.stop() // user-initiated: no surprise notification or action
    #expect(reminder.notices.isEmpty)
    #expect(endActor.performed.isEmpty)
}

@MainActor
@Test func endEffectsFireWhenTriggerConditionsDrop() {
    let (controller, reminder, endActor, _) = makeEndController()
    controller.notifyOnEnd = true
    controller.endAction = .startScreensaver
    let gate = StubReminderGate(true)
    controller.triggerGate = gate

    controller.reconcile() // conditions met: activates
    #expect(controller.isActive)
    gate.satisfied = false
    controller.reconcile() // conditions drop: ends on its own
    #expect(controller.isActive == false)
    #expect(reminder.notices.contains { $0.title == "Keepresso stopped" })
    #expect(endActor.performed == [.startScreensaver])
}

@MainActor
@Test func endEffectsStayQuietWhenTheOptionsAreOff() {
    let (controller, reminder, endActor, clock) = makeEndController()
    // notifyOnEnd false, endAction .none (defaults)
    controller.start(mode: .timed(duration: 30))
    clock.advance(31)
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(reminder.notices.isEmpty)
    #expect(endActor.performed.isEmpty)
}

// MARK: - Ending soon

@MainActor
@Test func endingSoonFiresOnceInsideTheNoticeWindow() {
    let (controller, reminder, clock) = makeController()
    controller.endingSoonNotice = 5 * 60
    controller.start()
    controller.stopIn(15 * 60)

    clock.advance(9 * 60)
    controller.reconcile()
    #expect(reminder.notices.isEmpty) // 6 min left: outside the window

    clock.advance(90)
    controller.reconcile()
    #expect(reminder.notices.count == 1) // 4.5 min left: fired
    #expect(reminder.notices.first?.title == "Keepresso stops soon")

    clock.advance(60)
    controller.reconcile()
    #expect(reminder.notices.count == 1) // one-shot per arming
}

@MainActor
@Test func endingSoonSuppressedWhenTheCountdownStartsInsideTheWindow() {
    let (controller, reminder, clock) = makeController()
    controller.endingSoonNotice = 5 * 60
    controller.start(mode: .timed(duration: 3 * 60)) // already inside
    clock.advance(60)
    controller.reconcile()
    #expect(reminder.notices.isEmpty)

    controller.stop()
    controller.start()
    controller.stopIn(2 * 60) // quick stop shorter than the notice
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
    #expect(reminder.notices.count == 1) // 4 min left: fired

    controller.stopIn(20 * 60) // extend: re-arms
    clock.advance(16 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 2) // fired again at the new crossing
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
@Test func stopInDoesNotResetTheReminderCounter() {
    let (controller, reminder, clock) = makeController()
    controller.reminderAfter = 30 * 60
    controller.start()
    clock.advance(31 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1) // mid-session reminder fired

    controller.stopIn(60 * 60) // continue, don't restart
    clock.advance(10 * 60)
    controller.reconcile()
    #expect(reminder.notices.count == 1) // same interval, no duplicate
}
