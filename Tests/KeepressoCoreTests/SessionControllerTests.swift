import Testing
import Foundation
@testable import KeepressoCore

private final class FakeAssertions: PowerAsserting {
    private(set) var held: Set<PowerAssertionKind> = []
    var refuse: Set<PowerAssertionKind> = []
    func apply(_ kinds: Set<PowerAssertionKind>, reason: String) {
        held = kinds.subtracting(refuse)
    }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

private final class FakeActivity: ActivitySimulating {
    private(set) var pokes: [ActivityPokeKind] = []
    var pokeCount: Int { pokes.count }
    func poke(_ kind: ActivityPokeKind) { pokes.append(kind) }
}

private final class FakeBrightness: BrightnessControlling {
    var supported: Bool
    var keyboardSupported: Bool
    var level: Double
    var keyboardLevel: Double
    private(set) var setLevels: [Double] = []
    private(set) var setKeyboardLevels: [Double] = []
    init(supported: Bool = true, keyboardSupported: Bool = true, level: Double = 0.8, keyboardLevel: Double = 0.5) {
        self.supported = supported
        self.keyboardSupported = keyboardSupported
        self.level = level
        self.keyboardLevel = keyboardLevel
    }
    var isSupported: Bool { supported }
    func currentBrightness() -> Double? { supported ? level : nil }
    func setBrightness(_ newLevel: Double) { level = newLevel; setLevels.append(newLevel) }
    var isKeyboardSupported: Bool { keyboardSupported }
    func currentKeyboardBrightness() -> Double? { keyboardSupported ? keyboardLevel : nil }
    func setKeyboardBrightness(_ newLevel: Double) {
        keyboardLevel = newLevel
        setKeyboardLevels.append(newLevel)
    }
}

@MainActor
@Test func keepActivePokesOnceOnActivationThenOnTheInterval() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true))
    #expect(activity.pokeCount == 1)

    controller.reconcile()
    #expect(activity.pokeCount == 1)

    clock.advance(SessionController.activityPokeInterval)
    controller.reconcile()
    #expect(activity.pokeCount == 2)
    #expect(activity.pokes == [.powerWarp, .powerWarp])
}

@MainActor
@Test func keepActiveNeverPokesWhenTheOptionIsOff() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start()
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
    #expect(activity.pokeCount == 1)

    clock.advance(60)
    controller.reconcile(systemIdleSeconds: 2)
    controller.reconcile(systemIdleSeconds: 1)
    #expect(activity.pokeCount == 1)

    controller.reconcile(systemIdleSeconds: 30)
    #expect(activity.pokeCount == 2)
}

@MainActor
@Test func keepActiveStaysQuietBetweenSessionsByDefault() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    clock.advance(120)
    controller.reconcile(systemIdleSeconds: 120)
    #expect(activity.pokeCount == 0)

    controller.start()
    #expect(activity.pokeCount == 1)
    controller.stop()
    clock.advance(120)
    controller.reconcile(systemIdleSeconds: 120)
    #expect(activity.pokeCount == 1)
}

@MainActor
@Test func keepActivePokesBetweenSessionsWhenNotScopedToBrewing() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    var options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    options.activityOnlyWhileBrewing = false
    controller.options = options

    clock.advance(30)
    controller.reconcile(systemIdleSeconds: 30)
    #expect(activity.pokeCount == 1)
    controller.reconcile(systemIdleSeconds: 30)
    #expect(activity.pokeCount == 1)
    clock.advance(SessionController.activityPokeInterval)
    controller.reconcile(systemIdleSeconds: 60)
    #expect(activity.pokeCount == 2)
    #expect(!controller.isActive)

    clock.advance(120)
    controller.reconcile(systemIdleSeconds: 1)
    #expect(activity.pokeCount == 2)
}

@MainActor
@Test func keepActiveBetweenSessionsHonorsTheBatteryPause() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    var options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    options.activityOnlyWhileBrewing = false
    controller.options = options
    controller.pauseBelowBatteryPercent = 20

    clock.advance(60)
    controller.reconcile(systemIdleSeconds: 60, battery: .discharging(10))
    clock.advance(60)
    controller.reconcile(systemIdleSeconds: 120, battery: .discharging(10))
    #expect(controller.pausedByBattery)
    #expect(activity.pokeCount == 0)

    clock.advance(60)
    controller.reconcile(systemIdleSeconds: 180, battery: .onAC)
    #expect(activity.pokeCount == 1)
}

@MainActor
@Test func keepActiveBetweenSessionsNeedsAnIdleReading() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    var options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    options.activityOnlyWhileBrewing = false
    controller.options = options

    clock.advance(60)
    controller.reconcile()
    #expect(activity.pokeCount == 0)
    controller.reconcile(systemIdleSeconds: 60)
    #expect(activity.pokeCount == 1)
}

