import Testing
import Foundation
@testable import KeepressoCore

private final class FakeThroughputReader: NetworkThroughputReading {
    var readings: [Double?]
    init(_ readings: [Double?]) { self.readings = readings }
    func currentBytesPerSecond() -> Double? { readings.isEmpty ? nil : readings.removeFirst() }
}

/// Run the pure step over a sample sequence (bytes/sec) and return the final state.
private func run(_ samples: [Double?], thresholdKB: Int, from state: NetworkThroughputTrigger.SmoothingState = .init()) -> NetworkThroughputTrigger.SmoothingState {
    samples.reduce(state) { NetworkThroughputTrigger.step($0, sampleBytesPerSecond: $1, thresholdKilobytesPerSecond: thresholdKB) }
}

@Test func sustainedHighThroughputFires() {
    // 1 MB/s sustained, threshold 500 KB/s.
    let state = run(Array(repeating: 1_000_000, count: 12), thresholdKB: 500)
    #expect(state.isSatisfied)
}

@Test func aBriefBurstDoesNotFire() {
    // Quiet, one 1.5 MB/s second, quiet again: smoothed over the low base the
    // average never reaches the 500 KB/s threshold, so no session starts.
    let state = run([10_000, 10_000, 1_500_000, 10_000, 10_000], thresholdKB: 500)
    #expect(!state.isSatisfied)
}

@Test func throughputHysteresisPreventsFlapping() {
    var state = run(Array(repeating: 2_000_000, count: 12), thresholdKB: 500)
    #expect(state.isSatisfied)
    // Hovering just under the threshold (450 KB/s) but above the release band
    // (70% of 500 KB/s = 350 KB/s) keeps it on...
    state = run(Array(repeating: 450_000, count: 12), thresholdKB: 500, from: state)
    #expect(state.isSatisfied)
    // ...but dropping clearly below turns it off.
    state = run(Array(repeating: 100_000, count: 30), thresholdKB: 500, from: state)
    #expect(!state.isSatisfied)
}

@Test func nilThroughputReadingsHoldThePreviousVerdict() {
    var state = run(Array(repeating: 1_000_000, count: 12), thresholdKB: 500)
    #expect(state.isSatisfied)
    state = run([nil, nil, nil], thresholdKB: 500, from: state)
    #expect(state.isSatisfied) // a transient read failure / counter wrap doesn't drop it
    #expect(!run([nil, nil], thresholdKB: 500).isSatisfied) // but no data ever seen stays off
}

@MainActor
@Test func throughputTriggerAdvancesOnlyOnTick() {
    let reader = FakeThroughputReader(Array(repeating: 1_000_000, count: 12))
    let trigger = NetworkThroughputTrigger(thresholdKilobytesPerSecond: 500, reader: reader)
    for _ in 0 ..< 12 { trigger.tick() }
    #expect(trigger.isSatisfied())
}

@MainActor
@Test func throughputIsSatisfiedIsAPureReadThatDoesNotStep() {
    let reader = FakeThroughputReader(Array(repeating: 1_000_000, count: 5))
    let trigger = NetworkThroughputTrigger(thresholdKilobytesPerSecond: 500, reader: reader)
    for _ in 0 ..< 100 { _ = trigger.isSatisfied() } // no ticks: nothing read
    #expect(!trigger.isSatisfied())     // never armed
    #expect(reader.readings.count == 5) // reader untouched
}

@Test func getifaddrsReaderComputesBytesPerSecondBetweenSamples() {
    var current = Date(timeIntervalSinceReferenceDate: 0)
    var samples: [UInt64] = [1000, 1500]
    let reader = GetifaddrsThroughputReader(ttl: 0.5, now: { current }, readBytes: { samples.removeFirst() })

    #expect(reader.currentBytesPerSecond() == nil) // first sample: nothing to diff against
    current = current.addingTimeInterval(1)
    #expect(reader.currentBytesPerSecond() == 500) // 500 bytes over 1 second
}

@Test func getifaddrsReaderSkipsABackwardsCounter() {
    // A wrap / interface reset makes the total go down; report nil (skip that
    // interval) rather than a bogus negative rate.
    var current = Date(timeIntervalSinceReferenceDate: 0)
    var samples: [UInt64] = [5000, 1000]
    let reader = GetifaddrsThroughputReader(ttl: 0.5, now: { current }, readBytes: { samples.removeFirst() })
    _ = reader.currentBytesPerSecond()
    current = current.addingTimeInterval(1)
    #expect(reader.currentBytesPerSecond() == nil)
}

@Test func rateLabelReadsNaturally() {
    #expect(NetworkThroughput.rateLabel(kilobytesPerSecond: 100) == "100 KB/s")
    #expect(NetworkThroughput.rateLabel(kilobytesPerSecond: 1024) == "1 MB/s")
    #expect(NetworkThroughput.rateLabel(kilobytesPerSecond: 5120) == "5 MB/s")
    #expect(NetworkThroughput.rateLabel(kilobytesPerSecond: 1536) == "1.5 MB/s")
}

@Test func throughputRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.throughput(kilobytesPerSecond: 1024)
    #expect(rule.label == "Network above 1 MB/s")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}
