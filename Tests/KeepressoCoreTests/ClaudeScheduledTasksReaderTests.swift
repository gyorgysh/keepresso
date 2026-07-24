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

private func reader(_ manifests: String...) -> ClaudeScheduledTasksReader {
    let datas = manifests.map { Data($0.utf8) }
    return ClaudeScheduledTasksReader { datas }
}

@Test func claudeReaderParsesTheRealManifestShape() {
    // The exact shape Claude Desktop writes for a Local scheduled task.
    let json = """
    { "scheduledTasks": [
        { "id": "daily-brief", "cronExpression": "0 9 * * *", "enabled": true,
          "filePath": "/Users/x/.claude/scheduled-tasks/daily-brief/SKILL.md",
          "createdAt": 1784890295784, "cwd": "/Users/x/proj", "useWorktree": false }
      ], "recordedSkips": {} }
    """
    let all = reader(json).automations()
    #expect(all.count == 1)
    let a = all[0]
    #expect(a.source == .claudeDesktop)
    #expect(a.key == "daily-brief")
    #expect(a.name == "Daily Brief")   // title-cased from the kebab id
    #expect(a.enabled)
    #expect(a.id == "claude:daily-brief")
    // The recurrence really is the 09:00 daily cron.
    let cal = utc()
    #expect(a.recurrence.nextOccurrences(after: at(2026, 1, 1, 0, 0, cal), count: 1, calendar: cal)
            == [at(2026, 1, 1, 9, 0, cal)])
}

@Test func claudeReaderSurfacesDisabledTasks() {
    let json = #"{ "scheduledTasks": [ { "id": "audit", "cronExpression": "0 3 * * *", "enabled": false } ] }"#
    let a = reader(json).automations()
    #expect(a.count == 1)
    #expect(a[0].enabled == false)
}

@Test func claudeReaderSkipsManualTasksWithoutASchedule() {
    // A "Manual" (run-on-demand) task carries no cron: nothing to wake for.
    let missing = #"{ "scheduledTasks": [ { "id": "on-demand", "enabled": true } ] }"#
    let empty = #"{ "scheduledTasks": [ { "id": "on-demand", "cronExpression": "", "enabled": true } ] }"#
    #expect(reader(missing).automations().isEmpty)
    #expect(reader(empty).automations().isEmpty)
}

@Test func claudeReaderUnionsAcrossManifestsPreferringEnabled() {
    let disabled = #"{ "scheduledTasks": [ { "id": "sync", "cronExpression": "0 2 * * *", "enabled": false } ] }"#
    let enabled = #"{ "scheduledTasks": [ { "id": "sync", "cronExpression": "0 2 * * *", "enabled": true } ] }"#
    // Whichever order the two manifests are read, an enabled copy wins.
    #expect(reader(disabled, enabled).automations().first?.enabled == true)
    #expect(reader(enabled, disabled).automations().first?.enabled == true)
}

@Test func claudeReaderIgnoresMalformedManifests() {
    let good = #"{ "scheduledTasks": [ { "id": "ok", "cronExpression": "0 9 * * *", "enabled": true } ] }"#
    let all = reader("not json at all", good, "{}").automations()
    #expect(all.map(\.key) == ["ok"])
}
