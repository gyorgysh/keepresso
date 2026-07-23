import Testing
import Foundation
@testable import KeepressoCore

/// In-memory power-assertion backend that records the last applied set.
private final class FakeAssertions: PowerAsserting {
    private(set) var held: Set<PowerAssertionKind> = []
    func apply(_ kinds: Set<PowerAssertionKind>, reason: String) { held = kinds }
}

/// A controllable clock shared with the controller under test.
@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

/// Records how often the keep-active poke fires.
private final class FakeActivity: ActivitySimulating {
    private(set) var pokeCount = 0
    func poke() { pokeCount += 1 }
}

@MainActor
@Test func keepActivePokesOnceOnActivationThenOnTheInterval() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true))
    #expect(activity.pokeCount == 1) // start reconciles: pokes immediately

    controller.reconcile() // same second
    #expect(activity.pokeCount == 1) // not again within the interval

    clock.advance(SessionController.activityPokeInterval)
    controller.reconcile()
    #expect(activity.pokeCount == 2) // interval elapsed: pokes again
}

@MainActor
@Test func keepActiveNeverPokesWhenTheOptionIsOff() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start() // simulateUserActivity defaults off
    clock.advance(120)
    controller.reconcile()
    #expect(activity.pokeCount == 0)
}

@MainActor
@Test func keepActiveSkipsThePokeWhileTheUserIsActive() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true))
    #expect(activity.pokeCount == 1) // initial poke (no idle info at start)

    // The user is actively providing input (low idle, e.g. gaming): no nudge,
    // even across the poke interval.
    clock.advance(60)
    controller.reconcile(systemIdleSeconds: 2)
    controller.reconcile(systemIdleSeconds: 1)
    #expect(activity.pokeCount == 1)

    // Once they step away past the threshold, it pokes promptly.
    controller.reconcile(systemIdleSeconds: 30)
    #expect(activity.pokeCount == 2)
}

@MainActor
@Test func keepActivePokesAgainImmediatelyOnANewSession() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    let options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    controller.start(options: options)
    #expect(activity.pokeCount == 1)
    controller.stop()
    clock.advance(5) // well within the interval
    controller.start(options: options)
    #expect(activity.pokeCount == 2) // the fresh session pokes right away
}

@MainActor
private func makeController() -> (SessionController, FakeAssertions, Clock) {
    let fake = FakeAssertions()
    let clock = Clock()
    let controller = SessionController(assertions: fake, now: { clock.now })
    return (controller, fake, clock)
}

