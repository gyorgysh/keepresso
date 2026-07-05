import Testing
import Foundation
@testable import KeepressoCore

private final class FakeCPUReader: CPULoadReading {
    var readings: [Double?]
    init(_ readings: [Double?]) { self.readings = readings }
    func currentLoad() -> Double? { readings.isEmpty ? nil : readings.removeFirst() }
}

/// Run the pure step over a sample sequence and return the final state.
private func run(_ samples: [Double?], threshold: Int, from state: CPULoadTrigger.SmoothingState = .init()) -> CPULoadTrigger.SmoothingState {
    samples.reduce(state) { CPULoadTrigger.step($0, sample: $1, thresholdPercent: threshold) }
}

@Test func sustainedHighLoadFires() {
    let state = run(Array(repeating: 0.9, count: 12), threshold: 50)
    #expect(state.isSatisfied)
}

@Test func aBriefSpikeDoesNotFire() {
    // Idle, one full-tilt second, idle again: the smoothed average never
    // reaches the threshold, so no session starts for a momentary blip.
    let state = run([0.05, 0.05, 1.0, 0.05, 0.05], threshold: 50)
    #expect(!state.isSatisfied)
}

@Test func hysteresisPreventsFlappingAtTheThreshold() {
    var state = run(Array(repeating: 0.9, count: 12), threshold: 50)
    #expect(state.isSatisfied)
    // Hovering just under the threshold keeps it on...
    state = run(Array(repeating: 0.47, count: 12), threshold: 50, from: state)
    #expect(state.isSatisfied)
    // ...but dropping clearly below turns it off.
    state = run(Array(repeating: 0.1, count: 30), threshold: 50, from: state)
    #expect(!state.isSatisfied)
}

@Test func nilReadingsHoldThePreviousVerdict() {
    var state = run(Array(repeating: 0.9, count: 12), threshold: 50)
    #expect(state.isSatisfied)
    state = run([nil, nil, nil], threshold: 50, from: state)
    #expect(state.isSatisfied) // a transient read failure doesn't drop the session
    #expect(!run([nil, nil], threshold: 50).isSatisfied) // but no data ever seen stays off
}

@MainActor
@Test func triggerAdvancesOnlyOnTick() {
    let reader = FakeCPUReader(Array(repeating: 0.9, count: 12))
    let trigger = CPULoadTrigger(thresholdPercent: 50, reader: reader)
    for _ in 0 ..< 12 { trigger.tick() }
    #expect(trigger.isSatisfied())
}

@MainActor
@Test func isSatisfiedIsAPureReadThatDoesNotStepTheAverage() {
    // The menu's live rule list calls isSatisfied() every render; it must not
    // advance the EMA (that would double the smoothing rate with the menu open,
    // the E6 double-step). Only tick() consumes a reading.
    let reader = FakeCPUReader(Array(repeating: 0.9, count: 5))
    let trigger = CPULoadTrigger(thresholdPercent: 50, reader: reader)
    for _ in 0 ..< 100 { _ = trigger.isSatisfied() } // no ticks: nothing read
    #expect(!trigger.isSatisfied())     // never armed
    #expect(reader.readings.count == 5) // reader untouched
}

@Test func lowThresholdCanStillRelease() {
    // With a flat `on - hysteresis` the off-band goes <= 0 for thresholds <= 5%,
    // latching the trigger on forever. The floored band must still release.
    var state = run(Array(repeating: 0.9, count: 12), threshold: 5)
    #expect(state.isSatisfied)
    state = run(Array(repeating: 0.0, count: 40), threshold: 5, from: state)
    #expect(!state.isSatisfied) // idle CPU releases even at a 5% threshold
}

@Test func hostReaderComputesTheDeltaBetweenSamples() {
    var current = Date(timeIntervalSinceReferenceDate: 0)
    var ticks = [HostCPULoadReader.Ticks(busy: 100, total: 1000),
                 HostCPULoadReader.Ticks(busy: 150, total: 1100)]
    let reader = HostCPULoadReader(ttl: 0.5, now: { current }, readTicks: { ticks.removeFirst() })

    #expect(reader.currentLoad() == nil) // first sample: nothing to diff against
    current = current.addingTimeInterval(1)
    #expect(reader.currentLoad() == 0.5) // 50 busy of 100 total new ticks
}

@Test func hostReaderCachesWithinTheTTL() {
    // Reads inside the TTL window share one tick sample: the menu's rule list
    // and the trigger engine both evaluate within the same second, and a
    // back-to-back delta would be over a meaninglessly tiny interval.
    var current = Date(timeIntervalSinceReferenceDate: 0)
    var tickReads = 0
    let reader = HostCPULoadReader(ttl: 0.5, now: { current }, readTicks: {
        tickReads += 1
        return HostCPULoadReader.Ticks(busy: UInt64(tickReads * 100), total: UInt64(tickReads * 1000))
    })

    _ = reader.currentLoad()
    _ = reader.currentLoad()
    #expect(tickReads == 1)
    current = current.addingTimeInterval(1)
    #expect(reader.currentLoad() == 0.1)
    #expect(tickReads == 2)
}

@Test func cpuRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.cpuLoad(thresholdPercent: 75)
    #expect(rule.label == "CPU above 75%")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}
