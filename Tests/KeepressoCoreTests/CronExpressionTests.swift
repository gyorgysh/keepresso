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

@Test func cronDailyFiresAtTheHourAndIsStrictlyAfter() {
    let cal = utc()
    let cron = CronExpression("0 9 * * *")!
    #expect(cron.next(after: at(2026, 1, 1, 8, 0, cal), calendar: cal) == at(2026, 1, 1, 9, 0, cal))
    // Exactly on a fire time returns the NEXT day, never the same instant.
    #expect(cron.next(after: at(2026, 1, 1, 9, 0, cal), calendar: cal) == at(2026, 1, 2, 9, 0, cal))
    #expect(cron.next(after: at(2026, 1, 1, 9, 30, cal), calendar: cal) == at(2026, 1, 2, 9, 0, cal))
}

@Test func cronWeekdaysSkipTheWeekend() {
    let cal = utc()
    // 2026-01-02 is a Friday; Mon-Fri only.
    let cron = CronExpression("0 9 * * 1-5")!
    // After Friday's run, the next is Monday, not Saturday.
    #expect(cron.next(after: at(2026, 1, 2, 10, 0, cal), calendar: cal) == at(2026, 1, 5, 9, 0, cal))
}

@Test func cronWeeklyOnFriday() {
    let cal = utc()
    let cron = CronExpression("0 16 * * 5")!
    #expect(cron.next(after: at(2026, 1, 1, 0, 0, cal), calendar: cal) == at(2026, 1, 2, 16, 0, cal))
    #expect(cron.next(after: at(2026, 1, 2, 16, 0, cal), calendar: cal) == at(2026, 1, 9, 16, 0, cal))
}

@Test func cronStepMinutesAndHours() {
    let cal = utc()
    #expect(CronExpression("*/15 * * * *")!.next(after: at(2026, 1, 1, 10, 7, cal), calendar: cal)
            == at(2026, 1, 1, 10, 15, cal))
    // Every six hours -> 0,6,12,18.
    #expect(CronExpression("0 */6 * * *")!.next(after: at(2026, 1, 1, 1, 0, cal), calendar: cal)
            == at(2026, 1, 1, 6, 0, cal))
}

@Test func cronMonthlyOnTheFirst() {
    let cal = utc()
    let cron = CronExpression("0 9 1 * *")!
    #expect(cron.next(after: at(2026, 1, 15, 0, 0, cal), calendar: cal) == at(2026, 2, 1, 9, 0, cal))
}

@Test func cronDayOfMonthOrDayOfWeekIsAUnion() {
    let cal = utc()
    // The 13th OR any Friday, at midnight. From Jan 10 the 13th (a Tuesday)
    // comes before the next Friday (the 16th).
    let cron = CronExpression("0 0 13 * 5")!
    #expect(cron.next(after: at(2026, 1, 10, 0, 0, cal), calendar: cal) == at(2026, 1, 13, 0, 0, cal))
}

@Test func cronNextOccurrencesAreOrderedAndStrictlyIncreasing() {
    let cal = utc()
    let runs = CronExpression("0 9 * * *")!.nextOccurrences(after: at(2026, 1, 1, 0, 0, cal), count: 3, calendar: cal)
    #expect(runs == [at(2026, 1, 1, 9, 0, cal), at(2026, 1, 2, 9, 0, cal), at(2026, 1, 3, 9, 0, cal)])
}

@Test func cronRejectsMalformedExpressions() {
    #expect(CronExpression("bad") == nil)
    #expect(CronExpression("* * *") == nil)            // too few fields
    #expect(CronExpression("99 * * * *") == nil)       // minute out of range
    #expect(CronExpression("0 9 * * 8") == nil)        // day-of-week out of range
    #expect(CronExpression("0 9 * * *") != nil)        // a good one still parses
}

@Test func cronFiresAtLocalWallClockAcrossDaylightSaving() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    // US spring-forward is 2026-03-08 02:00 -> 03:00. A 09:00 daily run still
    // fires at 09:00 local on that day and the next, not shifted by the hour.
    let daily9 = CronExpression("0 9 * * *")!
    #expect(daily9.nextOccurrences(after: at(2026, 3, 7, 12, 0, cal), count: 2, calendar: cal)
            == [at(2026, 3, 8, 9, 0, cal), at(2026, 3, 9, 9, 0, cal)])
    // 02:30 doesn't exist on the transition day: skip to the next valid one,
    // no hang or crash.
    let at230 = CronExpression("30 2 * * *")!
    #expect(at230.next(after: at(2026, 3, 8, 0, 0, cal), calendar: cal)
            == at(2026, 3, 9, 2, 30, cal))
}

@Test func cronImpossibleExpressionTerminatesWithNil() {
    let cal = utc()
    // February 30th never happens: the search must give up, not spin forever.
    #expect(CronExpression("0 0 30 2 *")!.next(after: at(2026, 1, 1, 0, 0, cal), calendar: cal) == nil)
}
