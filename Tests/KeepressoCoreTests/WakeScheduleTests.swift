import Testing
import Foundation
@testable import KeepressoCore

@Test func weekdaysNormalizeAndDefaultToAll() {
    #expect(WakeScheduleConfig.normalizedWeekdays("mwf") == "MWF")
    #expect(WakeScheduleConfig.normalizedWeekdays("xyz") == "MTWRFSU")
    #expect(WakeScheduleConfig.normalizedWeekdays("") == "MTWRFSU")
}

@Test func oneShotStringUsesLocalPmsetFormat() {
    let cal = Calendar(identifier: .gregorian)
    let date = cal.date(from: DateComponents(
        year: 2026, month: 7, day: 18, hour: 3, minute: 15, second: 0
    ))!
    let stamp = WakeScheduleConfig.oneShotString(for: date, calendar: cal)
    #expect(stamp == "07/18/26 03:15:00")
}

@Test func repeatTimeStringIsZeroPadded() {
    var config = WakeScheduleConfig(repeatSecondsFromMidnight: 3 * 3600 + 5 * 60 + 9)
    #expect(config.repeatTimeString == "03:05:09")
    config = WakeScheduleConfig(repeatSecondsFromMidnight: 0)
    #expect(config.repeatTimeString == "00:00:00")
}

@Test func wakeAndBrewMatchesOneShotWithinWindow() {
    let slot = Date(timeIntervalSince1970: 5_000)
    let config = WakeScheduleConfig(
        oneShot: slot, startSessionOnWake: true, sessionDurationSeconds: 3600)
    #expect(WakeAndBrewPolicy.shouldStartSession(
        config: config, wakeDate: slot.addingTimeInterval(90)))
    #expect(!WakeAndBrewPolicy.shouldStartSession(
        config: config, wakeDate: slot.addingTimeInterval(10 * 60)))
}

@Test func wakeAndBrewMatchesRepeatingSlot() {
    let cal = Calendar(identifier: .gregorian)
    // A Monday at 03:00 local.
    let monday = cal.date(from: DateComponents(
        year: 2026, month: 7, day: 20, hour: 3, minute: 0 // 2026-07-20 is Monday
    ))!
    #expect(WakeAndBrewPolicy.weekdayLetter(for: monday, calendar: cal) == "M")
    let config = WakeScheduleConfig(
        repeatingEnabled: true,
        repeatSecondsFromMidnight: 3 * 3600,
        repeatWeekdays: "MTWRF",
        startSessionOnWake: true
    )
    #expect(WakeAndBrewPolicy.shouldStartSession(
        config: config, wakeDate: monday.addingTimeInterval(30), calendar: cal))
    // Sunday is outside the weekday set.
    let sunday = cal.date(from: DateComponents(
        year: 2026, month: 7, day: 19, hour: 3, minute: 0
    ))!
    #expect(!WakeAndBrewPolicy.shouldStartSession(
        config: config, wakeDate: sunday, calendar: cal))
}

@Test func wakeAndBrewRespectsStartSessionFlag() {
    let slot = Date(timeIntervalSince1970: 9_000)
    let config = WakeScheduleConfig(
        oneShot: slot, startSessionOnWake: false)
    #expect(!WakeAndBrewPolicy.shouldStartSession(config: config, wakeDate: slot))
}

@Test func wakeAndBrewMatchesPreviousDaySlotAcrossMidnight() {
    let cal = Calendar(identifier: .gregorian)
    // Friday-only 23:58 slot; the firmware wake lands Saturday 00:01.
    let config = WakeScheduleConfig(
        repeatingEnabled: true,
        repeatSecondsFromMidnight: 23 * 3600 + 58 * 60,
        repeatWeekdays: "F",
        startSessionOnWake: true
    )
    let saturdayJustPastMidnight = cal.date(from: DateComponents(
        year: 2026, month: 7, day: 25, hour: 0, minute: 1 // 2026-07-25 is Saturday
    ))!
    #expect(WakeAndBrewPolicy.weekdayLetter(for: saturdayJustPastMidnight, calendar: cal) == "S")
    #expect(WakeAndBrewPolicy.shouldStartSession(
        config: config, wakeDate: saturdayJustPastMidnight, calendar: cal))
    // Sunday just past midnight is a day too late for Friday's slot.
    let sundayJustPastMidnight = cal.date(from: DateComponents(
        year: 2026, month: 7, day: 26, hour: 0, minute: 1
    ))!
    #expect(!WakeAndBrewPolicy.shouldStartSession(
        config: config, wakeDate: sundayJustPastMidnight, calendar: cal))
}

@Test func schedParserExtractsOneShotWakes() {
    let text = """
    Scheduled power events:
     [0]  wake at 07/18/2026 14:32:09 by 'com.apple.alarm'
     [1]  wake at 07/19/26 04:20:00 by 'other'
    """
    let state = WakeScheduleParser.parse(text)
    #expect(state.scheduledWakes.count == 2)
}

