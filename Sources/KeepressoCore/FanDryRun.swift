import Foundation
import Observation

/// Outcome of one fan dry run (the "Test Fans" system check in Preferences ▸
/// General ▸ Thermal): step the fans through a few forced levels via the
/// helper, read what the hardware actually did at each, hand control back,
/// and summarize whether the boost path can be trusted.
public struct FanDryRunReport: Equatable, Sendable {
    /// One forced level and the per-fan RPM once it had time to settle.
    /// `rpm` has one entry per fan; `nil` where the read failed.
    public struct Step: Equatable, Sendable {
        public let percent: Int
        public let rpm: [Double?]

        public init(percent: Int, rpm: [Double?]) {
            self.percent = percent
            self.rpm = rpm
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// Every fan followed the forced levels; the boost path works.
        case allGood
        /// The helper accepted the writes but one or more fans never sped up
        /// (typically firmware refusing manual control on this machine).
        case fansDidNotRespond
        /// The helper refused or never answered; nothing was written.
        case helperUnavailable
        /// No fans to test (fanless machine, or the SMC was unreadable).
        case noFans
    }

    public var fanCount: Int
    /// Per-fan RPM right before the first forced write.
    public var baselineRPM: [Double?]
    /// Per-fan reported maximum RPM, for describing headroom. `nil` entries
    /// where the range was unreadable.
    public var maxRPM: [Double?]
    public var steps: [Step]
    /// The hottest temperature seen during the run, when a sensor path
    /// exists, so the report can say readings are alive too.
    public var hottestCelsius: Double?
    public var verdict: Verdict

    public init(
        fanCount: Int,
        baselineRPM: [Double?] = [],
        maxRPM: [Double?] = [],
        steps: [Step] = [],
        hottestCelsius: Double? = nil,
        verdict: Verdict
    ) {
        self.fanCount = fanCount
        self.baselineRPM = baselineRPM
        self.maxRPM = maxRPM
        self.steps = steps
        self.hottestCelsius = hottestCelsius
        self.verdict = verdict
    }

    /// A fan counts as responding when the last forced level clearly moved it
    /// over its baseline, or it was already near its top (a hot machine's
    /// fans may have nowhere left to go, which is not a failure of the boost
    /// path). Deliberately forgiving about exact targets: ramp curves differ
    /// per machine and the settle window is short.
    public static let respondedRPMDelta: Double = 400
    static let nearTopFraction: Double = 0.8

    static func fanResponded(baseline: Double?, final: Double?, range: (min: Double, max: Double)?) -> Bool {
        guard let final else { return false }
        if let baseline, final - baseline >= respondedRPMDelta { return true }
        if let range, final >= range.min + nearTopFraction * (range.max - range.min) { return true }
        return false
    }
}

/// Runs the dry run: baseline read, three forced levels through the helper
/// with a settle-and-read at each, restore to automatic, verdict. Everything
/// it touches is injected (helper, fan reads, temperature, sleeping), so
/// tests script hardware behavior and skip the real settling waits.
///
/// The host must keep this test and the live thermal safety net apart: don't
/// start it while a real boost holds the fans, and cancel it if an emergency
/// boost fires mid-test (``cancelAndWait()``), so the safety net never shares
/// the fan hold with a diagnostic.
@MainActor
@Observable
public final class FanDryRunController {
    public enum Phase: Equatable, Sendable {
        case idle
        /// `percent` is the forced level in flight, `nil` while reading the
        /// baseline.
        case running(percent: Int?)
        case finished(FanDryRunReport)
        /// Stopped early (user, or a real thermal emergency taking the fans);
        /// control was handed back.
        case cancelled
    }

    /// The forced levels, in order. Three points show a ramp, not just "it
    /// moved once".
    public static let levels = [50, 70, 90]
    /// How long each level gets to spin up before its reading.
    public static let settleSeconds: TimeInterval = 4

    public private(set) var phase: Phase = .idle
    /// The in-flight run, awaitable by tests and by the emergency cancel.
    public private(set) var activeRun: Task<Void, Never>?

    private let helper: PrivilegedHelperCalling
    private let fans: FanInfoReading
    private let readCelsius: @MainActor () -> Double?
    private let sleeper: (TimeInterval) async -> Void

    public init(
        helper: PrivilegedHelperCalling,
        fans: FanInfoReading,
        readCelsius: @escaping @MainActor () -> Double? = { nil },
        sleeper: @escaping (TimeInterval) async -> Void = {
            try? await Task.sleep(for: .seconds($0))
        }
    ) {
        self.helper = helper
        self.fans = fans
        self.readCelsius = readCelsius
        self.sleeper = sleeper
    }

    public var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    public func start() {
        guard !isRunning else { return }
        phase = .running(percent: nil)
        activeRun = Task { await perform() }
    }

    /// Stop early and hand fan control back.
    public func cancel() {
        guard isRunning else { return }
        activeRun?.cancel()
    }

    /// Cancel and wait until the fans are actually released, for a thermal
    /// emergency that needs the hold for itself.
    public func cancelAndWait() async {
        cancel()
        await activeRun?.value
    }

    private func perform() async {
        defer { activeRun = nil }
        guard let count = fans.fanCount(), count > 0 else {
            phase = .finished(FanDryRunReport(fanCount: 0, verdict: .noFans))
            return
        }
        let baseline = (0..<count).map { fans.rpm(ofFan: $0) }
        let ranges = (0..<count).map { fans.rpmRange(ofFan: $0) }
        var report = FanDryRunReport(
            fanCount: count,
            baselineRPM: baseline,
            maxRPM: ranges.map { $0?.max },
            hottestCelsius: readCelsius(),
            verdict: .allGood
        )

        for percent in Self.levels {
            phase = .running(percent: percent)
            guard await callHelper(holding: true, percent: percent) else {
                await release()
                report.verdict = .helperUnavailable
                phase = .finished(report)
                return
            }
            await sleeper(Self.settleSeconds)
            if Task.isCancelled {
                await release()
                phase = .cancelled
                return
            }
            report.steps.append(FanDryRunReport.Step(
                percent: percent,
                rpm: (0..<count).map { fans.rpm(ofFan: $0) }
            ))
            if let hot = readCelsius() {
                report.hottestCelsius = max(report.hottestCelsius ?? hot, hot)
            }
        }
        await release()

        let final = report.steps.last?.rpm ?? []
        let allResponded = (0..<count).allSatisfy { fan in
            FanDryRunReport.fanResponded(
                baseline: baseline[fan],
                final: fan < final.count ? final[fan] : nil,
                range: ranges[fan]
            )
        }
        report.verdict = allResponded ? .allGood : .fansDidNotRespond
        phase = .finished(report)
    }

    /// One helper call off the main actor (the XPC client blocks on a
    /// semaphore, same rule as every other caller).
    private func callHelper(holding: Bool, percent: Int) async -> Bool {
        let helper = self.helper
        return await Task.detached { helper.setFanHold(holding, percent: percent) }.value
    }

    private func release() async {
        _ = await callHelper(holding: false, percent: 0)
    }
}