@MainActor
@Test func keepActiveBetweenSessionsHoldsAfterTheEndActionUntilInput() {
    let clock = Clock()
    let activity = FakeActivity()
    let endActor = RecordingEndActor()
    let controller = SessionController(
        assertions: FakeAssertions(), activity: activity, endActor: endActor, now: { clock.now })
    var options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    options.activityOnlyWhileBrewing = false
    controller.options = options
    controller.endAction = .sleepDisplay

    controller.start(mode: .timed(duration: 60))
    clock.advance(60)
    controller.reconcile(systemIdleSeconds: 60)
    #expect(!controller.isActive)
    clock.advance(SessionController.endActionDebounce)
    controller.reconcile(systemIdleSeconds: 63)
    #expect(endActor.performed == [.sleepDisplay])
    let afterAction = activity.pokeCount

    clock.advance(600)
    controller.reconcile(systemIdleSeconds: 663)
    #expect(activity.pokeCount == afterAction)

    controller.reconcile(systemIdleSeconds: 1)
    clock.advance(30)
    controller.reconcile(systemIdleSeconds: 30)
    #expect(activity.pokeCount == afterAction + 1)
}

@MainActor
@Test func keepActiveHoldAfterTheEndActionIgnoresItsOwnPostedInput() {
    let clock = Clock()
    let activity = FakeActivity()
    let endActor = RecordingEndActor()
    let controller = SessionController(
        assertions: FakeAssertions(), activity: activity, endActor: endActor, now: { clock.now })
    var options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    options.activityOnlyWhileBrewing = false
    controller.options = options
    controller.endAction = .sleepDisplay

    controller.start(mode: .timed(duration: 60))
    clock.advance(60)
    controller.reconcile(systemIdleSeconds: 60)
    #expect(!controller.isActive)
    let sessionPokes = activity.pokeCount
    clock.advance(1)
    controller.reconcile(systemIdleSeconds: 61)
    #expect(activity.pokeCount == sessionPokes)
    clock.advance(SessionController.endActionDebounce)
    controller.reconcile(systemIdleSeconds: 4)
    #expect(endActor.performed == [.sleepDisplay])

    for idle in [5.0, 6, 30, 90] as [TimeInterval] {
        clock.advance(30)
        controller.reconcile(systemIdleSeconds: idle)
    }
    #expect(activity.pokeCount == sessionPokes)

    controller.reconcile(systemIdleSeconds: 1)
    clock.advance(30)
    controller.reconcile(systemIdleSeconds: 30)
    #expect(activity.pokeCount == sessionPokes + 1)
}


@MainActor
@Test func keepActiveNilIdleHoldsThePokeCadence() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    var options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    options.activityPokeIdleMinutes = 3
    controller.start(options: options)

    clock.advance(200)
    controller.reconcile(systemIdleSeconds: 200)
    #expect(activity.pokeCount == 1)

    clock.advance(SessionController.activityPokeInterval / 2)
    controller.reconcile(systemIdleSeconds: nil)
    clock.advance(SessionController.activityPokeInterval / 2 - 1)
    controller.reconcile(systemIdleSeconds: 400)
    #expect(activity.pokeCount == 1)

    clock.advance(2)
    controller.reconcile(systemIdleSeconds: 402)
    #expect(activity.pokeCount == 2)
}

@MainActor
@Test func keepActiveIdleOnlyModeWaitsForTheConfiguredMinutes() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    var options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    options.activityPokeIdleMinutes = 3
    controller.start(options: options)
    #expect(activity.pokeCount == 0)

    clock.advance(120)
    controller.reconcile(systemIdleSeconds: 120)
    #expect(activity.pokeCount == 0)

    clock.advance(70)
    controller.reconcile(systemIdleSeconds: 190)
    #expect(activity.pokeCount == 1)
    clock.advance(SessionController.activityPokeInterval)
    controller.reconcile(systemIdleSeconds: 220)
    #expect(activity.pokeCount == 2)
}

@MainActor
@Test func keepActiveIdleOnlyModePausesWhileAGameIsFrontmost() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    var options = SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true)
    options.activityPokeIdleMinutes = 3
    controller.start(options: options)
    #expect(activity.pokeCount == 0)

    clock.advance(300)
    controller.reconcile(systemIdleSeconds: 300, gameFrontmost: true)
    #expect(activity.pokeCount == 0)

    controller.reconcile(systemIdleSeconds: 301, gameFrontmost: false)
    #expect(activity.pokeCount == 1)
}

@MainActor
@Test func keepActiveIgnoresGameFrontmostWhenIdleOnlyModeIsOff() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, simulateUserActivity: true))
    #expect(activity.pokeCount == 1)

    clock.advance(60)
    controller.reconcile(systemIdleSeconds: 60, gameFrontmost: true)
    #expect(activity.pokeCount == 2)
}


@MainActor
@Test func dimDropsBrightnessAfterIdleAndRestoresOnActivity() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.8)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 300, dimFloor: 0))

    controller.reconcile(systemIdleSeconds: 10)
    #expect(brightness.level == 0.8)

    controller.reconcile(systemIdleSeconds: 300)
    #expect(brightness.level == 0)
    let writes = brightness.setLevels.count
    controller.reconcile(systemIdleSeconds: 360)
    #expect(brightness.setLevels.count == writes)

    controller.reconcile(systemIdleSeconds: 1)
    #expect(brightness.level == 0.8)
}

@MainActor
@Test func lidShutWithNoExternalTakesOverFromTheIdleDim() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.6)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 60, dimFloor: 0.2))
    controller.reconcile(systemIdleSeconds: 90)
    #expect(brightness.level == 0.2)

    controller.reconcile(systemIdleSeconds: 120, display: .lidShutNoExternal)
    #expect(brightness.level == 0)

    let writes = brightness.setLevels.count
    controller.reconcile(systemIdleSeconds: 180, display: .lidShutNoExternal)
    #expect(brightness.level == 0)
    #expect(brightness.setLevels.count == writes)

    controller.reconcile(systemIdleSeconds: 200, display: .usable)
    #expect(brightness.level == 0.2)

    controller.reconcile(systemIdleSeconds: 0, display: .usable)
    #expect(brightness.level == 0.6)
}

