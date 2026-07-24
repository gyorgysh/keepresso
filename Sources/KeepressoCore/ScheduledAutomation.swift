import Foundation

/// A recurring local automation that a scheduler (Claude Desktop, Codex, ...)
/// runs *on this Mac*, discovered so Keepresso can wake for it. Deliberately
/// carries only what a wake needs: identity, a display name, its recurrence, and
/// whether it is enabled. The task's prompt is never read or retained.
///
/// Only *local* automations belong here. Cloud routines run on the vendor's
/// servers whether the Mac is awake or not, so there is nothing to wake for and
/// they are never surfaced.
public struct ScheduledAutomation: Equatable, Sendable, Identifiable {
    /// Where the automation was discovered. The raw value is the stable prefix
    /// used in ``id`` and in any persisted per-automation setting.
    public enum Source: String, Codable, Sendable, CaseIterable {
        case claudeDesktop = "claude"
        case codex

        /// Human label for the source, for the "synced from" UI.
        public var label: String {
            switch self {
            case .claudeDesktop: return "Claude Desktop"
            case .codex:         return "Codex"
            }
        }
    }

    public var source: Source
    /// Identifier within the source (e.g. the task folder name). Unique per
    /// source, not necessarily across sources, hence the composite ``id``.
    public var key: String
    /// Display name, e.g. "Daily Brief".
    public var name: String
    /// When it runs.
    public var recurrence: Recurrence
    /// Whether the source has it enabled. A disabled automation is shown but not
    /// woken for.
    public var enabled: Bool

    /// Stable cross-source identity, e.g. `claude:daily-brief`.
    public var id: String { "\(source.rawValue):\(key)" }

    public init(source: Source, key: String, name: String, recurrence: Recurrence, enabled: Bool) {
        self.source = source
        self.key = key
        self.name = name
        self.recurrence = recurrence
        self.enabled = enabled
    }
}

/// How an automation recurs. A common surface over the per-source schedule
/// formats (Claude Desktop stores cron; Codex stores an iCal RRULE) so the wake
/// planner treats every source the same.
public enum Recurrence: Equatable, Sendable {
    case cron(CronExpression)
    case rrule(RecurrenceRule)

    /// The next `count` run times strictly after `date`, in order.
    public func nextOccurrences(after date: Date, count: Int, calendar: Calendar) -> [Date] {
        switch self {
        case .cron(let expression):
            return expression.nextOccurrences(after: date, count: count, calendar: calendar)
        case .rrule(let rule):
            return rule.nextOccurrences(after: date, count: count, calendar: calendar)
        }
    }
}

/// A source of locally-scheduled automations. One reader per scheduler; the app
/// unions several. Kept a protocol seam like ``PowerAsserting`` so the app wires
/// the real disk-reading implementation and tests inject fakes.
public protocol LocalAutomationReading: Sendable {
    /// The automations currently defined in the source. Best-effort and
    /// side-effect free: a missing or malformed store yields an empty list, not
    /// an error, so discovery never breaks the app.
    func automations() -> [ScheduledAutomation]
}

/// One upcoming run of an automation, with the moment to wake the Mac for it.
public struct AutomationOccurrence: Equatable, Sendable {
    public var automationID: String
    public var automationName: String
    public var source: ScheduledAutomation.Source
    /// When the automation is scheduled to run.
    public var runTime: Date
    /// When to wake the Mac: `runTime` minus the lead time, so the machine is up
    /// and settled before the run fires (schedulers also add their own stagger).
    public var wakeTime: Date

    public init(automationID: String, automationName: String, source: ScheduledAutomation.Source,
                runTime: Date, wakeTime: Date) {
        self.automationID = automationID
        self.automationName = automationName
        self.source = source
        self.runTime = runTime
        self.wakeTime = wakeTime
    }
}

/// Merges the recurrences of many automations into one sorted wake timeline.
/// Pure, so the arming layer (rolling one-shot `pmset` wakes) and the UI both
/// read from the same computed plan.
public enum AutomationWakePlan {
    /// Upcoming occurrences across the enabled automations, within `horizon`
    /// from `now`, sorted by wake time. Each automation contributes up to
    /// `perAutomation` runs so a frequent one can't crowd out the rest.
    ///
    /// `leadTime` is how early to wake before each run. macOS only fires a
    /// firmware wake to the minute and needs a moment to settle, and the
    /// schedulers stagger their own starts by a few minutes, so a lead of a few
    /// minutes keeps the Mac awake and ready when the run actually begins.
    public static func upcomingOccurrences(
        _ automations: [ScheduledAutomation],
        after now: Date,
        within horizon: TimeInterval,
        leadTime: TimeInterval,
        perAutomation: Int = 3,
        calendar: Calendar = .current
    ) -> [AutomationOccurrence] {
        let cutoff = now.addingTimeInterval(horizon)
        var occurrences: [AutomationOccurrence] = []
        for automation in automations where automation.enabled {
            for run in automation.recurrence.nextOccurrences(after: now, count: perAutomation, calendar: calendar) {
                guard run <= cutoff else { break }
                occurrences.append(AutomationOccurrence(
                    automationID: automation.id,
                    automationName: automation.name,
                    source: automation.source,
                    runTime: run,
                    wakeTime: run.addingTimeInterval(-leadTime)
                ))
            }
        }
        return occurrences.sorted { $0.wakeTime < $1.wakeTime }
    }
}