@MainActor
@Test func idleHoldsNoAssertions() {
    let (controller, fake, _) = makeController()
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func startTakesSystemAssertionByDefault() {
    let (controller, fake, _) = makeController()
    controller.start()
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func displayOptionAddsDisplayAssertion() {
    let (controller, fake, _) = makeController()
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    #expect(fake.held == [.system, .display])
}

@MainActor
@Test func stopReleasesEverything() {
    let (controller, fake, _) = makeController()
    controller.start()
    controller.stop()
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func toggleFlipsState() {
    let (controller, _, _) = makeController()
    controller.toggle()
    #expect(controller.isActive)
    controller.toggle()
    #expect(controller.isActive == false)
}

@MainActor
@Test func timedSessionExpiresOnReconcile() {
    let (controller, fake, clock) = makeController()
    controller.start(mode: .timed(duration: 60))
    #expect(controller.isActive)

    clock.advance(59)
    controller.reconcile()
    #expect(controller.isActive) // before the deadline

    clock.advance(2) // 61s elapsed
    controller.reconcile()
    #expect(controller.isActive == false) // auto-stopped
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func elapsedAndRemaining() {
    let (controller, _, clock) = makeController()
    controller.start(mode: .timed(duration: 120))
    clock.advance(30)
    #expect(abs(controller.elapsed - 30) < 0.001)
    #expect(abs((controller.remaining ?? -1) - 90) < 0.001)
}

/// A gate whose decision the test flips directly.
private final class StubGate: TriggerEvaluating {
    var satisfied: Bool
    private(set) var ticks = 0
    init(_ satisfied: Bool) { self.satisfied = satisfied }
    func tick() { ticks += 1 }
    func isSatisfied() -> Bool { satisfied }
}

@MainActor
@Test func triggerGateDrivesActivationOnReconcile() {
    let (controller, fake, _) = makeController()
    let gate = StubGate(false)
    controller.triggerGate = gate

    controller.reconcile()
    #expect(controller.isActive == false) // gate off → idle
    #expect(fake.held.isEmpty)

    gate.satisfied = true
    controller.reconcile()
    #expect(controller.isActive) // gate on → activates
    #expect(fake.held == [.system])

    gate.satisfied = false
    controller.reconcile()
    #expect(controller.isActive == false) // gate off → releases
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func gatedSessionKeepsStartTimeWhileHeld() {
    let (controller, _, clock) = makeController()
    let gate = StubGate(true)
    controller.triggerGate = gate

    controller.reconcile()
    let started = controller.startedAt
    #expect(started != nil)

    clock.advance(30)
    controller.reconcile() // still satisfied
    #expect(controller.startedAt == started) // not restarted
    #expect(abs(controller.elapsed - 30) < 0.001)
}

@MainActor
@Test func gatedSessionHasNoRemainingEvenWithLeftoverTimedMode() {
    let (controller, _, clock) = makeController()
    controller.start(mode: .timed(duration: 3600)) // a 1h manual session
    clock.advance(10)
    #expect(controller.remaining != nil) // counting down while manual

    controller.triggerGate = StubGate(true) // triggers take over mid-session
    controller.reconcile()
    #expect(controller.isActive) // gate holds it on
    #expect(controller.remaining == nil) // but no countdown: gating isn't time-boxed
}

@MainActor
@Test func gatedSessionIgnoresTimedExpiry() {
    let (controller, fake, clock) = makeController()
    let gate = StubGate(true)
    controller.triggerGate = gate
    controller.start(mode: .timed(duration: 60))

    clock.advance(120) // well past the timed cap
    controller.reconcile()
    #expect(controller.isActive) // gate still owns activation
    #expect(fake.held == [.system])
}

@MainActor
@Test func screenSaverYieldDropsDisplayAssertion() {
    let (controller, fake, _) = makeController()
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true,
        preventDisplaySleep: true,
        allowScreenSaverAfter: 300
    ))
    #expect(fake.held == [.system, .display])

    controller.reconcile(systemIdleSeconds: 100) // below threshold
    #expect(fake.held == [.system, .display])

    controller.reconcile(systemIdleSeconds: 301) // past threshold → yield display
    #expect(fake.held == [.system])
}

@MainActor
@Test func lowBatteryForceStopsActiveSession() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.start()
    #expect(controller.isActive)

    controller.reconcile(battery: .discharging(15))
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func lowBatteryBlocksTriggerGateReactivation() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    let gate = StubGate(true)
    controller.triggerGate = gate

    controller.reconcile(battery: .discharging(10)) // low: stays idle even though gate wants on
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)

    controller.reconcile(battery: .discharging(50)) // recovered: gate resumes control
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func batteryPauseHasResumeHysteresis() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.triggerGate = StubGate(true)

    controller.reconcile(battery: .discharging(19)) // below cutoff: pause
    #expect(controller.isActive == false)
    #expect(controller.pausedByBattery) // exposed so the UI can explain the hold

    // A reading back at (or just above) the cutoff must NOT reactivate: without
    // a dead-band a value bouncing 19/20/19/20 would flap on and off each tick.
    controller.reconcile(battery: .discharging(20))
    #expect(controller.isActive == false)
    controller.reconcile(battery: .discharging(22)) // still inside the resume margin
    #expect(controller.isActive == false)

    controller.reconcile(battery: .discharging(23)) // clears cutoff + margin: resume
    #expect(controller.isActive)
    #expect(controller.pausedByBattery == false)
    #expect(fake.held == [.system])
}

@MainActor
@Test func batteryThresholdIgnoredWhenNoReadingSupplied() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.start()

    controller.reconcile() // no battery reading (e.g. desktop Mac) → no override
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func manualStartWhileBatteryPausedStaysPaused() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.triggerGate = StubGate(true)
    controller.reconcile(battery: .discharging(15))
    #expect(controller.pausedByBattery)

    // A hotkey/menu/widget start must not activate for one tick and then be
    // re-paused with natural-end effects: it stays paused, and the internal
    // no-reading reconcile inside any start path must not clear the latch.
    controller.start()
    #expect(controller.isActive == false)
    #expect(controller.pausedByBattery)
    #expect(fake.held.isEmpty)

    controller.reconcile() // internal-style reconcile: latch still holds
    #expect(controller.pausedByBattery)
    #expect(controller.isActive == false)
}

