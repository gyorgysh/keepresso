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

@Test func rruleDailyAtAnHour() {
    let cal = utc()
    let rule = RecurrenceRule("FREQ=DAILY;BYHOUR=9;BYMINUTE=0")!
    #expect(rule.next(after: at(2026, 1, 1, 8, 0, cal), calendar: cal) == at(2026, 1, 1, 9, 0, cal))
    #expect(rule.next(after: at(2026, 1, 1, 9, 0, cal), calendar: cal) == at(2026, 1, 2, 9, 0, cal))
}

@Test func rruleWeeklyOnFridayAcceptsThePrefix() {
    let cal = utc()
    // The exact form Codex writes, RRULE: prefix and all.
    let rule = RecurrenceRule("RRULE:FREQ=WEEKLY;BYHOUR=16;BYMINUTE=0;BYDAY=FR")!
    #expect(rule.next(after: at(2026, 1, 1, 0, 0, cal), calendar: cal) == at(2026, 1, 2, 16, 0, cal))
    #expect(rule.next(after: at(2026, 1, 2, 16, 0, cal), calendar: cal) == at(2026, 1, 9, 16, 0, cal))
}

@Test func rruleWeekdaysSkipTheWeekend() {
    let cal = utc()
    let rule = RecurrenceRule("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0")!
    #expect(rule.next(after: at(2026, 1, 2, 10, 0, cal), calendar: cal) == at(2026, 1, 5, 9, 0, cal))
}

@Test func rruleHourlyDefaultsToEveryHourAtTheMinute() {
    let cal = utc()
    let rule = RecurrenceRule("FREQ=HOURLY;BYMINUTE=0")!
    #expect(rule.next(after: at(2026, 1, 1, 10, 7, cal), calendar: cal) == at(2026, 1, 1, 11, 0, cal))
}

@Test func rruleMonthlyOnADayOfMonth() {
    let cal = utc()
    let rule = RecurrenceRule("FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0")!
    #expect(rule.next(after: at(2026, 1, 15, 0, 0, cal), calendar: cal) == at(2026, 2, 1, 9, 0, cal))
}

@Test func rruleRequiresAFrequency() {
    #expect(RecurrenceRule("BYHOUR=9;BYMINUTE=0") == nil)
    #expect(RecurrenceRule("FREQ=DAILY;BYHOUR=9") != nil)
}
