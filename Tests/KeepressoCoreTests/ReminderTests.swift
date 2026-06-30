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