@MainActor
@Test func refusedStartsWhileBatteryPausedAreCounted() {
    let (controller, _, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.reconcile(battery: .discharging(15))
    #expect(controller.pausedByBattery)
    #expect(controller.batteryRefusedStarts == 0)

    // Each refused user attempt bumps the counter, so the UI can nudge its
    // "paused on low battery" explanation exactly when the user pokes it.
    controller.start()
    #expect(controller.batteryRefusedStarts == 1)
    controller.start()
    #expect(controller.batteryRefusedStarts == 2)

    // A start that actually begins doesn't count as a refusal.
    controller.reconcile(battery: .onAC)
    controller.start()
    #expect(controller.isActive)
    #expect(controller.batteryRefusedStarts == 2)
}

// MARK: - Thermal pause

@MainActor
@Test func hotReadingForceStopsAnActiveSession() {
    let (controller, fake, _) = makeController()
    controller.pauseWhenHot = true
    controller.start()
    #expect(controller.isActive)

    controller.reconcile(thermal: .hot)
    #expect(controller.isActive == false)
    #expect(controller.pausedByThermal)
    #expect(fake.held.isEmpty)

    // Recovery releases the latch; the session does not restart on its own
    // (it was a manual session, the user starts it again).
    controller.reconcile(thermal: .clear)
    #expect(controller.pausedByThermal == false)
    #expect(controller.isActive == false)
}

@MainActor
@Test func hotReadingBlocksTriggerGateReactivation() {
    let (controller, fake, _) = makeController()
    controller.pauseWhenHot = true
    controller.triggerGate = StubGate(true)
    controller.reconcile(thermal: .hot)
    #expect(controller.pausedByThermal)
    #expect(controller.isActive == false)

    // The gate stays satisfied, but the pause outranks it every tick.
    controller.reconcile(thermal: .hot)
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)

    // On all-clear the very same reconcile lets the gate reactivate.
    controller.reconcile(thermal: .clear)
    #expect(controller.isActive)
}

@MainActor
@Test func unknownThermalReadingHoldsTheLatchAcrossStarts() {
    let (controller, fake, _) = makeController()
    controller.pauseWhenHot = true
    controller.reconcile(thermal: .hot)
    #expect(controller.pausedByThermal)

    // A manual start must not activate for one tick: start()'s internal
    // reconcile passes .unknown, which leaves the latch alone.
    controller.start()
    #expect(controller.isActive == false)
    #expect(controller.pausedByThermal)
    #expect(fake.held.isEmpty)

    controller.reconcile() // internal-style reconcile: still latched
    #expect(controller.pausedByThermal)
}

@MainActor
@Test func refusedStartsCombineBothSafetyPauses() {
    let (controller, _, _) = makeController()
    controller.pauseWhenHot = true
    controller.reconcile(thermal: .hot)
    controller.start()
    controller.start()
    #expect(controller.thermalRefusedStarts == 2)
    #expect(controller.refusedStarts == 2)

    // Battery refusals land in the same combined counter.
    controller.reconcile(thermal: .clear)
    controller.pauseBelowBatteryPercent = 20
    controller.reconcile(battery: .discharging(15))
    controller.start()
    #expect(controller.batteryRefusedStarts == 1)
    #expect(controller.refusedStarts == 3)
}

