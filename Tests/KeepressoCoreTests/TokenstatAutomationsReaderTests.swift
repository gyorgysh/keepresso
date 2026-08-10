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

private func reader(_ json: String) -> TokenstatAutomationsReader {
    let data = Data(json.utf8)
    return TokenstatAutomationsReader { data }
}

// The exact shape tokenstat-host writes for a daily job.
private let dailyBriefJSON = """
{ "jobs": [
    { "id": "automation-1786386302990",
      "name": "Daily brief",
      "backend": "claude",
      "model": null,
      "effort": null,
      "workspaceId": "/Users/x/proj",
      "prompt": "Summarise yesterday's usage and flag anything that needs attention.",
      "schedule": {
        "kind": "daily",
        "everySeconds": 0,
        "hour": 8,
        "minute": 0,
        "weekday": 0
      },
      "budgetSeconds": 600,
      "enabled": true,
      "lastRunAtMs": null,
      "nextRunAtMs": 1786428000000,
      "lastRunId": null }
  ] }
"""

@Test func tokenstatReaderParsesTheRealAutomationsFile() {
    let all = reader(dailyBriefJSON).automations()
    #expect(all.count == 1)
    let a = all[0]
    #expect(a.source == .tokenstat)
    #expect(a.key == "automation-1786386302990")
    #expect(a.name == "Daily brief")
    #expect(a.enabled)
    #expect(a.id == "tokenstat:automation-1786386302990")
    // Daily at 08:00 local (UTC in this test calendar).
    let cal = utc()
    #expect(a.recurrence.nextOccurrences(after: at(2026, 1, 1, 0, 0, cal), count: 1, calendar: cal)
            == [at(2026, 1, 1, 8, 0, cal)])
}

@Test func tokenstatReaderSkipsOnceJobs() {
    let json = """
    { "jobs": [
        { "id": "manual", "name": "Manual", "enabled": true,
          "schedule": { "kind": "once", "everySeconds": 0, "hour": 0, "minute": 0, "weekday": 0 } }
      ] }
    """
    #expect(reader(json).automations().isEmpty)
}

@Test func tokenstatReaderSurfacesDisabledJobs() {
    let json = """
    { "jobs": [
        { "id": "paused", "name": "Paused", "enabled": false,
          "schedule": { "kind": "daily", "everySeconds": 0, "hour": 3, "minute": 0, "weekday": 0 } }
      ] }
    """
    let a = reader(json).automations()
    #expect(a.count == 1)
    #expect(a[0].enabled == false)
}

@Test func tokenstatReaderMapsWeeklyMondayZeroToCron() {
    // tokenstat weekday 0 = Monday → cron day-of-week 1.
    let json = """
    { "jobs": [
        { "id": "standup", "name": "Standup", "enabled": true,
          "schedule": { "kind": "weekly", "everySeconds": 0, "hour": 9, "minute": 30, "weekday": 0 } }
      ] }
    """
    let a = reader(json).automations()[0]
    let cal = utc()
    // 2026-01-01 is Thursday; next Monday is 2026-01-05.
    #expect(a.recurrence.nextOccurrences(after: at(2026, 1, 1, 0, 0, cal), count: 1, calendar: cal)
            == [at(2026, 1, 5, 9, 30, cal)])
}

@Test func tokenstatReaderProjectsIntervalFromNextRun() {
    // nextRunAtMs = 2026-01-01 10:00:00 UTC
    let anchorMs: Int64 = 1_767_261_600_000
    let json = """
    { "jobs": [
        { "id": "tick", "name": "Tick", "enabled": true,
          "nextRunAtMs": \(anchorMs),
          "schedule": { "kind": "interval", "everySeconds": 3600, "hour": 0, "minute": 0, "weekday": 0 } }
      ] }
    """
    let a = reader(json).automations()[0]
    let cal = utc()
    let after = at(2026, 1, 1, 9, 0, cal)
    #expect(a.recurrence.nextOccurrences(after: after, count: 3, calendar: cal) == [
        at(2026, 1, 1, 10, 0, cal),
        at(2026, 1, 1, 11, 0, cal),
        at(2026, 1, 1, 12, 0, cal),
    ])
}

@Test func tokenstatReaderSkipsIntervalShorterThanAMinute() {
    let json = """
    { "jobs": [
        { "id": "too-fast", "name": "Too fast", "enabled": true,
          "schedule": { "kind": "interval", "everySeconds": 30, "hour": 0, "minute": 0, "weekday": 0 } }
      ] }
    """
    #expect(reader(json).automations().isEmpty)
}