@MainActor
@Test func lidShutWithNoExternalDarkensThePanelAndKeyboard() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.7, keyboardLevel: 0.4)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    controller.reconcile(display: .usable)

    controller.reconcile(display: .lidShutNoExternal)
    #expect(brightness.level == 0)
    #expect(brightness.keyboardLevel == 0)

    controller.reconcile(display: .usable)
    #expect(brightness.level == 0.7)
    #expect(brightness.keyboardLevel == 0.4)
}

@MainActor
@Test func dimRestoresBrightnessWhenTheSessionStops() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.7)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 60, dimFloor: 0.05))
    controller.reconcile(systemIdleSeconds: 90)
    #expect(brightness.level == 0.05)

    controller.stop()
    #expect(brightness.level == 0.7)
}

@MainActor
@Test func dimStaysInertWhenUnsupportedOrUnconfigured() {
    let clock = Clock()
    let unsupported = FakeBrightness(supported: false, level: 0.9)
    let a = SessionController(assertions: FakeAssertions(), brightness: unsupported, now: { clock.now })
    a.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 30))
    a.reconcile(systemIdleSeconds: 300)
    #expect(unsupported.setLevels.isEmpty)

    let supported = FakeBrightness(level: 0.9)
    let b = SessionController(assertions: FakeAssertions(), brightness: supported, now: { clock.now })
    b.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    b.reconcile(systemIdleSeconds: 300)
    #expect(supported.setLevels.isEmpty)
    #expect(!b.consumesIdleReading)
}

@MainActor
@Test func dimConfigMakesTheControllerConsumeIdle() {
    let controller = SessionController(assertions: FakeAssertions())
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 120))
    #expect(controller.consumesIdleReading)
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
    clock.advance(5)
    controller.start(options: options)
    #expect(activity.pokeCount == 2)
}

@MainActor
@Test func keepActiveHIDMethodUsesSixtySecondIntervalAndPostsTheKey() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true,
        simulateUserActivity: true,
        activitySimulationMethod: .f15
    ))
    #expect(activity.pokes == [.key(ActivitySimulationMethod.f15KeyCode)])

    clock.advance(SessionController.activityPokeInterval)
    controller.reconcile()
    #expect(activity.pokeCount == 1)

    clock.advance(ActivitySimulationMethod.f15.pokeInterval - SessionController.activityPokeInterval)
    controller.reconcile()
    #expect(activity.pokes == [
        .key(ActivitySimulationMethod.f15KeyCode),
        .key(ActivitySimulationMethod.f15KeyCode),
    ])
}

@MainActor
private final class IdleResettingActivity: ActivitySimulating {
    let clock: Clock
    var lastInput: Date
    private(set) var pokeTimes: [Date] = []
    init(clock: Clock) { self.clock = clock; lastInput = clock.now }
    var idle: TimeInterval { clock.now.timeIntervalSince(lastInput) }
    nonisolated func poke(_: ActivityPokeKind) {
        MainActor.assumeIsolated {
            pokeTimes.append(clock.now)
            lastInput = clock.now
        }
    }
}

@MainActor
@Test func keepActiveHIDPokeDoesNotCountItsOwnIdleResetAsInput() {
    // GitHub #35: the key poke resets HID idle, which read as the user being
    // back, re-armed the poke, and fired it every ~11 s instead of every 60 s.
    let clock = Clock()
    let activity = IdleResettingActivity(clock: clock)
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true,
        simulateUserActivity: true,
        activitySimulationMethod: .f15
    ))
    let start = clock.now
    for _ in 0..<180 {
        clock.advance(1)
        controller.reconcile(systemIdleSeconds: activity.idle)
    }
    let offsets = activity.pokeTimes.map { $0.timeIntervalSince(start) }
    #expect(offsets == [0, 60, 120, 180])
}

@MainActor
@Test func keepActiveStillSeesRealInputAfterItsOwnPoke() {
    let clock = Clock()
    let activity = IdleResettingActivity(clock: clock)
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true,
        simulateUserActivity: true,
        activitySimulationMethod: .f15
    ))
    #expect(activity.pokeTimes.count == 1)
    let start = clock.now

    for second in 1...100 {
        clock.advance(1)
        if second == 30 { activity.lastInput = clock.now }
        controller.reconcile(systemIdleSeconds: activity.idle)
    }
    let offsets = activity.pokeTimes.map { $0.timeIntervalSince(start) }
    #expect(offsets.first == 0)
    #expect(offsets.dropFirst().first == 30 + SessionController.activityIdleThreshold)
}

@MainActor
@Test func keepActiveIdleOnlyModeKeepsItsCadenceAfterAHIDPoke() {
    let clock = Clock()
    let activity = IdleResettingActivity(clock: clock)
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    var options = SleepPreventionOptions(
        preventSystemSleep: true,
        simulateUserActivity: true,
        activitySimulationMethod: .f15
    )
    options.activityPokeIdleMinutes = 2
    controller.start(options: options)
    let start = clock.now
    for _ in 0..<300 {
        clock.advance(1)
        controller.reconcile(systemIdleSeconds: activity.idle)
    }
    let offsets = activity.pokeTimes.map { $0.timeIntervalSince(start) }
    #expect(offsets == [120, 180, 240, 300])
}