@MainActor
@Test func disablingPauseWhenHotClearsAStaleLatch() {
    let (controller, _, _) = makeController()
    controller.pauseWhenHot = true
    controller.reconcile(thermal: .hot)
    #expect(controller.pausedByThermal)

    controller.pauseWhenHot = false
    controller.reconcile() // no reading needed; feature off clears the latch
    #expect(controller.pausedByThermal == false)
    controller.start()
    #expect(controller.isActive)
}

@MainActor
@Test func batteryAndThermalPausesHandOverCleanly() {
    let (controller, _, _) = makeController()
    controller.pauseWhenHot = true
    controller.pauseBelowBatteryPercent = 20

    // The battery block runs first and holds while latched, so a simultaneous
    // hot reading defers: everything is stopped anyway, one latch suffices.
    controller.reconcile(battery: .discharging(15), thermal: .hot)
    #expect(controller.pausedByBattery)
    #expect(controller.pausedByThermal == false)

    // Plugging in lifts the battery pause; the still-hot reading latches the
    // thermal pause on the very same reconcile, so there is no unprotected gap.
    controller.reconcile(battery: .onAC, thermal: .hot)
    #expect(controller.pausedByBattery == false)
    #expect(controller.pausedByThermal)
    controller.start()
    #expect(controller.isActive == false)

    // Cooling releases the last hold; now a start works.
    controller.reconcile(battery: .onAC, thermal: .clear)
    controller.start()
    #expect(controller.isActive)
}

