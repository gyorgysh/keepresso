import Foundation
import Observation

/// One echo in a jitter test: its sequence number and round-trip time,
/// `nil` when the reply never came back.
public struct PingSample: Equatable, Sendable {
    public var sequence: Int
    public var milliseconds: Double?

    public init(sequence: Int, milliseconds: Double?) {
        self.sequence = sequence
        self.milliseconds = milliseconds
    }
}

/// What the jitter signature looks like.
public enum JitterVerdict: Equatable, Sendable {
    /// Latency is flat: no spikes worth mentioning.
    case clean
    /// Spikes recur about once a second over a flat baseline, the AWDL
    /// signature: the Wi-Fi radio hops off-channel for AirDrop/Handoff scans.
    case looksLikeAWDL
    /// Latency spikes, but without the periodic AWDL cadence (congestion,
    /// weak signal, a busy router).
    case jittery
    /// Not enough replies to judge (offline, a firewall eating ICMP).
    case inconclusive
}

/// The outcome of a jitter test: the raw samples plus the derived numbers the
/// Gaming & Streaming Setup screen reports.
public struct JitterReport: Equatable, Sendable {
    public var samples: [PingSample]
    /// Lower-quartile round-trip of the successful echoes (a floor estimate
    /// spikes can't drag up), `nil` when too few came back.
    public var baselineMs: Double?
    /// Worst round-trip seen.
    public var maxMs: Double?
    /// Echoes counted as spikes (see ``JitterAnalyzer/spikeThreshold(baseline:)``).
    public var spikeCount: Int
    /// Echoes that never came back.
    public var lostCount: Int
    public var verdict: JitterVerdict

    public init(
        samples: [PingSample],
        baselineMs: Double?,
        maxMs: Double?,
        spikeCount: Int,
        lostCount: Int,
        verdict: JitterVerdict
    ) {
        self.samples = samples
        self.baselineMs = baselineMs
        self.maxMs = maxMs
        self.spikeCount = spikeCount
        self.lostCount = lostCount
        self.verdict = verdict
    }

    /// One-line numeric summary for the UI, e.g.
    /// "Baseline 12 ms, 8 spikes up to 96 ms, 1 lost".
    public var summary: String {
        guard let baselineMs, let maxMs else {
            return "Not enough replies to measure."
        }
        var parts = ["Baseline \(Int(baselineMs.rounded())) ms"]
        if spikeCount > 0 {
            parts.append("\(spikeCount) spike\(spikeCount == 1 ? "" : "s") up to \(Int(maxMs.rounded())) ms")
        } else {
            parts.append("max \(Int(maxMs.rounded())) ms")
        }
        if lostCount > 0 {
            parts.append("\(lostCount) lost")
        }
        return parts.joined(separator: ", ")
    }
}

/// Pure parsing and analysis of a ping run — the heart of the jitter test and
/// the unit under test. The impure spawn lives behind ``PingRunning``.
public enum JitterAnalyzer {
    /// How many successful echoes a run needs before the verdict means anything.
    static let minimumReplies = 10

    /// A reply this far above the baseline counts as a spike. AWDL detours
    /// add roughly 50-100 ms, so half that clears normal wander without
    /// missing real hops; doubling a tiny baseline alone isn't a spike.
    static func spikeThreshold(baseline: Double) -> Double {
        max(baseline + 25, baseline * 2)
    }

    /// Parse raw `ping` output into ordered samples. Reply lines look like
    /// `64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=12.345 ms`; a drop is
    /// `Request timeout for icmp_seq 3`. Anything else is ignored.
    public static func parse(_ output: String) -> [PingSample] {
        var samples: [PingSample] = []
        for line in output.split(whereSeparator: \.isNewline) {
            if line.contains("bytes from"),
               let seq = integer(after: "icmp_seq=", in: line),
               let ms = double(after: "time=", in: line) {
                samples.append(PingSample(sequence: seq, milliseconds: ms))
            } else if line.contains("Request timeout"),
                      let seq = integer(after: "icmp_seq ", in: line) {
                samples.append(PingSample(sequence: seq, milliseconds: nil))
            }
        }
        return samples
    }

