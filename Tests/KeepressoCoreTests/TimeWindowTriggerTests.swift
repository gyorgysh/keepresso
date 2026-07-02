import Testing
import Foundation
@testable import KeepressoCore

/// A fixed calendar so the tests don't depend on the machine's locale/zone.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2026-07-03 is a Friday; offset days from there for other weekdays.
private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
}

private let friday = 3, saturday = 4, sunday = 5, monday = 6

private func evaluate(_ rule: TimeWindowRule, day: Int, hour: Int, minute: Int = 0) -> Bool {
    TimeWindowTrigger.evaluate(rule, at: date(day: day, hour: hour, minute: minute), calendar: utc)
}

// MARK: - Plain (non-wrapping) windows

@Test func insideWindowFires() {
    let nineToSix = TimeWindowRule(startMinutes: 9 * 60, endMinutes: 18 * 60)
    #expect(evaluate(nineToSix, day: friday, hour: 12))
}

@Test func outsideWindowDoesNotFire() {
    let nineToSix = TimeWindowRule(startMinutes: 9 * 60, endMinutes: 18 * 60)
    #expect(!evaluate(nineToSix, day: friday, hour: 8, minute: 59))
    #expect(!evaluate(nineToSix, day: friday, hour: 20))
}

@Test func startIsInclusiveEndIsExclusive() {
    let nineToSix = TimeWindowRule(startMinutes: 9 * 60, endMinutes: 18 * 60)
    #expect(evaluate(nineToSix, day: friday, hour: 9, minute: 0))
    #expect(!evaluate(nineToSix, day: friday, hour: 18, minute: 0))
    #expect(evaluate(nineToSix, day: friday, hour: 17, minute: 59))
}

// MARK: - Weekday filtering

@Test func emptyWeekdaysMeansEveryDay() {
    let rule = TimeWindowRule(startMinutes: 0, endMinutes: 23 * 60)
    #expect(evaluate(rule, day: saturday, hour: 12))
    #expect(evaluate(rule, day: monday, hour: 12))
}

@Test func weekdayFilterExcludesOtherDays() {
    // Weekdays in Calendar numbering: Mon=2 … Fri=6.
    let workHours = TimeWindowRule(startMinutes: 9 * 60, endMinutes: 18 * 60, weekdays: [2, 3, 4, 5, 6])
    #expect(evaluate(workHours, day: friday, hour: 12))
    #expect(!evaluate(workHours, day: saturday, hour: 12))
    #expect(!evaluate(workHours, day: sunday, hour: 12))
}

// MARK: - Windows wrapping past midnight

@Test func wrappedWindowCoversBothSidesOfMidnight() {
    let overnight = TimeWindowRule(startMinutes: 22 * 60, endMinutes: 6 * 60)
    #expect(evaluate(overnight, day: friday, hour: 23))
    #expect(evaluate(overnight, day: saturday, hour: 3))
    #expect(!evaluate(overnight, day: saturday, hour: 12))
    #expect(!evaluate(overnight, day: saturday, hour: 6, minute: 0)) // end exclusive
}

@Test func wrappedWindowMorningBelongsToTheStartDay() {
    // A Friday-only overnight window still covers Saturday 3:00 (it started
    // Friday), but not Sunday 3:00 (Saturday isn't a start day).
    let fridayNight = TimeWindowRule(startMinutes: 22 * 60, endMinutes: 6 * 60, weekdays: [6])
    #expect(evaluate(fridayNight, day: friday, hour: 23))
    #expect(evaluate(fridayNight, day: saturday, hour: 3))
    #expect(!evaluate(fridayNight, day: sunday, hour: 3))
    #expect(!evaluate(fridayNight, day: saturday, hour: 23))
}

@Test func sundayMorningWrapsBackToSaturday() {
    // Yesterday-of-Sunday must compute as Saturday (7), not weekday 0.
    let saturdayNight = TimeWindowRule(startMinutes: 22 * 60, endMinutes: 6 * 60, weekdays: [7])
    #expect(evaluate(saturdayNight, day: sunday, hour: 2))
}

@Test func equalStartAndEndReadsAsFullDay() {
    let allDay = TimeWindowRule(startMinutes: 9 * 60, endMinutes: 9 * 60, weekdays: [6])
    #expect(evaluate(allDay, day: friday, hour: 9))
    #expect(evaluate(allDay, day: friday, hour: 23, minute: 59))
    #expect(evaluate(allDay, day: saturday, hour: 8, minute: 59)) // morning tail of Friday's window
}

// MARK: - Trigger plumbing and labels

@MainActor
@Test func triggerReadsTheInjectedClock() {
    var current = date(day: friday, hour: 12)
    let trigger = TimeWindowTrigger(
        rule: TimeWindowRule(startMinutes: 9 * 60, endMinutes: 18 * 60),
        now: { current },
        calendar: utc
    )
    #expect(trigger.isSatisfied())
    current = date(day: friday, hour: 20)
    #expect(!trigger.isSatisfied())
}

@Test func labelsSummarizeDaysAndTimes() {
    #expect(TimeWindowRule(startMinutes: 540, endMinutes: 1080, weekdays: [2, 3, 4, 5, 6]).label == "Weekdays 9:00-18:00")
    #expect(TimeWindowRule(startMinutes: 22 * 60, endMinutes: 6 * 60).label == "Every day 22:00-6:00")
    #expect(TimeWindowRule(startMinutes: 600, endMinutes: 840, weekdays: [1, 7]).label == "Weekends 10:00-14:00")
    #expect(TimeWindowRule(startMinutes: 600, endMinutes: 845, weekdays: [2, 4]).label == "Mon, Wed 10:00-14:05")
}

@Test func timeWindowRuleRoundTripsThroughCodable() throws {
    let rule = TriggerRule.timeWindow(TimeWindowRule(startMinutes: 540, endMinutes: 1080, weekdays: [2, 6]))
    let data = try JSONEncoder().encode([rule])
    let decoded = try JSONDecoder().decode([TriggerRule].self, from: data)
    #expect(decoded == [rule])
}
