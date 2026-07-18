import Foundation
import Testing
@testable import KeepressoCore

private final class FakeAutomationFiles: CodexAutomationFileReading, @unchecked Sendable {
    var contents: [URL: String]
    var listingError = false
    var unreadable: Set<URL> = []

    init(contents: [URL: String]) {
        self.contents = contents
    }

    func automationFiles(in root: URL) throws -> [URL] {
        if listingError { throw CocoaError(.fileReadUnknown) }
        return contents.keys.sorted { $0.path < $1.path }
    }

    func readAutomationFile(at url: URL) throws -> String {
        if unreadable.contains(url) { throw CocoaError(.fileReadUnknown) }
        return contents[url]!
    }
}

private func automationURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/synthetic/automations/\(name)/automation.toml")
}

private func automationTOML(
    id: String,
    name: String,
    status: String = "ACTIVE",
    environment: String = "local",
    projectID: String = "local-project",
    rrule: String = "FREQ=DAILY;BYHOUR=9;BYMINUTE=30",
    extra: String = ""
) -> String {
    """
    version = 1
    id = "\(id)"
    name = "\(name)"
    prompt = \"\"\"
    Synthetic multiline task input.
    id = "must-not-escape-prompt"
    status = "ACTIVE"
    rrule = "FREQ=MINUTELY"
    \"\"\"
    status = "\(status)"
    rrule = "\(rrule)"
    cwds = ["/tmp/one", "/tmp/two"]
    execution_environment = "\(environment)"
    target = { type = "project", project_id = "\(projectID)" }
    created_at = 1784512800000
    \(extra)
    """
}

@Test func discoveryProjectsOnlySafeActiveLocalMetadata() throws {
    let local = automationURL("local")
    let worktree = automationURL("worktree")
    let paused = automationURL("paused")
    let cloud = automationURL("cloud")
    let remoteTarget = automationURL("remote-target")
    let files = FakeAutomationFiles(contents: [
        local: automationTOML(id: "local-id", name: "Local"),
        worktree: automationTOML(id: "worktree-id", name: "Worktree", environment: "worktree"),
        paused: automationTOML(id: "paused-id", name: "Paused", status: "PAUSED"),
        cloud: automationTOML(id: "cloud-id", name: "Cloud", environment: "cloud"),
        remoteTarget: automationTOML(id: "remote-id", name: "Remote", projectID: "remote-project"),
    ])

    let result = CodexAutomationDiscovery(
        root: URL(fileURLWithPath: "/synthetic/automations"),
        files: files
    ).discover()

    #expect(result.automations.map(\.id) == ["local-id", "worktree-id"])
    #expect(result.automations[0].workingDirectories == ["/tmp/one", "/tmp/two"])
    #expect(result.automations[0].executionEnvironment == "local")
    #expect(result.automations[1].executionEnvironment == "worktree")
    #expect(result.automations.allSatisfy { $0.target.projectID?.hasPrefix("local-") == true })
    #expect(result.automations.contains { $0.id == "must-not-escape-prompt" } == false)
    #expect(result.issues.isEmpty)
}

@Test func discoveryReportsOnlyNonSensitiveFailureKinds() {
    let malformed = automationURL("malformed")
    let unreadable = automationURL("unreadable")
    let files = FakeAutomationFiles(contents: [
        malformed: """
        name = "Missing ID"
        status = "ACTIVE"
        rrule = "FREQ=DAILY;BYHOUR=9"
        execution_environment = "local"
        target = { type = "project", project_id = "local-test" }
        prompt = "sensitive synthetic input"
        """,
        unreadable: automationTOML(id: "unreadable", name: "Unreadable"),
    ])
    files.unreadable = [unreadable]

    let result = CodexAutomationDiscovery(
        root: URL(fileURLWithPath: "/synthetic/automations"),
        files: files
    ).discover()

    #expect(result.automations.isEmpty)
    #expect(result.issues == [
        CodexAutomationDiscoveryIssue(sourceURL: malformed, reason: .missingField("id")),
        CodexAutomationDiscoveryIssue(sourceURL: unreadable, reason: .fileUnreadable),
    ])
}

@Test func discoveryHandlesUnreadableRootWithoutThrowing() {
    let files = FakeAutomationFiles(contents: [:])
    files.listingError = true
    let root = URL(fileURLWithPath: "/synthetic/automations")
    let result = CodexAutomationDiscovery(root: root, files: files).discover()
    #expect(result.automations.isEmpty)
    #expect(result.issues == [CodexAutomationDiscoveryIssue(sourceURL: root, reason: .rootUnreadable)])
}

@Test func defaultAutomationRootHonorsCodexHome() {
    let explicit = CodexAutomationDiscovery.defaultRoot(
        environment: ["CODEX_HOME": "/tmp/codex-home"],
        homeDirectory: URL(fileURLWithPath: "/Users/test")
    )
    #expect(explicit.path == "/tmp/codex-home/automations")

    let fallback = CodexAutomationDiscovery.defaultRoot(
        environment: [:],
        homeDirectory: URL(fileURLWithPath: "/Users/test")
    )
    #expect(fallback.path == "/Users/test/.codex/automations")
}

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    return calendar
}