@MainActor
@Test func pluggingInLiftsTheBatteryPause() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.triggerGate = StubGate(true)
    controller.reconcile(battery: .discharging(15))
    #expect(controller.pausedByBattery)

    controller.reconcile(battery: .onAC) // on AC the pause is moot
    #expect(controller.pausedByBattery == false)
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func batteryPauseKeepsTickingTheTriggerGate() {
    let (controller, _, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    let gate = StubGate(true)
    controller.triggerGate = gate
    controller.reconcile(battery: .discharging(10))
    let before = gate.ticks

    controller.reconcile(battery: .discharging(10)) // still paused
    controller.reconcile()                          // paused, no reading
    #expect(gate.ticks == before + 2) // rule state keeps advancing while paused
}

/// Records posted notifications, for the battery-pause notice tests.
private final class FakeReminder: ReminderNotifying {
    private(set) var notices: [(title: String, body: String, sound: Bool)] = []
    func notify(title: String, body: String, sound: Bool) { notices.append((title, body, sound)) }
    func cancelPending() {}
}

@MainActor
@Test func batteryPauseExplainsItselfInANotification() {
    let reminder = FakeReminder()
    let clock = Clock()
    let controller = SessionController(assertions: FakeAssertions(), reminder: reminder, now: { clock.now })
    controller.pauseBelowBatteryPercent = 20
    controller.notifyOnEnd = true // must not add a second, generic notification
    controller.start()

    controller.reconcile(battery: .discharging(15))
    #expect(controller.pausedByBattery)
    #expect(reminder.notices.count == 1)
    #expect(reminder.notices.first?.title == "Paused on low battery")
    #expect(reminder.notices.first?.body.contains("15%") == true)
    // Resuming is tied to charging, not to a charge level: on battery the
    // percentage only ever falls, so the notice tells the user to plug in.
    #expect(reminder.notices.first?.body.contains("plug in") == true)

    // Staying below the cutoff must not repeat the notice every tick.
    controller.reconcile(battery: .discharging(14))
    #expect(reminder.notices.count == 1)
}

@MainActor
@Test func batteryPauseNotifiesEvenWithEndNotificationsOff() {
    let reminder = FakeReminder()
    let clock = Clock()
    let controller = SessionController(assertions: FakeAssertions(), reminder: reminder, now: { clock.now })
    controller.pauseBelowBatteryPercent = 20
    controller.start() // notifyOnEnd stays false

    controller.reconcile(battery: .discharging(15))
    #expect(reminder.notices.count == 1)
    #expect(reminder.notices.first?.title == "Paused on low battery")
}

@MainActor
@Test func batteryPauseLatchingWhileIdleStaysQuiet() {
    let reminder = FakeReminder()
    let clock = Clock()
    let controller = SessionController(assertions: FakeAssertions(), reminder: reminder, now: { clock.now })
    controller.pauseBelowBatteryPercent = 20

    // No session running: the latch engages, but nothing visibly changed for
    // the user, so there is nothing to announce.
    controller.reconcile(battery: .discharging(15))
    #expect(controller.pausedByBattery)
    #expect(reminder.notices.isEmpty)
}

// MARK: - Stop in N

@MainActor
@Test func stopInConvertsIndefiniteSessionKeepingStartedAt() {
    let (controller, fake, clock) = makeController()
    controller.start() // indefinite
    let started = controller.startedAt
    clock.advance(10 * 60)

    controller.stopIn(15 * 60)
    #expect(controller.startedAt == started) // continues, not restarted
    #expect(abs((controller.remaining ?? -1) - 15 * 60) < 0.001)

    clock.advance(15 * 60 - 1)
    controller.reconcile()
    #expect(controller.isActive) // just before the deadline

    clock.advance(2)
    controller.reconcile()
    #expect(controller.isActive == false) // ended on its own
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func stopInShortensAndExtendsATimedSession() {
    let (controller, _, clock) = makeController()
    controller.start(mode: .timed(duration: 60 * 60))
    clock.advance(60)

    controller.stopIn(5 * 60) // shorten
    #expect(abs((controller.remaining ?? -1) - 5 * 60) < 0.001)

    controller.stopIn(30 * 60) // extend, replacing the countdown
    #expect(abs((controller.remaining ?? -1) - 30 * 60) < 0.001)
}

@MainActor
@Test func stopInIsIgnoredWhileIdleGatedOrNonPositive() {
    let (controller, _, _) = makeController()
    controller.stopIn(15 * 60) // idle: nothing to convert
    #expect(controller.isActive == false)
    #expect(controller.mode == .indefinite)

    controller.start()
    controller.stopIn(0) // non-positive: ignored
    #expect(controller.remaining == nil)

    controller.triggerGate = StubGate(true)
    controller.reconcile()
    controller.stopIn(15 * 60) // gated sessions aren't time-boxed
    #expect(controller.mode == .indefinite)
}

// MARK: - Automation leases

/// A lease provider whose demand the test scripts directly.
@MainActor
private final class FakeLeaseProvider: LeaseProviding {
    var summaries: [LeaseSummary] = []
    private(set) var ticks = 0
    private(set) var revokeCalls = 0

    func tick(now: Date) -> [LeaseSummary] {
        ticks += 1
        return summaries
    }

    func revokeAll(now: Date) {
        revokeCalls += 1
        summaries = []
    }
}

private final class RecordingEndActor: SessionEndActing {
    private(set) var performed: [SessionEndAction] = []
    func perform(_ action: SessionEndAction) { performed.append(action) }
}

@MainActor
private func leaseSummary(
    id: String = "aaaaaaaa-1111-2222-3333-444444444444",
    tool: String = "test-tool",
    task: String = "a task",
    expiresAt: Date = Date(timeIntervalSince1970: 1_000_300)
) -> LeaseSummary {
    LeaseSummary(id: id, owner: "tester", tool: tool, task: task, expiresAt: expiresAt)
}

@MainActor
@Test func leaseDemandActivatesAnIdleController() {
    let (controller, fake, _) = makeController()
    let provider = FakeLeaseProvider()
    controller.leases = provider

    controller.reconcile()
    #expect(controller.isActive == false)

    provider.summaries = [leaseSummary()]
    controller.reconcile()
    #expect(controller.isActive)
    #expect(fake.held == [.system])
    #expect(controller.liveLeases.count == 1)
    #expect(controller.log.events.last?.kind == .leaseAcquired)
    // Lease sessions never count down.
    #expect(controller.remaining == nil)
}

@MainActor
@Test func leaseSessionNeverHoldsTheDisplayAssertion() {
    let (controller, fake, _) = makeController()
    controller.options = SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true)
    let provider = FakeLeaseProvider()
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile()
    #expect(fake.held == [.system])

    // A manual session with the same options still gets the display.
    controller.start()
    controller.reconcile()
    #expect(fake.held == [.system, .display])
}

@MainActor
@Test func lastLeaseEndFiresTheEndActionAfterDebounce() {
    let fake = FakeAssertions()
    let clock = Clock()
    let endActor = RecordingEndActor()
    let controller = SessionController(assertions: fake, endActor: endActor, now: { clock.now })
    controller.endAction = .sleepDisplay
    let provider = FakeLeaseProvider()
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile()
    #expect(controller.isActive)

    provider.summaries = []
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(controller.log.events.last?.kind == .leaseReleased)
    #expect(fake.held.isEmpty)
    #expect(endActor.performed.isEmpty) // debounce pending

    clock.advance(SessionController.endActionDebounce)
    controller.reconcile()
    #expect(endActor.performed == [.sleepDisplay])
}

@MainActor
@Test func manualSessionIgnoresLeaseComingsAndGoings() {
    let (controller, fake, _) = makeController()
    let provider = FakeLeaseProvider()
    controller.leases = provider

    controller.start()
    provider.summaries = [leaseSummary()]
    controller.reconcile()
    #expect(controller.isActive)

    // The lease vanishing changes nothing: the manual demand persists.
    provider.summaries = []
    controller.reconcile()
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func manualStartTakesOwnershipOfALeaseSession() {
    let (controller, _, _) = makeController()
    let provider = FakeLeaseProvider()
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile()
    #expect(controller.isActive)

    controller.start()
    provider.summaries = []
    controller.reconcile()
    // The session is manual now; lease expiry no longer ends it.
    #expect(controller.isActive)
}

@MainActor
@Test func timedExpiryConvertsToALeaseSessionWithoutFiringTheEndAction() {
    let fake = FakeAssertions()
    let clock = Clock()
    let endActor = RecordingEndActor()
    let controller = SessionController(assertions: fake, endActor: endActor, now: { clock.now })
    controller.endAction = .sleepMac
    let provider = FakeLeaseProvider()
    controller.leases = provider

    controller.start(mode: .timed(duration: 60))
    provider.summaries = [leaseSummary()]
    clock.advance(61)
    controller.reconcile()

    // The timed session ended and a lease session took over in the same tick.
    #expect(controller.isActive)
    #expect(controller.log.events.last?.kind == .leaseAcquired)
    #expect(controller.remaining == nil)
    #expect(fake.held == [.system])

    // The converted session must not fire the timed session's end action.
    clock.advance(SessionController.endActionDebounce + 1)
    controller.reconcile()
    #expect(endActor.performed.isEmpty)

    // The lease ending later is a natural end: now the action fires.
    provider.summaries = []
    controller.reconcile()
    clock.advance(SessionController.endActionDebounce)
    controller.reconcile()
    #expect(endActor.performed == [.sleepMac])
}

@MainActor
@Test func gateAndLeaseDemandUnionInTriggerMode() {
    let (controller, fake, _) = makeController()
    let gate = StubGate(true)
    let provider = FakeLeaseProvider()
    controller.triggerGate = gate
    controller.leases = provider

    controller.reconcile()
    #expect(controller.isActive)
    #expect(controller.log.events.last?.kind == .triggerFired)

    // The gate drops but a lease sustains the session.
    provider.summaries = [leaseSummary()]
    gate.satisfied = false
    controller.reconcile()
    #expect(controller.isActive)

    // The lease ending is attributed to the lease, not the trigger.
    provider.summaries = []
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(controller.log.events.last?.kind == .leaseReleased)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func leaseActivationInTriggerModeLogsTheLease() {
    let (controller, _, _) = makeController()
    let gate = StubGate(false)
    let provider = FakeLeaseProvider()
    controller.triggerGate = gate
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile()
    #expect(controller.isActive)
    #expect(controller.log.events.last?.kind == .leaseAcquired)

    // The gate turning on hands ownership to the triggers; the lease
    // vanishing then leaves the session up.
    gate.satisfied = true
    controller.reconcile()
    provider.summaries = []
    controller.reconcile()
    #expect(controller.isActive)
}

@MainActor
@Test func batteryPauseOutranksLeaseDemand() {
    let (controller, fake, clock) = makeController()
    controller.pauseBelowBatteryPercent = 20
    let provider = FakeLeaseProvider()
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile(battery: .discharging(50))
    #expect(controller.isActive)

    controller.reconcile(battery: .discharging(10))
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)

    // Still paused: lease demand cannot reactivate.
    clock.advance(1)
    controller.reconcile(battery: .discharging(10))
    #expect(controller.isActive == false)

    // Power is back: the surviving lease resumes the session.
    controller.reconcile(battery: .onAC)
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func stopInIsIgnoredForLeaseHeldSessions() {
    let (controller, _, clock) = makeController()
    let provider = FakeLeaseProvider()
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile()
    controller.stopIn(60)
    #expect(controller.remaining == nil)

    clock.advance(120)
    controller.reconcile()
    #expect(controller.isActive) // no timed cap crept in
}

@MainActor
@Test func thermalPauseOutranksLeaseDemand() {
    let (controller, fake, clock) = makeController()
    controller.pauseWhenHot = true
    let provider = FakeLeaseProvider()
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile(thermal: .clear)
    #expect(controller.isActive)

    controller.reconcile(thermal: .hot)
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)

    // Still hot, and an internal reconcile with no reading: lease demand
    // cannot reactivate through either path.
    clock.advance(1)
    controller.reconcile(thermal: .hot)
    #expect(controller.isActive == false)
    controller.reconcile()
    #expect(controller.isActive == false)

    // Cooled down: the surviving lease resumes the session.
    controller.reconcile(thermal: .clear)
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func leaseExpiryNoticedLateSkipsTheEndAction() {
    let fake = FakeAssertions()
    let clock = Clock()
    let endActor = RecordingEndActor()
    let controller = SessionController(assertions: fake, endActor: endActor, now: { clock.now })
    controller.endAction = .sleepMac
    let provider = FakeLeaseProvider()
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile()
    #expect(controller.isActive)

    // The Mac slept across the lease's expiry: the end is noticed hours
    // late and must not re-sleep the Mac someone just woke.
    clock.advance(3_600)
    provider.summaries = []
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(controller.log.events.last?.kind == .leaseReleased)

    clock.advance(SessionController.endActionDebounce + 1)
    controller.reconcile()
    #expect(endActor.performed.isEmpty)
}

@MainActor
@Test func handOffToLeasesConvertsAGateHeldSessionInPlace() {
    let (controller, fake, clock) = makeController()
    controller.options = SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true)
    let gate = StubGate(true)
    let provider = FakeLeaseProvider()
    controller.triggerGate = gate
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile()
    #expect(controller.isActive)
    #expect(controller.isLeaseHeld == false)
    let begun = controller.startedAt
    let logged = controller.log.events.count

    // The app pauses triggers: the gate detaches and the session hands
    // over to the live lease with no stop/restart pair in the log.
    controller.triggerGate = nil
    controller.handOffToLeases()
    clock.advance(1)
    controller.reconcile()
    #expect(controller.isActive)
    #expect(controller.isLeaseHeld)
    #expect(controller.startedAt == begun)
    #expect(controller.log.events.count == logged)
    #expect(fake.held == [.system]) // lease sessions never hold the display

    // The lease ending promptly afterwards is a natural lease end.
    clock.advance(1)
    provider.summaries = []
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(controller.log.events.last?.kind == .leaseReleased)
}
