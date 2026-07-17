import Testing
import Foundation
@testable import KeepressoCore

// The guard is exercised through its pure step function with scripted 1 Hz
// samples, the same style as CPULoadTriggerTests. A tiny driver keeps the
// scripts readable.
private func run(
    _ samples: [ThermalSample?],
    config: ThermalSafetyConfig,
    from state: ThermalGuardState = ThermalGuardState()
) -> (state: ThermalGuardState, effects: [ThermalEffect]) {
    var state = state
    var all: [ThermalEffect] = []
    for sample in samples {
        let (next, effects) = ThermalGuard.step(state, sample: sample, config: config)
        state = next
        all.append(contentsOf: effects)
    }
    return (state, all)
}

private let sensorConfig = ThermalSafetyConfig(
    mode: .sensors(ids: ["Tp09"], celsius: 95),
    sustainSeconds: 5,
    fanBoostPercent: 80,
    stopBrewing: true
)

private let pressureConfig = ThermalSafetyConfig(
    mode: .pressure(atOrAbove: .serious),
    sustainSeconds: 5,
    fanBoostPercent: nil,
    stopBrewing: true
)

@Test func dwellFiresExactlyAtTheSustainWindow() {
    let hot = ThermalSample.celsius(max: 97)
    // Four hot seconds: nothing yet.
    let early = run(Array(repeating: hot, count: 4), config: sensorConfig)
    #expect(early.effects.isEmpty)
    #expect(early.state.stage == .clear)
    // The fifth crosses the dwell: fans boost.
    let fired = run([hot], config: sensorConfig, from: early.state)
    #expect(fired.effects == [.boostFans(percent: 80)])
    #expect(fired.state.stage == .fansBoosted)
}

@Test func secondDwellEscalatesToPauseWithFansStillBoosted() {
    let hot = ThermalSample.celsius(max: 97)
    let (state, effects) = run(Array(repeating: hot, count: 10), config: sensorConfig)
    #expect(effects == [.boostFans(percent: 80), .pauseBrewing])
    #expect(state.stage == .stopped) // no .restoreFans emitted: fans keep cooling
}

@Test func fansOffGoesStraightToPause() {
    var config = sensorConfig
    config.fanBoostPercent = nil
    let hot = ThermalSample.celsius(max: 97)
    let (state, effects) = run(Array(repeating: hot, count: 5), config: config)
    #expect(effects == [.pauseBrewing])
    #expect(state.stage == .stopped)
}

@Test func stopDisabledBoostsFansAndNeverPauses() {
    var config = sensorConfig
    config.stopBrewing = false
    let hot = ThermalSample.celsius(max: 97)
    let (state, effects) = run(Array(repeating: hot, count: 60), config: config)
    #expect(effects == [.boostFans(percent: 80)])
    #expect(state.stage == .fansBoosted)
}

@Test func nothingEnabledEmitsNoEffects() {
    var config = sensorConfig
    config.fanBoostPercent = nil
    config.stopBrewing = false
    let hot = ThermalSample.celsius(max: 97)
    let (state, effects) = run(Array(repeating: hot, count: 60), config: config)
    #expect(effects.isEmpty)
    #expect(state.stage == .clear)
}

@Test func hysteresisBandNeverResumes() {
    let hot = ThermalSample.celsius(max: 97)
    let hovering = ThermalSample.celsius(max: 92) // under 95, above 95 - 5 margin
    let paused = run(Array(repeating: hot, count: 10), config: sensorConfig)
    #expect(paused.state.stage == .stopped)
    // A long hover inside the dead-band releases nothing.
    let still = run(Array(repeating: hovering, count: 120), config: sensorConfig, from: paused.state)
    #expect(still.effects.isEmpty)
    #expect(still.state.stage == .stopped)
    // Clearly under (<= 90) sustained for the window releases everything.
    let cooled = run(
        Array(repeating: .celsius(max: 88), count: 5),
        config: sensorConfig, from: still.state
    )
    #expect(cooled.effects == [.restoreFans, .resumeBrewing])
    #expect(cooled.state.stage == .clear)
}

@Test func pressureLevelDropIsTheResumeMargin() {
    let serious = ThermalSample.pressure(.serious)
    let fair = ThermalSample.pressure(.fair)
    let paused = run(Array(repeating: serious, count: 5), config: pressureConfig)
    #expect(paused.state.stage == .stopped)
    // Bouncing serious/fair never accumulates the release dwell.
    let bouncing = run(
        [fair, serious, fair, fair, serious, fair, fair, fair, serious],
        config: pressureConfig, from: paused.state
    )
    #expect(bouncing.effects.isEmpty)
    #expect(bouncing.state.stage == .stopped)
    // Five straight fair seconds release.
    let recovered = run(Array(repeating: fair, count: 5), config: pressureConfig, from: bouncing.state)
    #expect(recovered.effects == [.restoreFans, .resumeBrewing])
}