@Test func schedParserReadsRepeatingEventFromItsOwnLine() {
    // Real pmset prints the repeating event on the indented line after the
    // bare section header, not after the colon.
    let text = """
    Repeating power events:
      wakeorpoweron at 3:00:00AM every day
    Scheduled power events:
     [0]  wake at 07/18/26 14:32:09 by 'Keepresso'
    """
    let state = WakeScheduleParser.parse(text)
    #expect(state.repeatingSummary == "wakeorpoweron at 3:00:00AM every day")
    #expect(state.scheduledWakes.count == 1)
}

@Test func schedParserTreatsEmptyRepeatingSectionAsNone() {
    let text = """
    Repeating power events:
    Scheduled power events:
     [0]  wake at 07/18/26 14:32:09 by 'Keepresso'
    """
    let state = WakeScheduleParser.parse(text)
    #expect(state.repeatingSummary == nil)
    #expect(state.scheduledWakes.count == 1)
}

@Test func helperApplyWakeScheduleClearsWhenInactive() {
    let runner = RecordingRunner()
    let state = FakeMarkerState()
    let engine = HelperEngine(runner: runner, state: state)
    #expect(engine.applyWakeSchedule(WakeScheduleConfig()))
    #expect(runner.commands.contains { $0.contains("cancelall") })
    #expect(runner.commands.contains { $0.contains("repeat cancel") })
}

@Test func helperApplyWakeScheduleInstallsOneShotAndRepeat() {
    let runner = RecordingRunner()
    let engine = HelperEngine(runner: runner, state: FakeMarkerState())
    let cal = Calendar(identifier: .gregorian)
    let date = cal.date(from: DateComponents(
        year: 2026, month: 8, day: 1, hour: 6, minute: 30
    ))!
    let config = WakeScheduleConfig(
        oneShot: date,
        repeatingEnabled: true,
        repeatSecondsFromMidnight: 7 * 3600,
        repeatWeekdays: "MWF"
    )
    #expect(engine.applyWakeSchedule(config))
    #expect(runner.commands.contains { $0.contains("schedule wake") })
    #expect(runner.commands.contains { $0.contains("repeat wakeorpoweron MWF 07:00:00") })
}

@Test func failedClearIsAcceptedAsDurablePendingWork() {
    let runner = RecordingRunner()
    runner.failAll = true
    let state = FakeMarkerState()
    let engine = HelperEngine(runner: runner, state: state)
    #expect(engine.clearWakeSchedules())
    #expect(state.markers().contains(.wakeClearPending))
}

@Test func partiallyFailedClearIsAcceptedAndKeepsThePendingMarker() {
    // One of the two cancels failing must not read as success: the surviving
    // schedule would keep waking the Mac with no retry debt.
    let runner = RecordingRunner()
    runner.failMatching = "repeat cancel"
    let state = FakeMarkerState()
    let engine = HelperEngine(runner: runner, state: state)
    #expect(engine.clearWakeSchedules())
    #expect(state.markers().contains(.wakeClearPending))
}

@Test func failedClearPreventsInstallAndKeepsTheRecoveryDebt() {
    // Installing after a failed clear could stack an old one-shot and then
    // lose track of it. The apply stops before installation and keeps debt.
    let runner = RecordingRunner()
    runner.failMatching = "cancelall"
    let state = FakeMarkerState()
    let engine = HelperEngine(runner: runner, state: state)
    let ok = engine.applyWakeSchedule(
        oneShot: "08/01/26 06:30:00", repeatDays: "MWF", repeatTime: "07:00:00")
    #expect(ok)
    #expect(state.markers().contains(.wakeClearPending))
    #expect(!runner.commands.contains { $0.contains("schedule wake") })
    #expect(!runner.commands.contains { $0.contains("wakeorpoweron") })

    // The desired schedule is durable. Once the transient clear failure is
    // gone, the helper tick completes the original install without the app.
    runner.failMatching = nil
    engine.wakeTick()
    #expect(!state.markers().contains(.wakeClearPending))
    #expect(runner.commands.contains { $0.contains("schedule wake") })
    #expect(runner.commands.contains { $0.contains("wakeorpoweron") })
}

@Test func totallyFailedApplyIsAcceptedAndKeepsTheDesiredDebt() {
    // When neither the clear nor the install lands, the debt must survive so
    // the next daemon launch still settles whatever pmset is left holding.
    let runner = RecordingRunner()
    runner.failAll = true
    let state = FakeMarkerState()
    let engine = HelperEngine(runner: runner, state: state)
    #expect(engine.applyWakeSchedule(
        oneShot: "08/01/26 06:30:00", repeatDays: nil, repeatTime: nil))
    #expect(state.markers().contains(.wakeClearPending))
}