@MainActor
@Test func keepActiveHIDPokeDoesNotBrightenADimmedPanel() {
    let clock = Clock()
    let activity = IdleResettingActivity(clock: clock)
    let brightness = FakeBrightness(level: 0.6)
    let controller = SessionController(
        assertions: FakeAssertions(), activity: activity, brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 30, dimFloor: 0.2,
        simulateUserActivity: true, activitySimulationMethod: .f15))
    for _ in 0..<150 {
        clock.advance(1)
        controller.reconcile(systemIdleSeconds: activity.idle)
    }
    #expect(activity.pokeTimes.count == 3)
    #expect(brightness.setLevels == [0.2])

    activity.lastInput = clock.now
    clock.advance(1)
    controller.reconcile(systemIdleSeconds: activity.idle)
    #expect(brightness.level == 0.6)
}

@MainActor
@Test func keepActiveStartPokeDoesNotBringTheDimForward() {
    let clock = Clock()
    let activity = IdleResettingActivity(clock: clock)
    let brightness = FakeBrightness(level: 0.6)
    let controller = SessionController(
        assertions: FakeAssertions(), activity: activity, brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 30, dimFloor: 0.2,
        simulateUserActivity: true, activitySimulationMethod: .f15))
    for _ in 0..<29 {
        clock.advance(1)
        controller.reconcile(systemIdleSeconds: activity.idle)
    }
    #expect(brightness.setLevels.isEmpty)
    clock.advance(1)
    controller.reconcile(systemIdleSeconds: activity.idle)
    #expect(brightness.setLevels == [0.2])
}

@MainActor
@Test func keepActiveSpecifiedKeyFallsBackUntilAKeyIsRecorded() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    var options = SleepPreventionOptions(
        preventSystemSleep: true,
        simulateUserActivity: true,
        activitySimulationMethod: .specifiedKey
    )
    controller.start(options: options)
    #expect(activity.pokes == [.powerWarp])

    options.activitySimulationKeyCode = 123
    controller.options = options
    clock.advance(SessionController.activityPokeInterval)
    controller.reconcile()
    #expect(activity.pokeCount == 1)

    clock.advance(ActivitySimulationMethod.specifiedKey.pokeInterval - SessionController.activityPokeInterval)
    controller.reconcile()
    #expect(activity.pokes.last == .key(123))
}

@MainActor
@Test func keepActiveMouseMovePostsMouseNotWarp() {
    let clock = Clock()
    let activity = FakeActivity()
    let controller = SessionController(assertions: FakeAssertions(), activity: activity, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true,
        simulateUserActivity: true,
        activitySimulationMethod: .mouseMove
    ))
    #expect(activity.pokes == [.mouseMove])
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
@Test func shutLidDropsTheDisplayAssertionAndRestoresItOnReopen() {
    let (controller, fake, _) = makeController()
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    #expect(fake.held == [.system, .display])

    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system])

    controller.reconcile(display: .usable)
    #expect(fake.held == [.system, .display])
}

@MainActor
@Test func aClamshellDrivingAMonitorKeepsTheDisplayAssertion() {
    let (controller, fake, _) = makeController()
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))

    controller.reconcile(display: .lidShutWithExternal)
    #expect(fake.held == [.system, .display])
}

@MainActor
@Test func zeroBrightnessKeepsClosedLidDisplayAwakePastIdleTimeout() {
    let clock = Clock()
    let fake = FakeAssertions()
    let brightness = FakeBrightness(level: 0.7, keyboardLevel: 0.4)
    let controller = SessionController(assertions: fake, brightness: brightness, now: { clock.now })
    controller.closedLidDisplayPolicy = .zeroBrightness
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    controller.reconcile(display: .usable)

    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system, .display])
    #expect(brightness.level == 0)
    #expect(brightness.keyboardLevel == 0)

    clock.advance(601)
    controller.reconcile(systemIdleSeconds: 601, display: .unknown)
    #expect(fake.held == [.system, .display])
    #expect(brightness.level == 0)

    controller.reconcile(display: .usable)
    #expect(brightness.level == 0.7)
    #expect(brightness.keyboardLevel == 0.4)
    #expect(fake.held == [.system, .display])
}

@MainActor
@Test(arguments: [ClosedLidDisplayPolicy.displayOff, .leaveAlone])
func otherLidPoliciesStillDropTheClosedLidDisplayAssertion(policy: ClosedLidDisplayPolicy) {
    let (controller, fake, _) = makeController()
    controller.closedLidDisplayPolicy = policy
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))

    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system])
}

@MainActor
@Test func zeroBrightnessPolicyChangesApplyWhileTheLidStaysClosed() {
    let (controller, fake, _) = makeController()
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system])

    controller.closedLidDisplayPolicy = .zeroBrightness
    controller.reconcile()
    #expect(fake.held == [.system, .display])

    controller.closedLidDisplayPolicy = .displayOff
    controller.reconcile()
    #expect(fake.held == [.system])
}

