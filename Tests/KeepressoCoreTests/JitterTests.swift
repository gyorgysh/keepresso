import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Parsing

@Test func jitterParserReadsRepliesAndTimeouts() {
    let output = """
    PING 1.1.1.1 (1.1.1.1): 56 data bytes
    64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=14.719 ms
    64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=17.444 ms
    Request timeout for icmp_seq 2
    64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=16.009 ms

    --- 1.1.1.1 ping statistics ---
    4 packets transmitted, 3 packets received, 25.0% packet loss
    round-trip min/avg/max/stddev = 14.719/16.057/17.444/1.113 ms
    """
    let samples = JitterAnalyzer.parse(output)
    #expect(samples == [
        PingSample(sequence: 0, milliseconds: 14.719),
        PingSample(sequence: 1, milliseconds: 17.444),
        PingSample(sequence: 2, milliseconds: nil),
        PingSample(sequence: 3, milliseconds: 16.009),
    ])
}

@Test func jitterParserIgnoresGarbage() {
    #expect(JitterAnalyzer.parse("").isEmpty)
    #expect(JitterAnalyzer.parse("ping: cannot resolve nowhere.invalid: Unknown host").isEmpty)
}

// MARK: - Analysis

/// Fifty samples on a flat baseline, with `spikeEvery > 0` raising every n-th
/// sample by `spikeBy` ms (n = 5 at 0.2 s is the once-a-second AWDL cadence).
private func synthetic(baseline: Double, spikeEvery: Int = 0, spikeBy: Double = 0) -> [PingSample] {
    (0..<50).map { seq in
        let spiked = spikeEvery > 0 && seq % spikeEvery == 0
        return PingSample(sequence: seq, milliseconds: baseline + (spiked ? spikeBy : 0))
    }
}

@Test func flatLatencyIsClean() {
    let report = JitterAnalyzer.analyze(synthetic(baseline: 15), interval: 0.2)
    #expect(report.verdict == .clean)
    #expect(report.baselineMs == 15)
    #expect(report.spikeCount == 0)
    #expect(report.lostCount == 0)
}

@Test func onceASecondSpikesLookLikeAWDL() {
    // The post's signature: a flat baseline with 50-100 ms detours every
    // second (every 5th sample at 0.2 s).
    let report = JitterAnalyzer.analyze(
        synthetic(baseline: 15, spikeEvery: 5, spikeBy: 80), interval: 0.2)
    #expect(report.verdict == .looksLikeAWDL)
    #expect(report.spikeCount == 10)
    #expect(report.maxMs == 95)
}

@Test func aperiodicSpikesAreJitteryNotAWDL() {
    // Same spike magnitude, but bunched, not periodic: congestion, not AWDL.
    var samples = synthetic(baseline: 15)
    for seq in [7, 8, 9, 30] {
        samples[seq].milliseconds = 95
    }
    let report = JitterAnalyzer.analyze(samples, interval: 0.2)
    #expect(report.verdict == .jittery)
    #expect(report.spikeCount == 4)
}

@Test func constantSpikingIsJitteryEvenWhenEvenlySpaced() {
    // Every other sample spiking is not the AWDL minority-detour shape.
    let report = JitterAnalyzer.analyze(
        synthetic(baseline: 15, spikeEvery: 2, spikeBy: 80), interval: 0.2)
    #expect(report.verdict == .jittery)
}

@Test func tooFewRepliesAreInconclusive() {
    let samples = (0..<20).map { PingSample(sequence: $0, milliseconds: $0 < 5 ? 15 : nil) }
    let report = JitterAnalyzer.analyze(samples, interval: 0.2)
    #expect(report.verdict == .inconclusive)
    #expect(report.baselineMs == nil)
    #expect(report.lostCount == 15)
    #expect(report.summary == "Not enough replies to measure.")
}

@Test func spikeThresholdClearsNormalWanderOnTinyBaselines() {
    // On a 3 ms LAN-grade baseline, doubling alone (6 ms) must not count as a
    // spike; only the +25 ms absolute floor should.
    let report = JitterAnalyzer.analyze(
        synthetic(baseline: 3, spikeEvery: 5, spikeBy: 10), interval: 0.2)
    #expect(report.verdict == .clean)
}

@Test func summaryReadsAsOneLine() {
    var samples = synthetic(baseline: 15, spikeEvery: 5, spikeBy: 80)
    samples[1].milliseconds = nil
    let report = JitterAnalyzer.analyze(samples, interval: 0.2)
    #expect(report.summary == "Baseline 15 ms, 10 spikes up to 95 ms, 1 lost")
}

// MARK: - Controller

private final class FakePingRunner: PingRunning, @unchecked Sendable {
    let output: String?
    init(output: String?) { self.output = output }
    func ping(host: String, count: Int, interval: TimeInterval) -> String? { output }
}

@MainActor
@Test func jitterControllerReportsAFinishedRun() async {
    let output = (0..<50)
        .map { "64 bytes from 1.1.1.1: icmp_seq=\($0) ttl=57 time=15.0 ms" }
        .joined(separator: "\n")
    let controller = JitterTestController(runner: FakePingRunner(output: output))
    #expect(controller.state == .idle)
    await controller.run()
    guard case .finished(let report) = controller.state else {
        Issue.record("expected a finished state")
        return
    }
    #expect(report.verdict == .clean)
}

@MainActor
@Test func jitterControllerFailsWhenPingCannotRun() async {
    let controller = JitterTestController(runner: FakePingRunner(output: nil))
    await controller.run()
    #expect(controller.state == .failed)
}
