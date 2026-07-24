import Foundation

/// A parsed 5-field cron expression (`minute hour day-of-month month day-of-week`)
/// covering the operators the schedulers actually emit: `*`, plain numbers,
/// `,` lists, `-` ranges, and `*/n` (or `a-b/n`) steps. It exists so a schedule
/// discovered from Claude Desktop (which stores tasks as cron, e.g. `0 9 * * *`)
/// can be turned into concrete upcoming run times to wake the Mac for.
///
/// Pure and injectable, mirroring the rest of ``KeepressoCore``: times are
/// resolved against a caller-supplied ``Calendar`` so tests pin a timezone
/// instead of depending on the machine's. Cron is wall-clock local time, which
/// is how Claude Desktop stores and shows it.
public struct CronExpression: Equatable, Sendable {
    private let minutes: Set<Int>       // 0...59
    private let hours: Set<Int>         // 0...23
    private let daysOfMonth: Set<Int>   // 1...31
    private let months: Set<Int>        // 1...12
    private let daysOfWeek: Set<Int>    // 0...6, Sunday = 0 (7 normalized to 0)
    private let domRestricted: Bool     // the day-of-month field was not "*"
    private let dowRestricted: Bool     // the day-of-week field was not "*"

    /// Parse a standard 5-field expression. Returns `nil` for anything this
    /// codec doesn't speak (wrong field count, out-of-range value, names, or the
    /// non-schedule sentinels a "Manual" task carries), so the caller can simply
    /// skip an automation with no usable schedule.
    public init?(_ text: String) {
        let fields = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5,
              let mins = Self.parseField(fields[0], min: 0, max: 59),
              let hrs = Self.parseField(fields[1], min: 0, max: 23),
              let dom = Self.parseField(fields[2], min: 1, max: 31),
              let mon = Self.parseField(fields[3], min: 1, max: 12),
              let dowRaw = Self.parseField(fields[4], min: 0, max: 7)
        else { return nil }
        minutes = mins
        hours = hrs
        daysOfMonth = dom
        months = mon
        daysOfWeek = Set(dowRaw.map { $0 == 7 ? 0 : $0 })  // cron allows 0 and 7 for Sunday
        domRestricted = fields[2] != "*"
        dowRestricted = fields[4] != "*"
    }

    /// Expand one field into the set of values it allows, or `nil` if malformed.
    static func parseField(_ field: String, min: Int, max: Int) -> Set<Int>? {
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            let stepSplit = part.split(separator: "/", maxSplits: 1).map(String.init)
            let base = stepSplit[0]
            var step = 1
            if stepSplit.count == 2 {
                guard let s = Int(stepSplit[1]), s > 0 else { return nil }
                step = s
            }
            var lo = min, hi = max
            if base == "*" {
                // Full range, optionally stepped.
            } else if let dash = base.firstIndex(of: "-") {
                guard let a = Int(base[..<dash]),
                      let b = Int(base[base.index(after: dash)...]) else { return nil }
                lo = a; hi = b
            } else if let v = Int(base) {
                lo = v
                // `n/step` means from n up to the field max, stepping; a bare `n`
                // is just that single value.
                hi = stepSplit.count == 2 ? max : v
            } else {
                return nil
            }
            guard lo >= min, hi <= max, lo <= hi else { return nil }
            var v = lo
            while v <= hi { result.insert(v); v += step }
        }
        return result.isEmpty ? nil : result
    }

    /// The next run time strictly after `date`, or `nil` if none within a five
    /// year horizon (an impossible expression such as Feb 30). Skips whole
    /// months, days, and hours that can't match so the search stays cheap even
    /// for sparse schedules.
    public func next(after date: Date, calendar: Calendar) -> Date? {
        let unit: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        guard let truncated = calendar.date(from: calendar.dateComponents(unit, from: date)) else { return nil }
        var candidate = truncated.addingTimeInterval(60)  // strictly after, minute resolution
        let horizon = calendar.date(byAdding: .year, value: 5, to: truncated) ?? truncated.addingTimeInterval(5 * 366 * 86400)

        while candidate <= horizon {
            let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: candidate)
            guard let month = c.month, let day = c.day, let hour = c.hour,
                  let minute = c.minute, let weekday = c.weekday else { return nil }
            if !months.contains(month) {
                candidate = startOfNextMonth(candidate, calendar: calendar); continue
            }
            if !dayMatches(day: day, weekday: weekday) {
                candidate = startOfNextDay(candidate, calendar: calendar); continue
            }
            if !hours.contains(hour) {
                candidate = startOfNextHour(candidate, calendar: calendar); continue
            }
            if !minutes.contains(minute) {
                candidate = candidate.addingTimeInterval(60); continue
            }
            return candidate
        }
        return nil
    }

    /// The next `count` run times after `date`, in order.
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

    /// The classic Vixie day rule: when both day-of-month and day-of-week are
    /// restricted, a day matches if it satisfies *either*; otherwise only the
    /// restricted field applies (and neither restricted means every day).
    private func dayMatches(day: Int, weekday: Int) -> Bool {
        let cronDow = weekday - 1  // Calendar 1...7 (Sun...Sat) -> cron 0...6
        let domMatch = daysOfMonth.contains(day)
        let dowMatch = daysOfWeek.contains(cronDow)
        switch (domRestricted, dowRestricted) {
        case (true, true):   return domMatch || dowMatch
        case (true, false):  return domMatch
        case (false, true):  return dowMatch
        case (false, false): return true
        }
    }

    private func startOfNextHour(_ date: Date, calendar: Calendar) -> Date {
        let base = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
        return calendar.date(byAdding: .hour, value: 1, to: base) ?? date.addingTimeInterval(3600)
    }

    private func startOfNextDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(86400)
    }

    private func startOfNextMonth(_ date: Date, calendar: Calendar) -> Date {
        let base = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return calendar.date(byAdding: .month, value: 1, to: base) ?? date.addingTimeInterval(31 * 86400)
    }
}