@Test func nilSamplesFreezeCountersAndStage() {
    let hot = ThermalSample.celsius(max: 97)
    // Mid-dwell: three hot, then a gap, then two more hot; the gap must not
    // reset the counter (freeze, not zero), so the fifth hot sample fires.
    let midDwell = run([hot, hot, hot, nil, nil, hot, hot], config: sensorConfig)
    #expect(midDwell.effects == [.boostFans(percent: 80)])
    // While stopped: reads failing forever never release the pause.
    let paused = run(Array(repeating: hot, count: 10), config: sensorConfig)
    let blind = run(Array(repeating: nil, count: 300), config: sensorConfig, from: paused.state)
    #expect(blind.effects.isEmpty)
    #expect(blind.state.stage == .stopped)
}

@Test func aDipMidDwellResetsTheOverCounter() {
    let hot = ThermalSample.celsius(max: 97)
    let cool = ThermalSample.celsius(max: 80)
    let (state, effects) = run([hot, hot, hot, hot, cool, hot, hot, hot, hot], config: sensorConfig)
    #expect(effects.isEmpty) // the dip restarted the window
    #expect(state.stage == .clear)
    #expect(state.overSeconds == 4)
}

@Test func mismatchedSampleKindNeverFiresOrReleases() {
    // A pressure sample against a sensors config is a plumbing error; it must
    // count as neither over nor clearly-under.
    let (state, effects) = run(
        Array(repeating: .pressure(.critical), count: 60),
        config: sensorConfig
    )
    #expect(effects.isEmpty)
    #expect(state.stage == .clear)
}

@MainActor
@Test func controllerConfigChangeReleasesLatchedEffects() {
    final class ScriptedSensors: ThermalSensorReading {
        var value: Double? = 97
        func discoverSensors() -> [ThermalSensor] { [ThermalSensor(id: "Tp09", name: "Tp09")] }
        func readCelsius(ids: [String]) -> [String: Double]? {
            value.map { ["Tp09": $0] }
        }
    }
    let sensors = ScriptedSensors()
    let controller = ThermalGuardController(sensors: sensors)
    controller.config = ThermalSafetyConfig(
        mode: .sensors(ids: ["Tp09"], celsius: 95),
        sustainSeconds: 5,
        fanBoostPercent: 80
    )
    var effects: [ThermalEffect] = []
    for _ in 0..<10 { effects.append(contentsOf: controller.tick()) }
    #expect(effects == [.boostFans(percent: 80), .pauseBrewing])
    #expect(controller.readingForSession == .hot)

    // Turning the feature off mid-emergency must not strand boosted fans or a
    // paused session: the very next tick surfaces the releases, even while off.
    controller.config = nil
    #expect(controller.readingForSession == .unknown)
    let released = controller.tick()
    #expect(released == [.restoreFans, .resumeBrewing])
    #expect(controller.tick().isEmpty) // released exactly once
}

@Test func configDecodingClampsOutOfRangeValues() throws {
    let json = """
    {
      "mode": {"sensors": {"ids": ["Tp09"], "celsius": 20}},
      "sustainSeconds": 100000,
      "fanBoostPercent": 5,
      "stopBrewing": true,
      "liftSleepDisable": false
    }
    """
    let decoded = try JSONDecoder().decode(ThermalSafetyConfig.self, from: Data(json.utf8))
    guard case .sensors(_, let celsius) = decoded.mode else {
        Issue.record("expected sensors mode")
        return
    }
    #expect(celsius == ThermalSafetyConfig.celsiusRange.lowerBound)
    #expect(decoded.sustainSeconds == ThermalSafetyConfig.sustainRange.upperBound)
    #expect(decoded.fanBoostPercent == ThermalSafetyConfig.boostPercentRange.lowerBound)
}

@Test func configRoundTripsBothModes() throws {
    let sensors = ThermalSafetyConfig(
        mode: .sensors(ids: ["Tp09", "Tp0D"], celsius: 98),
        sustainSeconds: 60,
        fanBoostPercent: 70,
        stopBrewing: true,
        liftSleepDisable: true
    )
    let pressure = ThermalSafetyConfig(mode: .pressure(atOrAbove: .critical))
    for config in [sensors, pressure] {
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ThermalSafetyConfig.self, from: data) == config)
    }
}