@Test func restoreAtLaunchRetriesPendingWakeClear() {
    let runner = RecordingRunner()
    let state = FakeMarkerState([.wakeClearPending])
    let engine = HelperEngine(runner: runner, state: state)
    engine.restoreAtLaunch()
    #expect(runner.commands.contains { $0.contains("cancelall") })
    #expect(!state.markers().contains(.wakeClearPending))
}

@Test func wakeIntentPersistenceFailureRunsNoPMSetAndTheSamePlanCanRetry() {
    let runner = RecordingRunner()
    let state = FakeMarkerState()
    state.failWrites = true
    let engine = HelperEngine(runner: runner, state: state)

    #expect(!engine.clearWakeSchedules())
    #expect(runner.commands.isEmpty)
    #expect(engine.isIdle)
    #expect(!engine.applyWakeSchedule(
        oneShot: "08/01/26 06:30:00", repeatDays: nil, repeatTime: nil
    ))
    #expect(runner.commands.isEmpty)
    state.failWrites = false
    #expect(engine.applyWakeSchedule(
        oneShot: "08/01/26 06:30:00", repeatDays: nil, repeatTime: nil
    ))
    #expect(runner.commands.contains { $0.contains("schedule wake") })
}

@Test func wakeMarkerFailureRunsNoPMSetAndThePersistedPlanCanRetry() {
    let runner = RecordingRunner()
    let state = FakeMarkerState()
    state.failMarkerWrites = true
    let engine = HelperEngine(runner: runner, state: state)

    #expect(!engine.applyWakeSchedule(
        oneShot: "08/01/26 06:30:00", repeatDays: nil, repeatTime: nil
    ))
    #expect(runner.commands.isEmpty)
    #expect(state.markers().isEmpty)
    #expect(state.wakeTransaction()?.oneShot == "08/01/26 06:30:00")

    state.failMarkerWrites = false
    #expect(engine.applyWakeSchedule(
        oneShot: "08/01/26 06:30:00", repeatDays: nil, repeatTime: nil
    ))
    #expect(runner.commands.contains { $0.contains("schedule wake") })
}

@Test func wakeAppliedPhaseWriteFailureKeepsPendingIntentForTickRetry() {
    let runner = RecordingRunner()
    let state = FakeMarkerState()
    state.failAppliedWrites = true
    let engine = HelperEngine(runner: runner, state: state)

    #expect(engine.applyWakeSchedule(
        oneShot: "08/01/26 06:30:00", repeatDays: nil, repeatTime: nil
    ))
    #expect(state.markers().contains(.wakeClearPending))
    #expect(state.wakeTransaction()?.phase == .pendingApply)
    state.failAppliedWrites = false
    engine.wakeTick()
    #expect(state.markers().isEmpty)
    #expect(state.wakeTransaction() == nil)
    #expect(runner.commands.filter { $0.contains("schedule wake") }.count == 2)
}

@Test func failedLaunchWakeRecoveryBlocksIdleAndRetriesOnTick() {
    let runner = RecordingRunner()
    runner.failMatching = "cancelall"
    let state = FakeMarkerState([.wakeClearPending])
    let engine = HelperEngine(runner: runner, state: state)

    engine.restoreAtLaunch()
    #expect(state.markers().contains(.wakeClearPending))
    #expect(!engine.isIdle)
    runner.failMatching = nil
    engine.wakeTick()
    #expect(!state.markers().contains(.wakeClearPending))
    #expect(engine.isIdle)
}

@Test func failedWakeMarkerClearIsRetriedWithoutReportingSuccess() {
    let runner = RecordingRunner()
    let state = FakeMarkerState()
    state.failClears = true
    let engine = HelperEngine(runner: runner, state: state)

    #expect(engine.applyWakeSchedule(
        oneShot: "08/01/26 06:30:00", repeatDays: nil, repeatTime: nil
    ))
    #expect(state.markers().contains(.wakeClearPending))
    #expect(!engine.isIdle)
    state.failClears = false
    engine.wakeTick()
    #expect(!state.markers().contains(.wakeClearPending))
    #expect(engine.isIdle)
    // The applied phase is durable, so cleanup retry runs no pmset command.
    #expect(runner.commands.filter { $0.contains("cancelall") }.count == 1)
    #expect(runner.commands.filter { $0.contains("schedule wake") }.count == 1)
}