private func utc(
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    _ second: Int = 0,
    year: Int = 2026,
    month: Int = 7
) -> Date {
    utcCalendar.date(from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
    ))!
}

@Test func minutelyRuleHonorsIntervalAndMinuteFilter() throws {
    let rule = try CodexRecurrenceRule("FREQ=MINUTELY;INTERVAL=15;BYMINUTE=0,30")
    let next = rule.next(
        after: utc(20, 10, 16),
        anchor: utc(20, 10, 0),
        calendar: utcCalendar
    )
    #expect(next == utc(20, 10, 30))
}

@Test func hourlyRuleHonorsIntervalAndByMinute() throws {
    let rule = try CodexRecurrenceRule("FREQ=HOURLY;INTERVAL=2;BYMINUTE=20")
    let next = rule.next(
        after: utc(20, 9, 30),
        anchor: utc(20, 8, 5),
        calendar: utcCalendar
    )
    #expect(next == utc(20, 10, 20))
}

@Test func dailyRuleIsStrictlyAfterInput() throws {
    let rule = try CodexRecurrenceRule("FREQ=DAILY;BYHOUR=9;BYMINUTE=30")
    let next = rule.next(
        after: utc(20, 9, 30),
        anchor: utc(1, 0, 0),
        calendar: utcCalendar
    )
    #expect(next == utc(21, 9, 30))
}

@Test func weeklyRuleHonorsByDayHourAndMinute() throws {
    let rule = try CodexRecurrenceRule("FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=7;BYMINUTE=15")
    let next = rule.next(
        after: utc(20, 8, 0),
        anchor: utc(20, 6, 0),
        calendar: utcCalendar
    )
    #expect(next == utc(22, 7, 15))
}

@Test func invalidOrUnsupportedRulesAreRejected() {
    #expect(throws: CodexRecurrenceRule.ParseError.unsupportedFrequency) {
        try CodexRecurrenceRule("FREQ=MONTHLY")
    }
    #expect(throws: CodexRecurrenceRule.ParseError.invalidHour) {
        try CodexRecurrenceRule("FREQ=DAILY;BYHOUR=25")
    }
    #expect(throws: CodexRecurrenceRule.ParseError.unsupportedPart("COUNT")) {
        try CodexRecurrenceRule("FREQ=DAILY;COUNT=2")
    }
}

@Test func wakePlannerUsesNearestRunAndDefaultFiveMinuteLead() throws {
    let source = URL(fileURLWithPath: "/synthetic/automation.toml")
    let later = CodexAutomation(
        id: "later",
        name: "Later",
        rrule: "FREQ=DAILY;BYHOUR=12;BYMINUTE=0",
        recurrence: try CodexRecurrenceRule("FREQ=DAILY;BYHOUR=12;BYMINUTE=0"),
        createdAt: utc(1, 0, 0),
        sourceURL: source
    )
    let nearest = CodexAutomation(
        id: "nearest",
        name: "Nearest",
        rrule: "FREQ=DAILY;BYHOUR=11;BYMINUTE=0",
        recurrence: try CodexRecurrenceRule("FREQ=DAILY;BYHOUR=11;BYMINUTE=0"),
        workingDirectories: ["/tmp/project"],
        createdAt: utc(1, 0, 0),
        sourceURL: source
    )
    let planner = CodexAutomationWakePlanner()
    let planning = planner.plan(
        for: [later, nearest],
        after: utc(20, 10, 0),
        calendar: utcCalendar
    )
    let plan = planning.wakePlan

    #expect(planner.leadTime == 5 * 60)
    #expect(planning.queuedRuns.map(\.automationID) == ["nearest", "later"])
    #expect(planning.queuedRuns.map(\.scheduledRun) == [utc(20, 11, 0), utc(20, 12, 0)])
    #expect(plan?.automationID == "nearest")
    #expect(plan?.scheduledRun == utc(20, 11, 0))
    #expect(plan?.scheduledWake == utc(20, 10, 55))
    #expect(plan?.workingDirectories == ["/tmp/project"])

    let existing = WakeScheduleConfig(
        repeatingEnabled: true,
        repeatSecondsFromMidnight: 3 * 3600,
        repeatWeekdays: "MWF",
        startSessionOnWake: true
    )
    let updated = planner.updating(existing, with: plan)
    #expect(updated.oneShot == plan?.scheduledWake)
    #expect(updated.repeatingEnabled)
    #expect(updated.repeatSecondsFromMidnight == 3 * 3600)
    #expect(updated.repeatWeekdays == "MWF")
    #expect(updated.startSessionOnWake)
}

