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