@Test func launchRecoveryCompletesAPersistedDesiredWakeSchedule() {
    let runner = RecordingRunner()
    runner.failMatching = "schedule wake"
    let transaction = HelperWakeTransaction(
        oneShot: "08/01/26 06:30:00",
        repeatDays: "MWF",
        repeatTime: "07:00:00"
    )
    let state = FakeMarkerState([.wakeClearPending], wakeTransaction: transaction)
    let engine = HelperEngine(runner: runner, state: state)

    engine.restoreAtLaunch()
    #expect(state.markers().contains(.wakeClearPending))
    #expect(state.wakeTransaction()?.phase == .pendingApply)
    runner.failMatching = nil
    engine.wakeTick()
    #expect(!state.markers().contains(.wakeClearPending))
    #expect(state.wakeTransaction() == nil)
    #expect(runner.commands.contains { $0.contains("schedule wake") })
    #expect(runner.commands.contains { $0.contains("wakeorpoweron") })
}

@Test func appliedWakePhaseSurvivesLaunchWithoutRepeatingPMSet() {
    let runner = RecordingRunner()
    let transaction = HelperWakeTransaction(
        oneShot: "08/01/26 06:30:00",
        repeatDays: nil,
        repeatTime: nil,
        phase: .applied
    )
    let state = FakeMarkerState([.wakeClearPending], wakeTransaction: transaction)
    state.failClears = true
    let engine = HelperEngine(runner: runner, state: state)

    engine.restoreAtLaunch()
    #expect(runner.commands.isEmpty)
    #expect(state.markers().contains(.wakeClearPending))
    state.failClears = false
    engine.wakeTick()
    #expect(runner.commands.isEmpty)
    #expect(state.markers().isEmpty)
}

@Test func wakeRecoveryTickCannotEraseAConcurrentSuccessfulInstall() {
    let runner = BlockingWakeRunner()
    let state = FakeMarkerState()
    let engine = HelperEngine(runner: runner, state: state)
    let applyFinished = DispatchSemaphore(value: 0)
    let tickStarted = DispatchSemaphore(value: 0)
    let tickFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        _ = engine.applyWakeSchedule(
            oneShot: "08/01/26 06:30:00", repeatDays: nil, repeatTime: nil
        )
        applyFinished.signal()
    }
    #expect(runner.installStarted.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
        tickStarted.signal()
        engine.wakeTick()
        tickFinished.signal()
    }
    #expect(tickStarted.wait(timeout: .now() + 2) == .success)
    runner.allowInstall.signal()
    #expect(applyFinished.wait(timeout: .now() + 2) == .success)
    #expect(tickFinished.wait(timeout: .now() + 2) == .success)

    #expect(runner.commands.filter { $0.contains("cancelall") }.count == 1)
    #expect(runner.commands.last?.contains("schedule wake") == true)
    #expect(!state.markers().contains(.wakeClearPending))
}

// MARK: - Fakes

private final class RecordingRunner: HelperCommandRunning, @unchecked Sendable {
    private(set) var commands: [String] = []
    var failAll = false
    /// When set, only commands containing this substring fail.
    var failMatching: String?
    func run(_ path: String, _ arguments: [String]) -> Bool {
        let command = ([path] + arguments).joined(separator: " ")
        commands.append(command)
        if failAll { return false }
        if let failMatching, command.contains(failMatching) { return false }
        return true
    }
}

private final class BlockingWakeRunner: HelperCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommands: [String] = []
    let installStarted = DispatchSemaphore(value: 0)
    let allowInstall = DispatchSemaphore(value: 0)

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedCommands
    }

    func run(_ path: String, _ arguments: [String]) -> Bool {
        let command = ([path] + arguments).joined(separator: " ")
        lock.lock()
        storedCommands.append(command)
        lock.unlock()
        if command.contains("schedule wake") {
            installStarted.signal()
            allowInstall.wait()
        }
        return true
    }
}

private final class FakeMarkerState: HelperWakeTransactionPersisting, @unchecked Sendable {
    private var stored: Set<HelperRestoreMarker>
    private var storedWakeTransaction: HelperWakeTransaction?
    var failWrites = false
    var failClears = false
    var failMarkerWrites = false
    var failAppliedWrites = false
    init(
        _ initial: Set<HelperRestoreMarker> = [],
        wakeTransaction: HelperWakeTransaction? = nil
    ) {
        stored = initial
        storedWakeTransaction = wakeTransaction
    }
    func markers() -> Set<HelperRestoreMarker> { stored }
    @discardableResult
    func set(_ marker: HelperRestoreMarker, present: Bool) -> Bool {
        guard !failWrites,
              !failMarkerWrites,
              !(!present && failClears)
        else { return false }
        if present { stored.insert(marker) } else { stored.remove(marker) }
        return true
    }

    func wakeTransaction() -> HelperWakeTransaction? { storedWakeTransaction }

    @discardableResult
    func setWakeTransaction(_ transaction: HelperWakeTransaction?) -> Bool {
        guard !failWrites,
              !(transaction?.phase == .applied && failAppliedWrites)
        else { return false }
        storedWakeTransaction = transaction
        return true
    }
}
