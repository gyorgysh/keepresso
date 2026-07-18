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

@Test func schedParserExtractsOneShotWakes() {
    let text = """
    Scheduled power events:
     [0]  wake at 07/18/2026 14:32:09 by 'com.apple.alarm'
     [1]  wake at 07/19/26 04:20:00 by 'other'
    """
    let state = WakeScheduleParser.parse(text)
    #expect(state.scheduledWakes.count == 2)
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

@Test func failedClearLeavesPendingMarker() {
    let runner = RecordingRunner()
    runner.failAll = true
    let state = FakeMarkerState()
    let engine = HelperEngine(runner: runner, state: state)
    #expect(!engine.clearWakeSchedules())
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

// MARK: - Fakes

private final class RecordingRunner: HelperCommandRunning, @unchecked Sendable {
    private(set) var commands: [String] = []
    var failAll = false
    func run(_ path: String, _ arguments: [String]) -> Bool {
        commands.append(([path] + arguments).joined(separator: " "))
        return !failAll
    }
}

private final class FakeMarkerState: HelperRestoreStatePersisting, @unchecked Sendable {
    private var stored: Set<HelperRestoreMarker>
    init(_ initial: Set<HelperRestoreMarker> = []) { stored = initial }
    func markers() -> Set<HelperRestoreMarker> { stored }
    func set(_ marker: HelperRestoreMarker, present: Bool) {
        if present { stored.insert(marker) } else { stored.remove(marker) }
    }
}
