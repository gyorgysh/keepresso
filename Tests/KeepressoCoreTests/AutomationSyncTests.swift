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

@Test func syncActiveFiltersMutedDisabledAndRespectsMasterSwitch() {
    let all = [claude("on", "0 9 * * *"), claude("off", "0 9 * * *", enabled: false), claude("muted", "0 9 * * *")]
    var config = AutomationSyncConfig(enabled: true, enabledSources: [.claudeDesktop], mutedIDs: ["claude:muted"])
    #expect(AutomationSync.active(all, config: config).map(\.key) == ["on"])
    config.enabled = false
    #expect(AutomationSync.active(all, config: config).isEmpty)
    config.enabled = true
    config.enabledSources = []
    #expect(AutomationSync.active(all, config: config).isEmpty)
}

@Test func syncNextWakeIsLeadBeforeTheEarliestRun() {
    let cal = utc()
    let morning = claude("morning", "0 9 * * *")
    let dawn = claude("dawn", "0 6 * * *")
    let config = AutomationSyncConfig(enabled: true, enabledSources: [.claudeDesktop], leadSeconds: 180)
    #expect(AutomationSync.nextWake([morning, dawn], config: config, after: at(2026, 1, 1, 0, 0, cal), calendar: cal)
            == at(2026, 1, 1, 6, 0, cal).addingTimeInterval(-180))
}

@Test func syncNextWakeIsNilWhenDisabledOrEmpty() {
    let cal = utc()
    let morning = claude("morning", "0 9 * * *")
    #expect(AutomationSync.nextWake([morning], config: AutomationSyncConfig(enabled: false),
                                    after: at(2026, 1, 1, 0, 0, cal), calendar: cal) == nil)
    #expect(AutomationSync.nextWake([], config: AutomationSyncConfig(enabled: true),
                                    after: at(2026, 1, 1, 0, 0, cal), calendar: cal) == nil)
}

@Test func syncWakeMatchIdentifiesTheRunWeWokeFor() {
    let cal = utc()
    let morning = claude("morning", "0 9 * * *")
    let config = AutomationSyncConfig(enabled: true, enabledSources: [.claudeDesktop], leadSeconds: 180)
    let match = AutomationSync.wakeMatch([morning], config: config,
                                         wokeAt: at(2026, 1, 1, 8, 57, cal), calendar: cal)
    #expect(match?.automationID == "claude:morning")
    #expect(match?.runTime == at(2026, 1, 1, 9, 0, cal))
    #expect(AutomationSync.wakeMatch([morning], config: config,
                                     wokeAt: at(2026, 1, 1, 3, 0, cal), calendar: cal) == nil)
}

@Test func effectiveOneShotPrefersEarlierFutureAndDropsPastManual() {
    let cal = utc()
    let now = at(2026, 1, 1, 7, 0, cal)
    let manual = at(2026, 1, 1, 8, 0, cal)
    let auto = at(2026, 1, 1, 8, 57, cal)
    #expect(AutomationSync.effectiveOneShot(manual: manual, automationWake: auto, now: now) == manual)
    let after = at(2026, 1, 1, 8, 30, cal)
    #expect(AutomationSync.effectiveOneShot(manual: manual, automationWake: auto, now: after) == auto)
    #expect(AutomationSync.effectiveOneShot(manual: nil, automationWake: auto, now: now) == auto)
    #expect(AutomationSync.effectiveOneShot(manual: manual, automationWake: nil, now: now) == manual)
    #expect(AutomationSync.effectiveOneShot(manual: nil, automationWake: nil, now: now) == nil)
}

@Test func keepLastKnownRidesOutABriefEmptyReadThenGivesWay() {
    #expect(AutomationSync.shouldKeepLastKnown(newIsEmpty: true, hadAutomations: true, emptyStreak: 0, maxEmptyStreak: 2))
    #expect(AutomationSync.shouldKeepLastKnown(newIsEmpty: true, hadAutomations: true, emptyStreak: 1, maxEmptyStreak: 2))
    #expect(!AutomationSync.shouldKeepLastKnown(newIsEmpty: true, hadAutomations: true, emptyStreak: 2, maxEmptyStreak: 2))
    #expect(!AutomationSync.shouldKeepLastKnown(newIsEmpty: false, hadAutomations: true, emptyStreak: 0, maxEmptyStreak: 2))
    #expect(!AutomationSync.shouldKeepLastKnown(newIsEmpty: true, hadAutomations: false, emptyStreak: 0, maxEmptyStreak: 2))
}

@Test func syncConfigDecodesForgivingly() throws {
    let config = try JSONDecoder().decode(AutomationSyncConfig.self, from: Data("{}".utf8))
    #expect(config.enabled == false)
    #expect(config.enabledSources.isEmpty)
    #expect(config.holdSeconds == AutomationSyncConfig.defaultHold)
    #expect(config.leadSeconds == AutomationSyncConfig.defaultLead)
}

@Test func syncConfigDropsUnknownEnabledSourceInsteadOfThrowing() throws {
    let json = #"{"enabled":true,"enabledSources":["claude","source-from-the-future"],"holdSeconds":900}"#
    let config = try JSONDecoder().decode(AutomationSyncConfig.self, from: Data(json.utf8))
    #expect(config.enabled == true)
    #expect(config.enabledSources == [.claudeDesktop])
    #expect(config.holdSeconds == 900)
}

@Test func syncNextWakeSkipsAWakeAlreadyInsideItsLeadWindow() {
    let cal = utc()
    let morning = claude("morning", "0 9 * * *")
    let config = AutomationSyncConfig(enabled: true, enabledSources: [.claudeDesktop], leadSeconds: 180)
    let now = at(2026, 1, 1, 8, 58, cal)
    let next = AutomationSync.nextWake([morning], config: config, after: now, calendar: cal)
    #expect(next == at(2026, 1, 2, 9, 0, cal).addingTimeInterval(-180))
    #expect((next ?? .distantPast) > now)
}
