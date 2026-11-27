import Testing
import Foundation
@testable import KeepressoCore


@Test func displayOffSleepsWhenLidShutWithNoExternalDisplay() {
    #expect(DisplayPolicyDecision.decide(
        policy: .displayOff, lidClosed: true, hasExternalDisplay: false
    ) == .sleepPanel)
}

@Test func displayOffHoldsWhenLidOpenExternalOrUnreadable() {
    #expect(DisplayPolicyDecision.decide(
        policy: .displayOff, lidClosed: false, hasExternalDisplay: false
    ) == .hold)
    #expect(DisplayPolicyDecision.decide(
        policy: .displayOff, lidClosed: true, hasExternalDisplay: true
    ) == .hold)
    #expect(DisplayPolicyDecision.decide(
        policy: .displayOff, lidClosed: nil, hasExternalDisplay: false
    ) == .hold)
}

@Test func zeroBrightnessDimsWhenLidShutWithNoExternalDisplay() {
    #expect(DisplayPolicyDecision.decide(
        policy: .zeroBrightness, lidClosed: true, hasExternalDisplay: false
    ) == .holdDim)
    #expect(DisplayPolicyDecision.decide(
        policy: .zeroBrightness, lidClosed: false, hasExternalDisplay: false
    ) == .hold)
    #expect(DisplayPolicyDecision.decide(
        policy: .zeroBrightness, lidClosed: true, hasExternalDisplay: true
    ) == .hold)
    #expect(DisplayPolicyDecision.decide(
        policy: .zeroBrightness, lidClosed: nil, hasExternalDisplay: false
    ) == .hold)
}

@Test func leaveAloneAlwaysHolds() {
    let lids: [Bool?] = [true, false, nil]
    for lid in lids {
        for external in [true, false] {
            #expect(DisplayPolicyDecision.decide(
                policy: .leaveAlone, lidClosed: lid, hasExternalDisplay: external
            ) == .hold)
        }
    }
}


private final class PolicyFakeSleepControl: SleepSettingControlling, @unchecked Sendable {
    var disabled = true
    func isSleepDisabled() -> Bool? { disabled }
    func setSleepDisabled(_ disabled: Bool) -> SleepSettingResult { .applied }
}

private final class PolicyFakeLid: LidStateReading, @unchecked Sendable {
    var closed: Bool?
    init(closed: Bool? = true) { self.closed = closed }
    func isClosed() -> Bool? { closed }
}

private final class PolicyFakeMonitor: DisplayMonitoring, @unchecked Sendable {
    var external = false
    var current: DisplaySnapshot {
        DisplaySnapshot(externalDisplayCount: external ? 1 : 0, totalDisplayCount: external ? 2 : 1)
    }
}

private final class PolicyFakeSleeper: DisplaySleepCommanding, @unchecked Sendable {
    private(set) var sleepNowCallCount = 0
    func sleepNow() { sleepNowCallCount += 1 }
}

private final class PolicyFakePower: DisplayPowerReading, @unchecked Sendable {
    var asleep: Bool? = true
    func builtInIsAsleep() -> Bool? { asleep }
}

private final class PolicyFakeBrightness: BrightnessControlling, @unchecked Sendable {
    var supported = true
    var current: Double? = 0.8
    private(set) var setCalls: [Double] = []
    var isSupported: Bool { supported }
    func currentBrightness() -> Double? { current }
    func setBrightness(_ level: Double) { setCalls.append(level); current = level }
    var isKeyboardSupported: Bool { false }
    func currentKeyboardBrightness() -> Double? { nil }
    func setKeyboardBrightness(_ level: Double) {}
}

@MainActor
private func makeHarness(
    lidClosed: Bool? = true,
    brightnessSupported: Bool = true,
    brightness: Double? = 0.8
) -> (controller: ClosedDisplayController, lid: PolicyFakeLid, monitor: PolicyFakeMonitor, sleeper: PolicyFakeSleeper, panel: PolicyFakeBrightness, clock: FakeClock) {
    let lid = PolicyFakeLid(closed: lidClosed)
    let monitor = PolicyFakeMonitor()
    let sleeper = PolicyFakeSleeper()
    let panel = PolicyFakeBrightness()
    panel.supported = brightnessSupported
    panel.current = brightness
    let clock = FakeClock()
    let controller = ClosedDisplayController(
        control: PolicyFakeSleepControl(),
        lid: lid,
        externalDisplay: monitor,
        displaySleeper: sleeper,
        displayPower: PolicyFakePower(),
        brightness: panel,
        now: { clock.now }
    )
    return (controller, lid, monitor, sleeper, panel, clock)
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 0)
    var now: Date { lock.withLock { _now } }
    func advance(_ interval: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(interval) } }
}

@MainActor
@Test func leaveAloneTouchesNothingAndStaysSilent() async {
    let h = makeHarness()
    await h.controller.refresh()
    h.controller.policy = .leaveAlone
    h.controller.tick()
    h.controller.tick()
    #expect(h.sleeper.sleepNowCallCount == 0)
    #expect(h.panel.setCalls.isEmpty)
    #expect(h.controller.lastDecisionReason == nil)
}

