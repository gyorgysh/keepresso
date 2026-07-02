import Testing
import Foundation
@testable import KeepressoCore

@Test func parsesStartWithoutDuration() {
    let url = URL(string: "keepresso://start")!
    #expect(URLCommand.parse(url) == .start(mode: .indefinite))
}

@Test func parsesStartWithDurationInMinutes() {
    let url = URL(string: "keepresso://start?duration=60")!
    #expect(URLCommand.parse(url) == .start(mode: .timed(duration: 3600)))
}

@Test func parsesStop() {
    let url = URL(string: "keepresso://stop")!
    #expect(URLCommand.parse(url) == .stop)
}

@Test func parsesToggle() {
    let url = URL(string: "keepresso://toggle")!
    #expect(URLCommand.parse(url) == .toggle)
}

@Test func rejectsWrongScheme() {
    let url = URL(string: "https://start")!
    #expect(URLCommand.parse(url) == nil)
}

@Test func rejectsUnknownHost() {
    let url = URL(string: "keepresso://pause")!
    #expect(URLCommand.parse(url) == nil)
}

@Test func rejectsNonPositiveDuration() {
    let url = URL(string: "keepresso://start?duration=0")!
    #expect(URLCommand.parse(url) == nil)
}

@Test func rejectsUnparseableDuration() {
    let url = URL(string: "keepresso://start?duration=abc")!
    #expect(URLCommand.parse(url) == nil)
}

// MARK: - until=HH:MM

/// Fixed clock for `until` tests: 2026-07-03 12:00 UTC.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let noon = utc.date(from: DateComponents(year: 2026, month: 7, day: 3, hour: 12))!

@Test func parsesUntilLaterToday() {
    let url = URL(string: "keepresso://start?until=18:00")!
    #expect(URLCommand.parse(url, now: noon, calendar: utc) == .start(mode: .timed(duration: 6 * 3600)))
}

@Test func untilAPassedTimeMeansTomorrow() {
    let url = URL(string: "keepresso://start?until=9:30")!
    #expect(URLCommand.parse(url, now: noon, calendar: utc) == .start(mode: .timed(duration: 21.5 * 3600)))
}

@Test func untilTheCurrentTimeMeansAFullDay() {
    let url = URL(string: "keepresso://start?until=12:00")!
    #expect(URLCommand.parse(url, now: noon, calendar: utc) == .start(mode: .timed(duration: 24 * 3600)))
}

@Test func durationWinsOverUntil() {
    let url = URL(string: "keepresso://start?duration=60&until=18:00")!
    #expect(URLCommand.parse(url, now: noon, calendar: utc) == .start(mode: .timed(duration: 3600)))
}

@Test func rejectsMalformedUntil() {
    for bad in ["until=25:00", "until=12:60", "until=noon", "until=12", "until=1:2:3"] {
        let url = URL(string: "keepresso://start?\(bad)")!
        #expect(URLCommand.parse(url, now: noon, calendar: utc) == nil, "\(bad) should be rejected")
    }
}

@Test func sessionModeUntilRejectsOutOfRange() {
    #expect(SessionMode.until(hour: 24, minute: 0, now: noon, calendar: utc) == nil)
    #expect(SessionMode.until(hour: -1, minute: 0, now: noon, calendar: utc) == nil)
    #expect(SessionMode.until(hour: 12, minute: 60, now: noon, calendar: utc) == nil)
}
