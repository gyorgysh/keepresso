import Testing
import Foundation
@testable import KeepressoCore

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func claude(_ key: String, _ cron: String, enabled: Bool = true) -> ScheduledAutomation {
    ScheduledAutomation(source: .claudeDesktop, key: key, name: key,
                        recurrence: .cron(CronExpression(cron)!), enabled: enabled)
}

@Test func wakePlanMergesSourcesAndSortsByWakeTime() {
    let cal = utc()
    let morning = claude("morning", "0 9 * * *")
    let evening = claude("evening", "0 17 * * *")
    let occ = AutomationWakePlan.upcomingOccurrences(
        [evening, morning], after: at(2026, 1, 1, 0, 0, cal),
        within: 2 * 86400, leadTime: 300, perAutomation: 3, calendar: cal)

    #expect(occ.map(\.runTime) == [
        at(2026, 1, 1, 9, 0, cal), at(2026, 1, 1, 17, 0, cal),
        at(2026, 1, 2, 9, 0, cal), at(2026, 1, 2, 17, 0, cal),
    ])
    // Wake is exactly the lead time before each run.
    #expect(occ.allSatisfy { $0.wakeTime == $0.runTime.addingTimeInterval(-300) })
}

@Test func wakePlanExcludesDisabledAutomations() {
    let cal = utc()
    let on = claude("on", "0 9 * * *")
    let off = claude("off", "0 10 * * *", enabled: false)
    let occ = AutomationWakePlan.upcomingOccurrences(
        [on, off], after: at(2026, 1, 1, 0, 0, cal),
        within: 86400, leadTime: 0, perAutomation: 3, calendar: cal)
    #expect(occ.allSatisfy { $0.automationID == "claude:on" })
    #expect(!occ.isEmpty)
}

@Test func wakePlanCapsEachAutomationsRuns() {
    let cal = utc()
    let frequent = claude("frequent", "*/15 * * * *")
    let occ = AutomationWakePlan.upcomingOccurrences(
        [frequent], after: at(2026, 1, 1, 10, 7, cal),
        within: 86400, leadTime: 0, perAutomation: 2, calendar: cal)
    #expect(occ.map(\.runTime) == [at(2026, 1, 1, 10, 15, cal), at(2026, 1, 1, 10, 30, cal)])
}

@Test func wakePlanRespectsTheHorizon() {
    let cal = utc()
    let daily = claude("daily", "0 9 * * *")
    // Only twelve hours ahead: the first run is inside it, the next day's isn't.
    let occ = AutomationWakePlan.upcomingOccurrences(
        [daily], after: at(2026, 1, 1, 0, 0, cal),
        within: 12 * 3600, leadTime: 0, perAutomation: 3, calendar: cal)
    #expect(occ.map(\.runTime) == [at(2026, 1, 1, 9, 0, cal)])
}