@Test func wakePlannerRequestsImmediatePreparationInsideLeadWindow() throws {
    let source = URL(fileURLWithPath: "/synthetic/automation.toml")
    let automation = CodexAutomation(
        id: "near",
        name: "Near",
        rrule: "FREQ=DAILY;BYHOUR=11;BYMINUTE=0",
        recurrence: try CodexRecurrenceRule("FREQ=DAILY;BYHOUR=11;BYMINUTE=0"),
        createdAt: utc(1, 0, 0),
        sourceURL: source
    )
    let plan = CodexAutomationWakePlanner().nextPlan(
        for: [automation],
        after: utc(20, 10, 58),
        calendar: utcCalendar
    )
    #expect(plan?.scheduledRun == utc(20, 11, 0))
    #expect(plan?.desiredWake == utc(20, 10, 55))
    #expect(plan?.scheduledWake == nil)
    #expect(plan?.requiresImmediatePreparation == true)
}

@Test func consumedManualOneShotRevealsLaterCodexWake() {
    let manualWake = utc(20, 8, 0)
    let codexWake = utc(20, 9, 0)
    let manual = WakeScheduleConfig(
        oneShot: manualWake,
        repeatingEnabled: true,
        repeatSecondsFromMidnight: 3 * 3600,
        repeatWeekdays: "MWF"
    )

    let beforeManualWake = CodexWakeSchedulePolicy.effective(
        manual: manual,
        codexWake: codexWake,
        codexEnabled: true,
        at: utc(20, 7, 0)
    )
    #expect(beforeManualWake.oneShot == manualWake)

    let afterManualWake = CodexWakeSchedulePolicy.effective(
        manual: manual,
        codexWake: codexWake,
        codexEnabled: true,
        at: utc(20, 8, 1)
    )
    #expect(afterManualWake.oneShot == codexWake)
    #expect(afterManualWake.repeatingEnabled)
    #expect(afterManualWake.repeatSecondsFromMidnight == 3 * 3600)
    #expect(afterManualWake.repeatWeekdays == "MWF")

    let afterBothWakes = CodexWakeSchedulePolicy.effective(
        manual: manual,
        codexWake: codexWake,
        codexEnabled: true,
        at: utc(20, 9, 1)
    )
    #expect(afterBothWakes.oneShot == nil)
}

@Test func scheduledHandoffAcceptsOnlyCorrelatedCodexLeases() throws {
    let date = utc(20, 9, 0)
    let runs = [
        CodexAutomationQueuedRun(
            automationID: "automation-one",
            automationName: "One",
            scheduledRun: date,
            workingDirectories: []
        ),
        CodexAutomationQueuedRun(
            automationID: "automation-two",
            automationName: "Two",
            scheduledRun: date,
            workingDirectories: []
        ),
    ]
    let baselineID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let claudeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    let unrelatedCodexID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
    let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
    let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000005"))

    func lease(
        _ id: UUID,
        owner: String,
        agent: String,
        task: String? = nil,
        attributes: [String: String] = [:]
    ) -> AgentWakeLease {
        AgentWakeLease(
            id: id,
            metadata: AgentLeaseMetadata(
                owner: owner,
                agent: agent,
                task: task,
                attributes: attributes
            ),
            acquiredAt: date,
            heartbeatAt: date,
            expiresAt: date.addingTimeInterval(300),
            ttl: 300,
            maxLifetime: 3_600
        )
    }

    let claims = CodexLeaseHandoffPolicy.matchedClaims(
        runs: runs,
        leases: [
            lease(baselineID, owner: "automation-one", agent: "codex"),
            lease(claudeID, owner: "automation-one", agent: "claude-code"),
            lease(unrelatedCodexID, owner: "someone-else", agent: "codex"),
            lease(firstID, owner: "automation-one", agent: "codex"),
            lease(
                secondID,
                owner: "runner",
                agent: "openai-codex",
                attributes: ["automation_id": "automation-two"]
            ),
        ],
        excluding: [baselineID]
    )

    #expect(claims == [
        "automation-one": firstID,
        "automation-two": secondID,
    ])
}

@Test func oneLeaseCannotClaimTwoGroupedCodexRuns() throws {
    let date = utc(20, 9, 0)
    let leaseID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000006"))
    let lease = AgentWakeLease(
        id: leaseID,
        metadata: AgentLeaseMetadata(
            owner: "first",
            agent: "codex",
            task: "second"
        ),
        acquiredAt: date,
        heartbeatAt: date,
        expiresAt: date.addingTimeInterval(300),
        ttl: 300,
        maxLifetime: 3_600
    )
    let runs = ["first", "second"].map {
        CodexAutomationQueuedRun(
            automationID: $0,
            automationName: $0,
            scheduledRun: date,
            workingDirectories: []
        )
    }

    let claims = CodexLeaseHandoffPolicy.matchedClaims(
        runs: runs,
        leases: [lease],
        excluding: []
    )
    #expect(claims.count == 1)
    #expect(Set(claims.values) == [leaseID])
}