@MainActor
@Test func zeroBrightnessStillHonorsTheDisplaySleepOptionAndScreenSaverYield() {
    let (controller, fake, _) = makeController()
    controller.closedLidDisplayPolicy = .zeroBrightness
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: false))
    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system])

    controller.options = SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, allowScreenSaverAfter: 300)
    controller.reconcile(systemIdleSeconds: 299, display: .lidShutNoExternal)
    #expect(fake.held == [.system, .display])
    controller.reconcile(systemIdleSeconds: 300, display: .lidShutNoExternal)
    #expect(fake.held == [.system])
}

@MainActor
@Test(arguments: [false, true])
func zeroBrightnessReleasesDisplayProtectionOnStopOrExpiry(timed: Bool) {
    let (controller, fake, clock) = makeController()
    controller.closedLidDisplayPolicy = .zeroBrightness
    controller.start(
        mode: timed ? .timed(duration: 60) : .indefinite,
        options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system, .display])

    if timed {
        clock.advance(60)
        controller.reconcile(display: .lidShutNoExternal)
    } else {
        controller.stop()
    }
    #expect(!controller.isActive)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test(arguments: [false, true])
func zeroBrightnessReleasesDisplayProtectionDuringSafetyPause(thermal: Bool) {
    let (controller, fake, _) = makeController()
    controller.closedLidDisplayPolicy = .zeroBrightness
    controller.pauseBelowBatteryPercent = 20
    controller.pauseWhenHot = true
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system, .display])

    controller.reconcile(
        battery: thermal ? .onAC : .discharging(10),
        thermal: thermal ? .hot : .clear,
        display: .lidShutNoExternal)
    #expect(!controller.isActive)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func clamshellForcesBuiltInPanelAndKeyboardDarkAndRestoresOnOpen() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.7, keyboardLevel: 0.4)
    let fake = FakeAssertions()
    let controller = SessionController(assertions: fake, brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    #expect(fake.held == [.system, .display])
    #expect(brightness.level == 0.7)
    #expect(brightness.keyboardLevel == 0.4)

    // Open-lid tick seeds the restore cache (required for correct keyboard
    // restore when macOS has already zeroed keys before the clamshell tick).
    controller.reconcile(display: .usable)

    controller.reconcile(display: .lidShutWithExternal)
    #expect(fake.held == [.system, .display])
    #expect(brightness.level == 0)
    #expect(brightness.keyboardLevel == 0)
    let panelWrites = brightness.setLevels.count
    let keyWrites = brightness.setKeyboardLevels.count

    controller.reconcile(display: .lidShutWithExternal)
    #expect(brightness.level == 0)
    #expect(brightness.keyboardLevel == 0)
    #expect(brightness.setLevels.count == panelWrites)
    #expect(brightness.setKeyboardLevels.count == keyWrites)

    controller.reconcile(display: .unknown)
    #expect(fake.held == [.system, .display])
    #expect(brightness.level == 0)
    #expect(brightness.keyboardLevel == 0)

    controller.reconcile(display: .usable)
    #expect(brightness.level == 0.7)
    #expect(brightness.keyboardLevel == 0.4)
}

@MainActor
@Test func clamshellDarkForceNeedsPreventDisplaySleep() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.7, keyboardLevel: 0.4)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: false))
    controller.reconcile(display: .lidShutWithExternal)
    #expect(brightness.level == 0.7)
    #expect(brightness.keyboardLevel == 0.4)
    #expect(brightness.setLevels.isEmpty)
    #expect(brightness.setKeyboardLevels.isEmpty)
}

@MainActor
@Test func clamshellDarkForceRestoresOnStop() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.6, keyboardLevel: 0.3)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    // Open-lid sample first: restore targets come from last open, not a
    // post-close zero (GitHub #13).
    controller.reconcile(display: .usable)
    controller.reconcile(display: .lidShutWithExternal)
    #expect(brightness.level == 0)
    #expect(brightness.keyboardLevel == 0)

    controller.stop()
    #expect(brightness.level == 0.6)
    #expect(brightness.keyboardLevel == 0.3)
}

@MainActor
@Test func clamshellKeyboardRestoreUsesLastOpenLevelNotPostCloseZero() {
    // Hardware (#13): macOS zeros the keyboard on lid close before our first
    // clamshell tick. Capturing that live 0 and restoring it left keys dark.
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.7, keyboardLevel: 0.5)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    controller.reconcile(display: .usable)
    #expect(brightness.keyboardLevel == 0.5)

    // macOS has already darkened the keys by the time we see clamshell.
    brightness.keyboardLevel = 0
    controller.reconcile(display: .lidShutWithExternal)
    #expect(brightness.keyboardLevel == 0)

    controller.reconcile(display: .usable)
    #expect(brightness.keyboardLevel == 0.5)
    #expect(brightness.level == 0.7)
}

@MainActor
@Test func clamshellSkipsKeyboardForceWhenNeverSampledOpenAndAlreadyDark() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.7, keyboardLevel: 0)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    controller.reconcile(display: .lidShutWithExternal)
    #expect(brightness.setKeyboardLevels.isEmpty)
    #expect(brightness.keyboardLevel == 0)

    // Opening must not write a spurious 0 over macOS's own restore.
    brightness.keyboardLevel = 0.4 // macOS restored
    controller.reconcile(display: .usable)
    #expect(brightness.setKeyboardLevels.isEmpty)
    #expect(brightness.keyboardLevel == 0.4)
}