@Test func tokenstatReaderMapsWeekdaysToMonFriCron() {
    let json = """
    { "jobs": [
        { "id": "standup", "name": "Standup", "enabled": true,
          "schedule": { "kind": "weekdays", "everySeconds": 0, "hour": 9, "minute": 0, "weekday": 0, "weekdays": 31 } }
      ] }
    """
    let a = reader(json).automations()[0]
    #expect(a.source == .tokenstat)
    let cal = utc()
    // 2026-01-01 is Thursday; next Mon-Fri at 09:00 is that same day.
    #expect(a.recurrence.nextOccurrences(after: at(2026, 1, 1, 0, 0, cal), count: 1, calendar: cal)
            == [at(2026, 1, 1, 9, 0, cal)])
    // After Friday 09:00, the next is Monday.
    #expect(a.recurrence.nextOccurrences(after: at(2026, 1, 2, 10, 0, cal), count: 1, calendar: cal)
            == [at(2026, 1, 5, 9, 0, cal)])
}

@Test func tokenstatReaderMapsCustomDayBitset() {
    // Tuesday (bit 1) and Thursday (bit 3) only → mask 10.
    let json = """
    { "jobs": [
        { "id": "pair", "name": "Pair", "enabled": true,
          "schedule": { "kind": "custom", "everySeconds": 0, "hour": 14, "minute": 0, "weekday": 0, "weekdays": 10 } }
      ] }
    """
    let a = reader(json).automations()[0]
    let cal = utc()
    // 2026-01-01 Thursday → next is today 14:00, then Tuesday 6th.
    #expect(a.recurrence.nextOccurrences(after: at(2026, 1, 1, 0, 0, cal), count: 2, calendar: cal) == [
        at(2026, 1, 1, 14, 0, cal),
        at(2026, 1, 6, 14, 0, cal),
    ])
}

@Test func tokenstatReaderMapsWeeklySundayToCronZero() {
    // tokenstat weekday 6 = Sunday → cron day-of-week 0.
    let json = """
    { "jobs": [
        { "id": "sunday", "name": "Sunday", "enabled": true,
          "schedule": { "kind": "weekly", "everySeconds": 0, "hour": 10, "minute": 0, "weekday": 6, "weekdays": 0 } }
      ] }
    """
    let a = reader(json).automations()[0]
    let cal = utc()
    // 2026-01-01 is Thursday; next Sunday is 2026-01-04.
    #expect(a.recurrence.nextOccurrences(after: at(2026, 1, 1, 0, 0, cal), count: 1, calendar: cal)
            == [at(2026, 1, 4, 10, 0, cal)])
}

@Test func tokenstatReaderMapsWeeklyMultiDayBitset() {
    // Monday + Wednesday bits 0|2 = 5.
    let json = """
    { "jobs": [
        { "id": "mw", "name": "MW", "enabled": true,
          "schedule": { "kind": "weekly", "everySeconds": 0, "hour": 11, "minute": 0, "weekday": 0, "weekdays": 5 } }
      ] }
    """
    let a = reader(json).automations()[0]
    let cal = utc()
    // After Thursday 1 Jan: next is Monday 5th, then Wednesday 7th.
    #expect(a.recurrence.nextOccurrences(after: at(2026, 1, 1, 12, 0, cal), count: 2, calendar: cal) == [
        at(2026, 1, 5, 11, 0, cal),
        at(2026, 1, 7, 11, 0, cal),
    ])
}

@Test func tokenstatReaderSkipsEmptyCustomMask() {
    let json = """
    { "jobs": [
        { "id": "empty", "name": "Empty", "enabled": true,
          "schedule": { "kind": "custom", "everySeconds": 0, "hour": 9, "minute": 0, "weekday": 0, "weekdays": 0 } }
      ] }
    """
    #expect(reader(json).automations().isEmpty)
}

@Test func tokenstatReaderSkipsAMalformedJobButKeepsTheRest() {
    let json = """
    { "jobs": [
        { "id": null, "name": "bad", "enabled": true,
          "schedule": { "kind": "daily", "hour": 8, "minute": 0 } },
        { "id": "good", "name": "Good", "enabled": true,
          "schedule": { "kind": "daily", "everySeconds": 0, "hour": 8, "minute": 0, "weekday": 0 } }
      ] }
    """
    #expect(reader(json).automations().map(\.key) == ["good"])
}

@Test func tokenstatReaderIgnoresMalformedFiles() {
    let good = """
    { "jobs": [
        { "id": "ok", "name": "Ok", "enabled": true,
          "schedule": { "kind": "daily", "everySeconds": 0, "hour": 9, "minute": 0, "weekday": 0 } }
      ] }
    """
    #expect(reader("not json").automations().isEmpty)
    #expect(reader("{}").automations().isEmpty)
    #expect(reader(good).automations().map(\.key) == ["ok"])
}

@Test func intervalRecurrenceStepsPastTheAnchor() {
    let cal = utc()
    let anchor = at(2026, 1, 1, 10, 0, cal)
    let recurrence = Recurrence.interval(every: 3600, anchor: anchor)
    // After the first fire, the next two are still projected.
    #expect(recurrence.nextOccurrences(after: at(2026, 1, 1, 10, 30, cal), count: 2, calendar: cal) == [
        at(2026, 1, 1, 11, 0, cal),
        at(2026, 1, 1, 12, 0, cal),
    ])
}