    /// Judge a run. `interval` is the seconds between echoes (the cadence the
    /// AWDL periodicity check is expressed in).
    public static func analyze(_ samples: [PingSample], interval: TimeInterval) -> JitterReport {
        let replies = samples.compactMap { sample in
            sample.milliseconds.map { (sequence: sample.sequence, ms: $0) }
        }
        let lost = samples.count - replies.count
        guard replies.count >= minimumReplies else {
            return JitterReport(
                samples: samples, baselineMs: nil, maxMs: nil,
                spikeCount: 0, lostCount: lost, verdict: .inconclusive
            )
        }

        // Lower quartile, not median: the baseline should estimate the floor,
        // and a median gets dragged up once spikes near half the samples
        // (which would then hide the spikes entirely).
        let sorted = replies.map(\.ms).sorted()
        let baseline = sorted[sorted.count / 4]
        let threshold = spikeThreshold(baseline: baseline)
        let spikes = replies.filter { $0.ms >= threshold }

        let verdict: JitterVerdict
        if spikes.isEmpty {
            verdict = .clean
        } else if isPeriodic(spikeSequences: spikes.map(\.sequence), interval: interval),
                  spikes.count * 2 < replies.count {
            verdict = .looksLikeAWDL
        } else {
            verdict = .jittery
        }
        return JitterReport(
            samples: samples,
            baselineMs: baseline,
            maxMs: sorted.last,
            spikeCount: spikes.count,
            lostCount: lost,
            verdict: verdict
        )
    }

    /// The AWDL cadence: spikes lands roughly once a second. True when there
    /// are at least three spikes and two thirds of the gaps between successive
    /// ones fall in the 0.5-2.5 s band.
    static func isPeriodic(spikeSequences: [Int], interval: TimeInterval) -> Bool {
        guard spikeSequences.count >= 3, interval > 0 else { return false }
        let gaps = zip(spikeSequences.dropFirst(), spikeSequences)
            .map { Double($0 - $1) * interval }
        let periodic = gaps.filter { (0.5...2.5).contains($0) }
        return periodic.count * 3 >= gaps.count * 2
    }

    // MARK: - Field extraction

    private static func integer(after prefix: String, in line: Substring) -> Int? {
        field(after: prefix, in: line).flatMap { Int($0) }
    }

    private static func double(after prefix: String, in line: Substring) -> Double? {
        field(after: prefix, in: line).flatMap { Double($0) }
    }

    /// The run of number characters right after `prefix`.
    private static func field(after prefix: String, in line: Substring) -> Substring? {
        guard let range = line.range(of: prefix) else { return nil }
        let rest = line[range.upperBound...]
        let value = rest.prefix { $0.isNumber || $0 == "." }
        return value.isEmpty ? nil : value
    }
}

/// System-touching seam: run a ping burst and return the raw output (`nil`
/// when the command couldn't run at all). Blocking for its full duration, so
/// callers hop off the main actor. Tests feed canned output.
public protocol PingRunning: AnyObject, Sendable {
    func ping(host: String, count: Int, interval: TimeInterval) -> String?
}

/// Real backend over `/sbin/ping`. An interval down to 0.1 s is allowed
/// without privileges, so the 0.2 s cadence needs no prompt. Output is
/// returned regardless of exit status: ping exits non-zero when packets were
/// lost, and lost packets are exactly what the analyzer wants to see.
public final class PingCommandRunner: PingRunning {
    public init() {}

    public func ping(host: String, count: Int, interval: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", String(count), "-i", String(interval), "-n", host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}

/// Drives the jitter test in the Gaming & Streaming Setup screen. Owns no
/// timer: the host calls ``run()`` from its button. `@MainActor` like the
/// other controllers; the blocking ping burst runs on a detached task.
@MainActor
@Observable
public final class JitterTestController {
    public enum State: Equatable, Sendable {
        case idle
        case running
        case finished(JitterReport)
        /// The ping couldn't run at all (no network path, missing binary).
        case failed
    }

    public private(set) var state: State = .idle

    /// The post's diagnosis recipe: ~10 s of echoes at 0.2 s intervals, wide
    /// enough to catch ten AWDL hops while staying under the boredom limit.
    /// `nonisolated` so the detached ping task can read them.
    public nonisolated static let host = "1.1.1.1"
    public nonisolated static let count = 50
    public nonisolated static let interval: TimeInterval = 0.2

    private let runner: PingRunning

    public init(runner: PingRunning = PingCommandRunner()) {
        self.runner = runner
    }

    /// Run one burst and land the report back on the main actor. Ignores a
    /// second press while a run is in flight.
    public func run() async {
        guard state != .running else { return }
        state = .running
        let runner = self.runner
        let output = await Task.detached {
            runner.ping(host: Self.host, count: Self.count, interval: Self.interval)
        }.value
        guard let output else {
            state = .failed
            return
        }
        state = .finished(JitterAnalyzer.analyze(
            JitterAnalyzer.parse(output),
            interval: Self.interval
        ))
    }
}