@MainActor
@Test func clamshellPanelForceUsesLastOpenWhenLivePanelDisappears() {
    // Hardware (#13): both display lists drop the built-in under a shut lid,
    // so currentBrightness is nil. Still force/restore from the open sample.
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.65, keyboardLevel: 0.3)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    controller.reconcile(display: .usable)

    brightness.supported = false
    controller.reconcile(display: .lidShutWithExternal)
    #expect(brightness.setLevels.last == 0)
    #expect(brightness.keyboardLevel == 0)

    brightness.supported = true
    controller.reconcile(display: .usable)
    #expect(brightness.level == 0.65)
    #expect(brightness.keyboardLevel == 0.3)
}

@MainActor
@Test func leavingClamshellWhileIdleAppliesDimFloor() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.7)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 60, dimFloor: 0.05))

    controller.reconcile(systemIdleSeconds: 10, display: .usable)
    controller.reconcile(systemIdleSeconds: 120, display: .lidShutWithExternal)
    #expect(brightness.level == 0)

    controller.reconcile(systemIdleSeconds: 130, display: .usable)
    #expect(brightness.level == 0.05)

    controller.reconcile(systemIdleSeconds: 1, display: .usable)
    #expect(brightness.level == 0.7)
}

@MainActor
@Test func idleDimDoesNotPoisonClamshellPanelRestoreAfterActivity() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.8)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 60, dimFloor: 0))

    controller.reconcile(systemIdleSeconds: 10, display: .usable)
    #expect(brightness.level == 0.8)

    controller.reconcile(systemIdleSeconds: 120, display: .usable)
    #expect(brightness.level == 0)

    controller.reconcile(systemIdleSeconds: 1, display: .usable)
    #expect(brightness.level == 0.8)

    brightness.supported = false
    controller.reconcile(systemIdleSeconds: 5, display: .lidShutWithExternal)
    #expect(brightness.setLevels.last == 0)

    brightness.supported = true
    controller.reconcile(systemIdleSeconds: 2, display: .usable)
    #expect(brightness.level == 0.8)
}

@MainActor
@Test func stopWhileIdleDimmedStillSeedsNextClamshellRestore() {
    let clock = Clock()
    let brightness = FakeBrightness(level: 0.75)
    let controller = SessionController(assertions: FakeAssertions(), brightness: brightness, now: { clock.now })
    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 60, dimFloor: 0))

    controller.reconcile(systemIdleSeconds: 10, display: .usable)
    controller.reconcile(systemIdleSeconds: 120, display: .usable)
    #expect(brightness.level == 0)

    controller.stop()
    #expect(brightness.level == 0.75)

    controller.start(options: SleepPreventionOptions(
        preventSystemSleep: true, preventDisplaySleep: true, dimDisplayAfter: 60, dimFloor: 0))
    brightness.supported = false
    controller.reconcile(systemIdleSeconds: 5, display: .lidShutWithExternal)
    #expect(brightness.setLevels.last == 0)

    brightness.supported = true
    controller.reconcile(systemIdleSeconds: 1, display: .usable)
    #expect(brightness.level == 0.75)
}

@MainActor
@Test func stopClearsDisplayLatchSoNextStartFailsOpen() {
    let (controller, fake, _) = makeController()
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system])

    controller.stop()
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))
    #expect(fake.held == [.system, .display])
}

@MainActor
@Test func anUnreadableLidNeverDropsTheDisplayAssertion() {
    let (controller, fake, _) = makeController()
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))

    controller.reconcile(display: .unknown)
    #expect(fake.held == [.system, .display])
}

@MainActor
@Test func aNilLidReadKeepsTheLastKnownDisplayStandDown() {
    let (controller, fake, _) = makeController()
    controller.start(options: SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true))

    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system])

    // AppleClamshellState flutters to nil while the lid is still shut: hold
    // the latched stand-down instead of re-creating the display assertion.
    controller.reconcile(display: .unknown)
    #expect(fake.held == [.system])

    controller.reconcile()
    #expect(fake.held == [.system])

    controller.reconcile(display: .usable)
    #expect(fake.held == [.system, .display])

    controller.reconcile(display: .unknown)
    #expect(fake.held == [.system, .display])
}

@MainActor
@Test func assertionCreateFailureSurfacesOnTheController() {
    let fake = FakeAssertions()
    fake.refuse = [.system]
    let clock = Clock()
    let controller = SessionController(assertions: fake, now: { clock.now })
    controller.start()
    #expect(controller.isActive)
    #expect(fake.held.isEmpty)
    #expect(controller.lastAssertionError != nil)

    fake.refuse = []
    controller.reconcile()
    #expect(fake.held == [.system])
    #expect(controller.lastAssertionError == nil)
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
    #expect(controller.isActive)

    clock.advance(2)
    controller.reconcile()
    #expect(controller.isActive == false)
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
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)

    gate.satisfied = true
    controller.reconcile()
    #expect(controller.isActive)
    #expect(fake.held == [.system])

    gate.satisfied = false
    controller.reconcile()
    #expect(controller.isActive == false)
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
    controller.reconcile()
    #expect(controller.startedAt == started)
    #expect(abs(controller.elapsed - 30) < 0.001)
}

