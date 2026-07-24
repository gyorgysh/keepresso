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

private func reader(_ tomls: String...) -> CodexAutomationsReader {
    CodexAutomationsReader { tomls }
}

// The exact shape Codex writes, inline table and array included.
private let weeklyReviewTOML = """
version = 1
id = "weekly-review"
kind = "cron"
name = "Weekly review"
prompt = "Review what I worked on this week and draft a short status update."
status = "ACTIVE"
rrule = "RRULE:FREQ=WEEKLY;BYHOUR=16;BYMINUTE=0;BYDAY=FR"
model = "gpt-5.5"
reasoning_effort = "low"
execution_environment = "local"
target = { type = "projectless" }
cwds = ["~"]
created_at = 1784889527597
updated_at = 1784889527597
"""

@Test func codexReaderParsesTheRealAutomationToml() {
    let all = reader(weeklyReviewTOML).automations()
    #expect(all.count == 1)
    let a = all[0]
    #expect(a.source == .codex)
    #expect(a.key == "weekly-review")
    #expect(a.name == "Weekly review")   // the real name, not derived from the id
    #expect(a.enabled)
    #expect(a.id == "codex:weekly-review")
    let cal = utc()
    #expect(a.recurrence.nextOccurrences(after: at(2026, 1, 1, 0, 0, cal), count: 1, calendar: cal)
            == [at(2026, 1, 2, 16, 0, cal)])
}

@Test func codexReaderSkipsCloudAutomations() {
    let cloud = """
    id = "nightly"
    name = "Nightly"
    status = "ACTIVE"
    rrule = "RRULE:FREQ=DAILY;BYHOUR=2;BYMINUTE=0"
    execution_environment = "cloud"
    """
    #expect(reader(cloud).automations().isEmpty)
}

@Test func codexReaderMarksPausedAutomationsDisabled() {
    let paused = """
    id = "audit"
    name = "Audit"
    status = "PAUSED"
    rrule = "RRULE:FREQ=DAILY;BYHOUR=3;BYMINUTE=0"
    execution_environment = "local"
    """
    let a = reader(paused).automations()
    #expect(a.count == 1)
    #expect(a[0].enabled == false)
}

@Test func codexReaderSkipsAutomationsWithoutAParseableSchedule() {
    let noRule = """
    id = "manual"
    name = "Manual"
    status = "ACTIVE"
    execution_environment = "local"
    """
    #expect(reader(noRule).automations().isEmpty)
}

@Test func codexTOMLParserReadsScalarsAndIgnoresTablesAndArrays() {
    let fields = CodexAutomationsReader.parseTOML(weeklyReviewTOML)
    #expect(fields["id"] == "weekly-review")
    #expect(fields["name"] == "Weekly review")
    #expect(fields["execution_environment"] == "local")
    #expect(fields["rrule"] == "RRULE:FREQ=WEEKLY;BYHOUR=16;BYMINUTE=0;BYDAY=FR")
    // The inline table and array are skipped, not mis-parsed.
    #expect(fields["target"] == nil)
    #expect(fields["cwds"] == nil)
}
