import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Fakes

private final class FakeControllers: ControllerMonitoring {
    var connectedCount = 0
}

private final class CountingActivity: ActivitySimulating {
    private(set) var pokeCount = 0
    func poke() { pokeCount += 1 }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 5_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

// MARK: - Controller trigger

@Test func controllerTriggerFollowsConnectedCount() {
    let controllers = FakeControllers()
    let trigger = ControllerTrigger(monitor: controllers)
    #expect(trigger.isSatisfied() == false)
    controllers.connectedCount = 1
    #expect(trigger.isSatisfied())
    controllers.connectedCount = 0
    #expect(trigger.isSatisfied() == false)
}

@Test func controllerRuleRoundTripsAndLabels() throws {
    let rule = TriggerRule.controllerConnected
    let data = try JSONEncoder().encode([rule])
    let decoded = try JSONDecoder().decode([TriggerRule].self, from: data)
    #expect(decoded == [rule])
    #expect(rule.requiredPermission == nil)
    #expect(!rule.label.isEmpty)
}

// MARK: - Controller activity poke

@MainActor
@Test func pokerPokesOnlyWhileEverythingIsTrue() {
    let clock = Clock()
    let activity = CountingActivity()
    let poker = ControllerActivityPoker(activity: activity, now: { clock.now })
    poker.enabled = true

    // Any missing condition: silent.
    poker.tick(gamingActive: false, controllerConnected: true, sessionActive: true)
    poker.tick(gamingActive: true, controllerConnected: false, sessionActive: true)
    poker.tick(gamingActive: true, controllerConnected: true, sessionActive: false)
    #expect(activity.pokeCount == 0)

    poker.tick(gamingActive: true, controllerConnected: true, sessionActive: true)
    #expect(activity.pokeCount == 1)
}

@MainActor
@Test func pokerThrottlesToTheInterval() {
    let clock = Clock()
    let activity = CountingActivity()
    let poker = ControllerActivityPoker(activity: activity, now: { clock.now })
    poker.enabled = true

    poker.tick(gamingActive: true, controllerConnected: true, sessionActive: true)
    clock.advance(5)
    poker.tick(gamingActive: true, controllerConnected: true, sessionActive: true)
    #expect(activity.pokeCount == 1) // within the interval

    clock.advance(ControllerActivityPoker.pokeInterval)
    poker.tick(gamingActive: true, controllerConnected: true, sessionActive: true)
    #expect(activity.pokeCount == 2)

    // A gap in play resets the cadence: the next qualifying tick pokes
    // immediately.
    poker.tick(gamingActive: false, controllerConnected: true, sessionActive: true)
    clock.advance(1)
    poker.tick(gamingActive: true, controllerConnected: true, sessionActive: true)
    #expect(activity.pokeCount == 3)
}

@MainActor
@Test func pokerStaysSilentWhileDisabled() {
    let clock = Clock()
    let activity = CountingActivity()
    let poker = ControllerActivityPoker(activity: activity, now: { clock.now })

    poker.tick(gamingActive: true, controllerConnected: true, sessionActive: true)
    #expect(activity.pokeCount == 0)
}

// MARK: - Game priority controller

@MainActor
private final class HoldRecorder {
    private(set) var calls: [(holding: Bool, pid: Int)] = []
    func record(_ holding: Bool, _ pid: Int) { calls.append((holding, pid)) }
}

@MainActor
@Test func priorityBoostEngagesOnTheRawGameAndReleasesAtBoutEnd() {
    let recorder = HoldRecorder()
    let controller = GamePriorityController { recorder.record($0, $1) }
    controller.autoWithGaming = true

    controller.autoTick(gameFrontmost: true, gamingActive: true, frontmostPID: 4242)
    #expect(controller.boostedPID == 4242)
    #expect(recorder.calls.map(\.holding) == [true])

    // Alt-tabbed: the graced bout continues, no flapping.
    controller.autoTick(gameFrontmost: false, gamingActive: true, frontmostPID: 999)
    #expect(controller.boostedPID == 4242)
    #expect(recorder.calls.count == 1)

    // Bout over: released.
    controller.autoTick(gameFrontmost: false, gamingActive: false, frontmostPID: nil)
    #expect(controller.boostedPID == nil)
    #expect(recorder.calls.last?.holding == false)
    #expect(recorder.calls.last?.pid == 4242)
}

@MainActor
@Test func priorityBoostKeepsTheFirstGameOfABout() {
    let recorder = HoldRecorder()
    let controller = GamePriorityController { recorder.record($0, $1) }
    controller.autoWithGaming = true

    controller.autoTick(gameFrontmost: true, gamingActive: true, frontmostPID: 100)
    controller.autoTick(gameFrontmost: true, gamingActive: true, frontmostPID: 200)
    #expect(controller.boostedPID == 100)
    #expect(recorder.calls.count == 1)
}

@MainActor
@Test func priorityBoostReleasesWhenToggledOffMidBout() {
    let recorder = HoldRecorder()
    let controller = GamePriorityController { recorder.record($0, $1) }
    controller.autoWithGaming = true
    controller.autoTick(gameFrontmost: true, gamingActive: true, frontmostPID: 100)

    controller.autoWithGaming = false
    #expect(controller.boostedPID == nil)
    #expect(recorder.calls.last?.holding == false)

    // Off: the pulse never engages.
    controller.autoTick(gameFrontmost: true, gamingActive: true, frontmostPID: 100)
    #expect(recorder.calls.count == 2)
}

@MainActor
@Test func priorityBoostIgnoresMissingOrHostilePids() {
    let recorder = HoldRecorder()
    let controller = GamePriorityController { recorder.record($0, $1) }
    controller.autoWithGaming = true

    controller.autoTick(gameFrontmost: true, gamingActive: true, frontmostPID: nil)
    controller.autoTick(gameFrontmost: true, gamingActive: true, frontmostPID: 0)
    #expect(controller.boostedPID == nil)
    #expect(recorder.calls.isEmpty)
}

// MARK: - Steam hardware HID dedup

@Test func steamHardwareCollapsesInterfacesAndIgnoresVirtuals() {
    // The real puck: several USB interfaces at one location plus lizard-mode
    // virtual keyboard/mouse children.
    #expect(SteamControllerHID.distinctHardwareCount(devices: [
        ("USB", 34_734_080), ("USB", 34_734_080), ("USB", 34_734_080),
        ("Virtual", 0), ("Virtual", 0),
    ]) == 1)
    // Two pucks on two ports.
    #expect(SteamControllerHID.distinctHardwareCount(devices: [
        ("USB", 1), ("USB", 1), ("USB", 2),
    ]) == 2)
    // Stale virtuals with no hardware left: nothing.
    #expect(SteamControllerHID.distinctHardwareCount(devices: [
        ("Virtual", 0), ("Virtual", nil),
    ]) == 0)
    // A physical device with no usable location still counts once.
    #expect(SteamControllerHID.distinctHardwareCount(devices: [
        ("Bluetooth", nil), ("Bluetooth", 0),
    ]) == 1)
    #expect(SteamControllerHID.distinctHardwareCount(devices: []) == 0)
}

@Test func gamingPresetsIncludeTheControllerRule() {
    let gaming = Preset.builtIns.first { $0.id == "gaming" }
    #expect(gaming?.ruleSet.rules.contains(.controllerConnected) == true)
    #expect(gaming?.ruleSet.rules.contains(.gaming) == true)
    let cloud = Preset.builtIns.first { $0.id == "cloud-gaming" }
    #expect(cloud?.ruleSet.rules.contains(.controllerConnected) == true)
}
