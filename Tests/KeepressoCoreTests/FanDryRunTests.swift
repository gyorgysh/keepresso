import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Fakes

/// Scripted helper: records fan-hold calls, optionally refuses them.
private final class FakeFanHelper: PrivilegedHelperCalling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    var accepts = true

    func ping() -> Bool { true }
    func pingVersion() -> Int? { HelperService.protocolVersion }
    func setSleepDisabled(_ disabled: Bool) -> Bool { true }
    func setSleepHold(_ holding: Bool) -> Bool { true }
    func setAWDLHold(_ holding: Bool) -> Bool { true }
    func setPriorityHold(_ holding: Bool, pid: Int) -> Bool { true }

    func setFanHold(_ holding: Bool, percent: Int) -> Bool {
        lock.lock()
        calls.append(holding ? "hold(\(percent))" : "release")
        let ok = accepts || !holding // releases always land
        lock.unlock()
        return ok
    }

    func fanHoldDropped() -> Bool? { false }
    func sleepNow() -> Bool { true }
    func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool { true }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Scripted fans: a fixed count and range, and an RPM that tracks whatever
/// the helper was last asked to hold (responsive), or stays put (stuck).
private final class FakeFans: FanInfoReading, @unchecked Sendable {
    var count: Int? = 2
    var idleRPM: Double = 1200
    var range: (min: Double, max: Double)? = (1000, 6000)
    /// When set, `rpm(ofFan:)` follows the forced percent; otherwise it
    /// stays at `idleRPM` (a fan that ignores the writes).
    var responsive = true
    var forcedPercent: Int?

    func fanCount() -> Int? { count }
    func currentRPM() -> Double? { rpm(ofFan: 0) }

    func rpm(ofFan index: Int) -> Double? {
        guard responsive, let percent = forcedPercent, let range else { return idleRPM }
        return range.min + Double(percent) / 100 * (range.max - range.min)
    }

    func rpmRange(ofFan index: Int) -> (min: Double, max: Double)? { range }
}

/// Wires the fake helper's holds into the fake fans, so a "responsive"
/// machine spins up when the controller asks the helper to boost.
private final class RigHelper: PrivilegedHelperCalling, @unchecked Sendable {
    let inner = FakeFanHelper()
    let fans: FakeFans

    init(fans: FakeFans) {
        self.fans = fans
    }

    func ping() -> Bool { inner.ping() }
    func pingVersion() -> Int? { inner.pingVersion() }
    func setSleepDisabled(_ disabled: Bool) -> Bool { true }
    func setSleepHold(_ holding: Bool) -> Bool { true }
    func setAWDLHold(_ holding: Bool) -> Bool { true }
    func setPriorityHold(_ holding: Bool, pid: Int) -> Bool { inner.setPriorityHold(holding, pid: pid) }

    func setFanHold(_ holding: Bool, percent: Int) -> Bool {
        let ok = inner.setFanHold(holding, percent: percent)
        if ok { fans.forcedPercent = holding ? percent : nil }
        return ok
    }

    func fanHoldDropped() -> Bool? { inner.fanHoldDropped() }
    func sleepNow() -> Bool { true }
    func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool { true }
}

@MainActor
private func makeController(
    fans: FakeFans,
    celsius: Double? = nil,
    sleeper: @escaping (TimeInterval) async -> Void = { _ in }
) -> (FanDryRunController, RigHelper) {
    let helper = RigHelper(fans: fans)
    let controller = FanDryRunController(
        helper: helper,
        fans: fans,
        readCelsius: { celsius },
        sleeper: sleeper
    )
    return (controller, helper)
}

// MARK: - Tests

@MainActor
@Test func dryRunStepsThroughTheLevelsAndReportsAllGood() async {
    let fans = FakeFans()
    let (controller, helper) = makeController(fans: fans, celsius: 61)
    controller.start()
    await controller.activeRun?.value

    guard case .finished(let report) = controller.phase else {
        Issue.record("expected a finished phase, got \(controller.phase)")
        return
    }
    #expect(report.verdict == .allGood)
    #expect(report.fanCount == 2)
    #expect(report.steps.map(\.percent) == FanDryRunController.levels)
    #expect(report.baselineRPM == [1200, 1200])
    #expect(report.hottestCelsius == 61)
    // Three holds in rising order, then exactly one release at the end.
    #expect(helper.inner.recorded == ["hold(50)", "hold(70)", "hold(90)", "release"])
    // The last reading tracked the 90% target.
    #expect(report.steps.last?.rpm.first == 1000 + 0.9 * 5000)
}