@MainActor
@Test func gatedSessionHasNoRemainingEvenWithLeftoverTimedMode() {
    let (controller, _, clock) = makeController()
    controller.start(mode: .timed(duration: 3600))
    clock.advance(10)
    #expect(controller.remaining != nil)

    controller.triggerGate = StubGate(true)
    controller.reconcile()
    #expect(controller.isActive)
    #expect(controller.remaining == nil)
}

@MainActor
@Test func gatedSessionIgnoresTimedExpiry() {
    let (controller, fake, clock) = makeController()
    let gate = StubGate(true)
    controller.triggerGate = gate
    controller.start(mode: .timed(duration: 60))

    clock.advance(120)
    controller.reconcile()
    #expect(controller.isActive)
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

    controller.reconcile(systemIdleSeconds: 100)
    #expect(fake.held == [.system, .display])

    controller.reconcile(systemIdleSeconds: 301)
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

    controller.reconcile(battery: .discharging(10))
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)

    controller.reconcile(battery: .discharging(50))
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func batteryPauseHasResumeHysteresis() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.triggerGate = StubGate(true)

    controller.reconcile(battery: .discharging(19))
    #expect(controller.isActive == false)
    #expect(controller.pausedByBattery)

    controller.reconcile(battery: .discharging(20))
    #expect(controller.isActive == false)
    controller.reconcile(battery: .discharging(22))
    #expect(controller.isActive == false)

    controller.reconcile(battery: .discharging(23))
    #expect(controller.isActive)
    #expect(controller.pausedByBattery == false)
    #expect(fake.held == [.system])
}

@MainActor
@Test func manualSessionResumesWhenPluggedInAfterBatteryPause() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.start()
    #expect(controller.isActive)

    controller.reconcile(battery: .discharging(15))
    #expect(controller.isActive == false)
    #expect(controller.pausedByBattery)
    #expect(fake.held.isEmpty)

    controller.reconcile(battery: .onAC)
    #expect(controller.pausedByBattery == false)
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func batteryPauseResumeKeepsOptionsChangedDuringThePause() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.start()
    controller.reconcile(battery: .discharging(15))
    #expect(controller.isActive == false)

    controller.options.preventDisplaySleep = true
    controller.options.activityOnlyWhileBrewing = false
    controller.reconcile(battery: .onAC)
    #expect(controller.isActive)
    #expect(controller.options.preventDisplaySleep)
    #expect(controller.options.activityOnlyWhileBrewing == false)
    #expect(fake.held == [.system, .display])
}

@MainActor
@Test func manualSessionResumesWhenBatteryRecoversAboveMargin() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.start()

    controller.reconcile(battery: .discharging(15))
    #expect(controller.isActive == false)

    controller.reconcile(battery: .discharging(22))
    #expect(controller.isActive == false)

    controller.reconcile(battery: .discharging(23))
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func manualStopDuringBatteryPauseCancelsAutoResume() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.start()

    controller.reconcile(battery: .discharging(15))
    #expect(controller.pausedByBattery)

    controller.stop()
    controller.reconcile(battery: .onAC)
    #expect(controller.pausedByBattery == false)
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func overdueTimedSessionEndsSameTickOnResume() {
    let (controller, fake, clock) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.start(mode: .timed(duration: 60))

    controller.reconcile(battery: .discharging(15))
    #expect(controller.isActive == false)

    clock.advance(120)
    controller.reconcile(battery: .onAC)
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func enablingTriggersDiscardsRememberedManualSession() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.start()

    controller.reconcile(battery: .discharging(15))
    #expect(controller.pausedByBattery)

    controller.triggerGate = StubGate(false)
    controller.reconcile(battery: .onAC)
    #expect(controller.isActive == false)

    controller.triggerGate = nil
    controller.reconcile(battery: .onAC)
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func batteryThresholdIgnoredWhenNoReadingSupplied() {
    let (controller, fake, _) = makeController()
    controller.pauseBelowBatteryPercent = 20
    controller.start()

    controller.reconcile()
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

    controller.start()
    #expect(controller.isActive == false)
    #expect(controller.pausedByBattery)
    #expect(fake.held.isEmpty)

    controller.reconcile()
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

    controller.start()
    #expect(controller.batteryRefusedStarts == 1)
    controller.start()
    #expect(controller.batteryRefusedStarts == 2)

    controller.reconcile(battery: .onAC)
    controller.start()
    #expect(controller.isActive)
    #expect(controller.batteryRefusedStarts == 2)
}


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

    controller.reconcile(thermal: .clear)
    #expect(controller.pausedByThermal == false)
    #expect(controller.isActive)
    #expect(fake.held == [.system])
}

@MainActor
@Test func hotReadingBlocksTriggerGateReactivation() {
    let (controller, fake, _) = makeController()
    controller.pauseWhenHot = true
    controller.triggerGate = StubGate(true)
    controller.reconcile(thermal: .hot)
    #expect(controller.pausedByThermal)
    #expect(controller.isActive == false)

    controller.reconcile(thermal: .hot)
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)

    controller.reconcile(thermal: .clear)
    #expect(controller.isActive)
}

@MainActor
@Test func unknownThermalReadingHoldsTheLatchAcrossStarts() {
    let (controller, fake, _) = makeController()
    controller.pauseWhenHot = true
    controller.reconcile(thermal: .hot)
    #expect(controller.pausedByThermal)

    controller.start()
    #expect(controller.isActive == false)
    #expect(controller.pausedByThermal)
    #expect(fake.held.isEmpty)

    controller.reconcile()
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
    controller.reconcile()
    #expect(controller.pausedByThermal == false)
    controller.start()
    #expect(controller.isActive)
}

