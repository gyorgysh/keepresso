import Foundation

/// A recurring daily time window on selected weekdays: the persisted shape of
/// a schedule trigger like "weekdays 9:00-18:00".
public struct TimeWindowRule: Codable, Equatable, Hashable, Sendable {
    /// Window start, in minutes from midnight (0..<1440).
    public var startMinutes: Int
    /// Window end, in minutes from midnight (0..<1440). An end at or before
    /// the start wraps past midnight into the next day (22:00-6:00).
    public var endMinutes: Int
    /// The weekdays the window *starts* on, in `Calendar`'s numbering
    /// (1 = Sunday … 7 = Saturday). Empty means every day.
    public var weekdays: Set<Int>

    public init(startMinutes: Int, endMinutes: Int, weekdays: Set<Int> = []) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.weekdays = weekdays
    }

    /// "Weekdays 9:00-18:00", "Every day 22:00-6:00", "Sat, Sun 10:00-14:00".
    public var label: String {
        "\(Self.daysSummary(weekdays)) \(Self.time(startMinutes))-\(Self.time(endMinutes))"
    }

    static func time(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func daysSummary(_ weekdays: Set<Int>) -> String {
        switch weekdays {
        case [], Set(1...7):       return L("Every day")
        case Set(2...6):           return L("Weekdays")
        case [1, 7]:               return L("Weekends")
        default:
            // The system's short weekday symbols, so day names follow the app's
            // language (index 0 = Sunday, matching Calendar's 1...7 numbering).
            // Guard the index: a corrupt or imported weekday outside 1...7 would
            // otherwise crash the app when the rules list renders this label.
            let names = Calendar.current.shortStandaloneWeekdaySymbols
            return weekdays.sorted()
                .compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }
                .joined(separator: ", ")
        }
    }
}

/// Fires while the current time falls inside a ``TimeWindowRule``. Time-driven
/// like ``GracePeriodTrigger``: the injected clock keeps the decision a pure
/// function of (rule, date, calendar), so tests pin both sides of every edge.
public final class TimeWindowTrigger: Trigger {
    public var rule: TimeWindowRule

    private let now: () -> Date
    private let calendar: Calendar

    public init(
        rule: TimeWindowRule,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.rule = rule
        self.now = now
        self.calendar = calendar
    }

    public var label: String { rule.label }

    public func isSatisfied() -> Bool {
        Self.evaluate(rule, at: now(), calendar: calendar)
    }

    /// Pure decision function, exposed for direct unit testing. The start is
    /// inclusive and the end exclusive, so back-to-back windows never overlap.
    /// A wrapped window's early-morning part belongs to the window that
    /// *started* the previous day, so "Fri 22:00-6:00" covers Saturday 3:00.
    static func evaluate(_ rule: TimeWindowRule, at date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute else { return false }
        let minutes = hour * 60 + minute

        func starts(on day: Int) -> Bool {
            rule.weekdays.isEmpty || rule.weekdays.contains(day)
        }

        if rule.startMinutes < rule.endMinutes {
            return starts(on: weekday) && minutes >= rule.startMinutes && minutes < rule.endMinutes
        }
        // Wrapped past midnight (an equal start and end reads as a full day).
        if minutes >= rule.startMinutes { return starts(on: weekday) }
        if minutes < rule.endMinutes {
            let yesterday = weekday == 1 ? 7 : weekday - 1
            return starts(on: yesterday)
        }
        return false
    }
}
