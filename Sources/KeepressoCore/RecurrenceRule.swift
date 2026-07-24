import Foundation

/// A focused iCal RRULE evaluator for the recurrences Codex writes into its
/// `automation.toml`, e.g. `FREQ=WEEKLY;BYHOUR=16;BYMINUTE=0;BYDAY=FR`. Handles
/// the parts the schedulers actually emit: `FREQ` (hourly/daily/weekly/monthly),
/// `BYHOUR`, `BYMINUTE`, `BYDAY`, and `BYMONTHDAY`.
///
/// `INTERVAL` greater than one (every N weeks, say) needs an anchor RRULE
/// doesn't carry here, so it is treated as one. The only effect is waking a bit
/// more often than strictly needed, which is safe. Like ``CronExpression``, it
/// resolves against a caller-supplied ``Calendar`` in local wall-clock time.
public struct RecurrenceRule: Equatable, Sendable {
    public enum Frequency: String, Sendable {
        case hourly = "HOURLY"
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
    }

    private let frequency: Frequency
    private let byHour: Set<Int>       // 0...23, empty = defaulted
    private let byMinute: Set<Int>     // 0...59, empty = {0}
    private let byWeekday: Set<Int>    // 0...6 Sun...Sat, empty = every day
    private let byMonthDay: Set<Int>   // 1...31, empty = every day

    /// Parse an RRULE body, with or without the leading `RRULE:` prefix.
    /// Returns `nil` without a `FREQ`, which every valid rule carries.
    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.uppercased().hasPrefix("RRULE:") { body = String(body.dropFirst(6)) }

        var frequency: Frequency?
        var byHour = Set<Int>(), byMinute = Set<Int>(), byWeekday = Set<Int>(), byMonthDay = Set<Int>()
        for pair in body.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let value = String(kv[1])
            switch kv[0].uppercased() {
            case "FREQ":       frequency = Frequency(rawValue: value.uppercased())
            case "BYHOUR":     byHour = Self.ints(value, 0, 23)
            case "BYMINUTE":   byMinute = Self.ints(value, 0, 59)
            case "BYMONTHDAY": byMonthDay = Self.ints(value, 1, 31)
            case "BYDAY":      byWeekday = Self.weekdays(value)
            default:           break
            }
        }
        guard let frequency else { return nil }
        self.frequency = frequency
        self.byHour = byHour
        self.byMinute = byMinute
        self.byWeekday = byWeekday
        self.byMonthDay = byMonthDay
    }

    private static func ints(_ value: String, _ min: Int, _ max: Int) -> Set<Int> {
        Set(value.split(separator: ",").compactMap { Int($0) }.filter { $0 >= min && $0 <= max })
    }

    /// `MO,TU,...` to cron-style weekday numbers (Sunday = 0). A numeric prefix
    /// such as `2MO` (second Monday) is not modelled; the day code still counts.
    private static func weekdays(_ value: String) -> Set<Int> {
        let map = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]
        var result = Set<Int>()
        for token in value.split(separator: ",") {
            let code = String(token.suffix(2)).uppercased()
            if let day = map[code] { result.insert(day) }
        }
        return result
    }

    private var hours: Set<Int> { byHour.isEmpty ? (frequency == .hourly ? Set(0...23) : [0]) : byHour }
    private var minutes: Set<Int> { byMinute.isEmpty ? [0] : byMinute }
    private var daysOfWeek: Set<Int> { byWeekday.isEmpty ? Set(0...6) : byWeekday }
    private var daysOfMonth: Set<Int> { byMonthDay.isEmpty ? Set(1...31) : byMonthDay }

    /// The next run strictly after `date`, or `nil` within five years. `BYDAY`
    /// and `BYMONTHDAY` are ANDed, matching RRULE (unlike cron's union).
    public func next(after date: Date, calendar: Calendar) -> Date? {
        let unit: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        guard let truncated = calendar.date(from: calendar.dateComponents(unit, from: date)) else { return nil }
        var candidate = truncated.addingTimeInterval(60)
        let horizon = calendar.date(byAdding: .year, value: 5, to: truncated) ?? truncated.addingTimeInterval(5 * 366 * 86400)
        let mins = minutes, hrs = hours, dow = daysOfWeek, dom = daysOfMonth

        while candidate <= horizon {
            let c = calendar.dateComponents([.day, .hour, .minute, .weekday], from: candidate)
            guard let day = c.day, let hour = c.hour, let minute = c.minute, let weekday = c.weekday else { return nil }
            if !dow.contains(weekday - 1) || !dom.contains(day) {
                candidate = startOfNextDay(candidate, calendar: calendar); continue
            }
            if !hrs.contains(hour) {
                candidate = startOfNextHour(candidate, calendar: calendar); continue
            }
            if !mins.contains(minute) {
                candidate = candidate.addingTimeInterval(60); continue
            }
            return candidate
        }
        return nil
    }

    public func nextOccurrences(after date: Date, count: Int, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var cursor = date
        for _ in 0..<max(0, count) {
            guard let n = next(after: cursor, calendar: calendar) else { break }
            result.append(n)
            cursor = n
        }
        return result
    }

    private func startOfNextHour(_ date: Date, calendar: Calendar) -> Date {
        let base = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
        return calendar.date(byAdding: .hour, value: 1, to: base) ?? date.addingTimeInterval(3600)
    }

    private func startOfNextDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(86400)
    }
}