@MainActor
@Test func zeroBrightnessZeroesOnShutAndRestoresOnOpen() async {
    let h = makeHarness()
    await h.controller.refresh()
    h.controller.policy = .zeroBrightness
    h.controller.tick()
    #expect(h.panel.setCalls == [0])
    h.controller.tick()
    #expect(h.panel.setCalls == [0])
    #expect(h.controller.lastDecisionReason == nil)

    h.lid.closed = false
    h.controller.tick()
    #expect(h.panel.setCalls == [0, 0.8])
}

@MainActor
@Test func zeroBrightnessReZeroesARaisedLevelPastTheGrace() async {
    let h = makeHarness()
    await h.controller.refresh()
    h.controller.policy = .zeroBrightness
    h.controller.tick()
    #expect(h.panel.setCalls == [0])

    h.panel.current = 0.5
    h.controller.tick()
    #expect(h.panel.setCalls == [0])
    h.clock.advance(ClosedDisplayController.resleepGrace)
    h.controller.tick()
    #expect(h.panel.setCalls == [0, 0])
}

@MainActor
@Test func zeroBrightnessWithoutSupportFallsBackToSleepAndSaysSo() async {
    let h = makeHarness(brightnessSupported: false)
    await h.controller.refresh()
    h.controller.policy = .zeroBrightness
    h.controller.tick()
    #expect(h.sleeper.sleepNowCallCount == 1)
    #expect(h.controller.lastDecisionReason != nil)
}

@MainActor
@Test func restoreSkipsALevelSomebodyElseChanged() async {
    let h = makeHarness()
    await h.controller.refresh()
    h.controller.policy = .zeroBrightness
    h.controller.tick()
    #expect(h.panel.setCalls == [0])

    h.panel.current = 0.5
    h.lid.closed = false
    h.controller.tick()
    #expect(h.panel.setCalls == [0])
}

@MainActor
@Test func policySwitchHandsBackTheSavedLevel() async {
    let h = makeHarness()
    await h.controller.refresh()
    h.controller.policy = .zeroBrightness
    h.controller.tick()
    #expect(h.panel.setCalls == [0])

    h.controller.policy = .displayOff
    h.lid.closed = false
    h.controller.tick()
    #expect(h.panel.setCalls == [0, 0.8])
}

@MainActor
@Test func modeOffHandsBackTheSavedLevel() async {
    let control = PolicyFakeSleepControl()
    let lid = PolicyFakeLid(closed: true)
    let panel = PolicyFakeBrightness()
    let controller = ClosedDisplayController(
        control: control,
        lid: lid,
        externalDisplay: PolicyFakeMonitor(),
        displaySleeper: PolicyFakeSleeper(),
        displayPower: PolicyFakePower(),
        brightness: panel
    )
    await controller.refresh()
    controller.policy = .zeroBrightness
    controller.tick()
    #expect(panel.setCalls == [0])

    control.disabled = false
    await controller.refresh(force: true)
    controller.tick()
    #expect(panel.setCalls == [0, 0.8])
}

@MainActor
@Test func restoreUsesTheOpenLidSampleNeverThePostCloseZero() async {
    let h = makeHarness(lidClosed: false, brightness: 0.7)
    await h.controller.refresh()
    h.controller.policy = .zeroBrightness
    h.controller.tick()
    h.controller.tick()
    #expect(h.panel.setCalls.isEmpty)

    h.lid.closed = true
    h.panel.current = 0 // macOS darkened the panel on close (see GitHub #13)
    h.controller.tick()
    #expect(h.panel.setCalls == [0])
    h.lid.closed = false
    h.controller.tick()
    #expect(h.panel.setCalls == [0, 0.7])
}

@MainActor
@Test func noRestoreTargetMeansNoZeroing() async {
    let h = makeHarness(brightness: nil)
    await h.controller.refresh()
    h.controller.policy = .zeroBrightness
    h.controller.tick()
    h.controller.tick()
    #expect(h.panel.setCalls.isEmpty)
}

@MainActor
@Test func restoreRetriesAnUnreadablePanel() async {
    let h = makeHarness()
    await h.controller.refresh()
    h.controller.policy = .zeroBrightness
    h.controller.tick()
    #expect(h.panel.setCalls == [0])

    h.lid.closed = false
    h.panel.current = nil
    h.controller.tick()
    #expect(h.panel.setCalls == [0])
    h.panel.current = 0
    h.controller.tick()
    #expect(h.panel.setCalls == [0, 0.8])
}

@Test func policySurvivesASettingsRoundTrip() throws {
    var settings = KeepressoSettings()
    #expect(settings.closedLidDisplayPolicy == .displayOff)
    settings.closedLidDisplayPolicy = .zeroBrightness
    let decoded = try JSONDecoder().decode(
        KeepressoSettings.self, from: JSONEncoder().encode(settings)
    )
    #expect(decoded == settings)
}

@Test func renamedPolicyValueFallsBackWithoutResettingSettings() throws {
    let data = Data("""
        {"closedLidDisplayPolicy": "keepDark", "quickStopDurations": [900]}
        """.utf8)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.closedLidDisplayPolicy == .displayOff)
    #expect(decoded.quickStopDurations == [900])
}
