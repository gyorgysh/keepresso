import Testing
import Foundation
@testable import KeepressoCore

private final class FakeThroughputReader: NetworkThroughputReading {
    var readings: [Double?]
    init(_ readings: [Double?]) { self.readings = readings }
    func currentBytesPerSecond() -> Double? { readings.isEmpty ? nil : readings.removeFirst() }
}

private func run(_ samples: [Double?], thresholdKB: Int, from state: NetworkThroughputTrigger.SmoothingState = .init()) -> NetworkThroughputTrigger.SmoothingState {
    samples.reduce(state) { NetworkThroughputTrigger.step($0, sampleBytesPerSecond: $1, thresholdKilobytesPerSecond: thresholdKB) }
}

@Test func sustainedHighThroughputFires() {
    let state = run(Array(repeating: 1_000_000, count: 12), thresholdKB: 500)
    #expect(state.isSatisfied)
}

@Test func aBriefBurstDoesNotFire() {
    let state = run([10_000, 10_000, 1_500_000, 10_000, 10_000], thresholdKB: 500)
    #expect(!state.isSatisfied)
}

@Test func throughputHysteresisPreventsFlapping() {
    var state = run(Array(repeating: 2_000_000, count: 12), thresholdKB: 500)
    #expect(state.isSatisfied)
    state = run(Array(repeating: 450_000, count: 12), thresholdKB: 500, from: state)
    #expect(state.isSatisfied)
    state = run(Array(repeating: 100_000, count: 30), thresholdKB: 500, from: state)
    #expect(!state.isSatisfied)
}

@Test func nilThroughputReadingsHoldThePreviousVerdict() {
    var state = run(Array(repeating: 1_000_000, count: 12), thresholdKB: 500)
    #expect(state.isSatisfied)
    state = run([nil, nil, nil], thresholdKB: 500, from: state)
    #expect(state.isSatisfied)
    #expect(!run([nil, nil], thresholdKB: 500).isSatisfied)
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
    for _ in 0 ..< 100 { _ = trigger.isSatisfied() }
    #expect(!trigger.isSatisfied())
    #expect(reader.readings.count == 5)
}

@Test func getifaddrsReaderComputesBytesPerSecondBetweenSamples() {
    var current = Date(timeIntervalSinceReferenceDate: 0)
    var samples: [UInt64] = [1000, 1500]
    let reader = GetifaddrsThroughputReader(ttl: 0.5, now: { current }, readBytes: { samples.removeFirst() })

    #expect(reader.currentBytesPerSecond() == nil)
    current = current.addingTimeInterval(1)
    #expect(reader.currentBytesPerSecond() == 500)
}

@Test func getifaddrsReaderSkipsABackwardsCounter() {
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