@MainActor
@Test func batteryAndThermalPausesHandOverCleanly() {
    let (controller, _, _) = makeController()
    controller.pauseWhenHot = true
    controller.pauseBelowBatteryPercent = 20

    controller.reconcile(battery: .discharging(15), thermal: .hot)
    #expect(controller.pausedByBattery)
    #expect(controller.pausedByThermal == false)

    controller.reconcile(battery: .onAC, thermal: .hot)
    #expect(controller.pausedByBattery == false)
    #expect(controller.pausedByThermal)
    controller.start()
    #expect(controller.isActive == false)

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

    controller.reconcile(battery: .onAC)
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

    controller.reconcile(battery: .discharging(10))
    controller.reconcile()
    #expect(gate.ticks == before + 2)
}

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
    controller.notifyOnEnd = true
    controller.start()

    controller.reconcile(battery: .discharging(15))
    #expect(controller.pausedByBattery)
    #expect(reminder.notices.count == 1)
    #expect(reminder.notices.first?.title == "Paused on low battery")
    #expect(reminder.notices.first?.body.contains("15%") == true)
    #expect(reminder.notices.first?.body.contains("plug in") == true)

    controller.reconcile(battery: .discharging(14))
    #expect(reminder.notices.count == 1)
}

@MainActor
@Test func batteryPauseNotifiesEvenWithEndNotificationsOff() {
    let reminder = FakeReminder()
    let clock = Clock()
    let controller = SessionController(assertions: FakeAssertions(), reminder: reminder, now: { clock.now })
    controller.pauseBelowBatteryPercent = 20
    controller.start()

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

    controller.reconcile(battery: .discharging(15))
    #expect(controller.pausedByBattery)
    #expect(reminder.notices.isEmpty)
}


@MainActor
@Test func stopInConvertsIndefiniteSessionKeepingStartedAt() {
    let (controller, fake, clock) = makeController()
    controller.start()
    let started = controller.startedAt
    clock.advance(10 * 60)

    controller.stopIn(15 * 60)
    #expect(controller.startedAt == started)
    #expect(abs((controller.remaining ?? -1) - 15 * 60) < 0.001)

    clock.advance(15 * 60 - 1)
    controller.reconcile()
    #expect(controller.isActive)

    clock.advance(2)
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(fake.held.isEmpty)
}

@MainActor
@Test func stopInShortensAndExtendsATimedSession() {
    let (controller, _, clock) = makeController()
    controller.start(mode: .timed(duration: 60 * 60))
    clock.advance(60)

    controller.stopIn(5 * 60)
    #expect(abs((controller.remaining ?? -1) - 5 * 60) < 0.001)

    controller.stopIn(30 * 60)
    #expect(abs((controller.remaining ?? -1) - 30 * 60) < 0.001)
}

@MainActor
@Test func stopInIsIgnoredWhileIdleGatedOrNonPositive() {
    let (controller, _, _) = makeController()
    controller.stopIn(15 * 60)
    #expect(controller.isActive == false)
    #expect(controller.mode == .indefinite)

    controller.start()
    controller.stopIn(0)
    #expect(controller.remaining == nil)

    controller.triggerGate = StubGate(true)
    controller.reconcile()
    controller.stopIn(15 * 60)
    #expect(controller.mode == .indefinite)
}


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
    #expect(controller.remaining == nil)
}

@MainActor
@Test func leaseSessionNeverHoldsTheDisplayAssertion() {
    let (controller, fake, _) = makeController()
    controller.closedLidDisplayPolicy = .zeroBrightness
    controller.options = SleepPreventionOptions(preventSystemSleep: true, preventDisplaySleep: true)
    let provider = FakeLeaseProvider()
    controller.leases = provider

    provider.summaries = [leaseSummary()]
    controller.reconcile(display: .lidShutNoExternal)
    #expect(fake.held == [.system])

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
    #expect(endActor.performed.isEmpty)

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

    #expect(controller.isActive)
    #expect(controller.log.events.last?.kind == .leaseAcquired)
    #expect(controller.remaining == nil)
    #expect(fake.held == [.system])

    clock.advance(SessionController.endActionDebounce + 1)
    controller.reconcile()
    #expect(endActor.performed.isEmpty)

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

    provider.summaries = [leaseSummary()]
    gate.satisfied = false
    controller.reconcile()
    #expect(controller.isActive)

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

    clock.advance(1)
    controller.reconcile(battery: .discharging(10))
    #expect(controller.isActive == false)

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
    #expect(controller.isActive)
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

    clock.advance(1)
    controller.reconcile(thermal: .hot)
    #expect(controller.isActive == false)
    controller.reconcile()
    #expect(controller.isActive == false)

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

    controller.triggerGate = nil
    controller.handOffToLeases()
    clock.advance(1)
    controller.reconcile()
    #expect(controller.isActive)
    #expect(controller.isLeaseHeld)
    #expect(controller.startedAt == begun)
    #expect(controller.log.events.count == logged)
    #expect(fake.held == [.system])

    clock.advance(1)
    provider.summaries = []
    controller.reconcile()
    #expect(controller.isActive == false)
    #expect(controller.log.events.last?.kind == .leaseReleased)
}