@MainActor
@Test func unresponsiveFansProduceAFailedVerdictAndStillRestore() async {
    let fans = FakeFans()
    fans.responsive = false
    let (controller, helper) = makeController(fans: fans)
    controller.start()
    await controller.activeRun?.value

    guard case .finished(let report) = controller.phase else {
        Issue.record("expected a finished phase, got \(controller.phase)")
        return
    }
    #expect(report.verdict == .fansDidNotRespond)
    #expect(helper.inner.recorded.last == "release")
}

@MainActor
@Test func helperRefusalAbortsEarlyWithoutFurtherLevels() async {
    let fans = FakeFans()
    let (controller, helper) = makeController(fans: fans)
    helper.inner.accepts = false
    controller.start()
    await controller.activeRun?.value

    guard case .finished(let report) = controller.phase else {
        Issue.record("expected a finished phase, got \(controller.phase)")
        return
    }
    #expect(report.verdict == .helperUnavailable)
    #expect(report.steps.isEmpty)
    // One refused hold, then the release; never the next level.
    #expect(helper.inner.recorded == ["hold(50)", "release"])
}

@MainActor
@Test func fanlessMachineFinishesImmediately() async {
    let fans = FakeFans()
    fans.count = 0
    let (controller, helper) = makeController(fans: fans)
    controller.start()
    await controller.activeRun?.value

    guard case .finished(let report) = controller.phase else {
        Issue.record("expected a finished phase, got \(controller.phase)")
        return
    }
    #expect(report.verdict == .noFans)
    #expect(helper.inner.recorded.isEmpty)
}

@MainActor
@Test func cancelMidRunReleasesTheHoldAndEndsCancelled() async {
    let fans = FakeFans()
    let gate = AsyncGate()
    let (controller, helper) = makeController(fans: fans) { _ in
        await gate.pause()
    }
    controller.start()
    // Let the run reach its first settle wait, then pull the plug.
    await Task.yield()
    await controller.cancelAndWait()

    #expect(controller.phase == .cancelled)
    #expect(helper.inner.recorded.last == "release")
    #expect(fans.forcedPercent == nil)
}

@MainActor
@Test func startWhileRunningIsIgnored() async {
    let fans = FakeFans()
    let (controller, helper) = makeController(fans: fans)
    controller.start()
    controller.start() // ignored: one run only
    await controller.activeRun?.value
    // A doubled run would have doubled the calls.
    #expect(helper.inner.recorded == ["hold(50)", "hold(70)", "hold(90)", "release"])
}

@Test func respondedJudgesDeltaAndNearTopFallback() {
    // A clear rise over baseline responds.
    #expect(FanDryRunReport.fanResponded(baseline: 1200, final: 1700, range: (1000, 6000)))
    // Flat at idle does not.
    #expect(!FanDryRunReport.fanResponded(baseline: 1200, final: 1250, range: (1000, 6000)))
    // Already near the top with no headroom still counts (hot machine).
    #expect(FanDryRunReport.fanResponded(baseline: 5600, final: 5700, range: (1000, 6000)))
    // No reading at all is a failure.
    #expect(!FanDryRunReport.fanResponded(baseline: 1200, final: nil, range: (1000, 6000)))
    // No baseline and no range: nothing to judge against, fail safe.
    #expect(!FanDryRunReport.fanResponded(baseline: nil, final: 3000, range: nil))
}

/// A sleeper the test can hold open until cancellation arrives.
private actor AsyncGate {
    func pause() async {
        // Parks until the surrounding task is cancelled; cancellation makes
        // the sleep throw and return immediately.
        try? await Task.sleep(for: .seconds(60))
    }
}
