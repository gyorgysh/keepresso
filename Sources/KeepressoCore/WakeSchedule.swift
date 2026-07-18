import Foundation

/// A user-authored wake schedule Keepresso installs through the helper
/// (`pmset schedule` / `pmset repeat`). System-wide: macOS only allows one
/// repeating power pair, so enabling ours replaces any existing repeat.
public struct WakeScheduleConfig: Codable, Equatable, Sendable {
    /// One-shot wall-clock wake, or `nil` when unused.
    public var oneShot: Date?
    /// When true, install a daily/weekly repeating wake at ``repeatTime`` on
    /// ``repeatWeekdays``.
    public var repeatingEnabled: Bool
    /// Seconds since midnight local time for the repeating wake (0...86399).
    public var repeatSecondsFromMidnight: Int
    /// Weekday letters for `pmset repeat` (`MTWRFSU` subset). Empty means all days.
    public var repeatWeekdays: String
    /// On system wake near a Keepresso schedule, start a keep-awake session.
    public var startSessionOnWake: Bool
    /// Timed session length when starting on wake, or `nil` for indefinite.
    public var sessionDurationSeconds: TimeInterval?
    /// Optional preset id to apply on wake (triggers + rules) instead of a
    /// bare timed/indefinite session.
    public var presetID: String?

    public init(
        oneShot: Date? = nil,
        repeatingEnabled: Bool = false,
        repeatSecondsFromMidnight: Int = 3 * 3600,
        repeatWeekdays: String = "MTWRFSU",
        startSessionOnWake: Bool = true,
        sessionDurationSeconds: TimeInterval? = 60 * 60,
        presetID: String? = nil
    ) {
        self.oneShot = oneShot
        self.repeatingEnabled = repeatingEnabled
        self.repeatSecondsFromMidnight = min(max(repeatSecondsFromMidnight, 0), 24 * 3600 - 1)
        self.repeatWeekdays = Self.normalizedWeekdays(repeatWeekdays)
        self.startSessionOnWake = startSessionOnWake
        self.sessionDurationSeconds = sessionDurationSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.presetID = presetID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        oneShot = try c.decodeIfPresent(Date.self, forKey: .oneShot)
        repeatingEnabled = try c.decodeIfPresent(Bool.self, forKey: .repeatingEnabled) ?? false
        repeatSecondsFromMidnight = min(
            max(try c.decodeIfPresent(Int.self, forKey: .repeatSecondsFromMidnight) ?? 3 * 3600, 0),
            24 * 3600 - 1
        )
        repeatWeekdays = Self.normalizedWeekdays(
            try c.decodeIfPresent(String.self, forKey: .repeatWeekdays) ?? "MTWRFSU"
        )
        startSessionOnWake = try c.decodeIfPresent(Bool.self, forKey: .startSessionOnWake) ?? true
        sessionDurationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .sessionDurationSeconds)
            .flatMap { $0 > 0 ? $0 : nil }
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
    }

    /// Whether anything should be installed on the system.
    public var isActive: Bool {
        oneShot != nil || repeatingEnabled
    }

    /// `HH:mm:ss` for `pmset repeat`.
    public var repeatTimeString: String {
        let h = repeatSecondsFromMidnight / 3600
        let m = (repeatSecondsFromMidnight % 3600) / 60
        let s = repeatSecondsFromMidnight % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// The `pmset`-facing pieces of this config: the one-shot stamp and the
    /// repeating days/time, `nil` for parts not wanted. The single source for
    /// the XPC call and the helper engine's convenience overload, so the two
    /// can't drift.
    public var pmsetArguments: (oneShot: String?, repeatDays: String?, repeatTime: String?) {
        (
            oneShot: oneShot.map { Self.oneShotString(for: $0) },
            repeatDays: repeatingEnabled ? repeatWeekdays : nil,
            repeatTime: repeatingEnabled ? repeatTimeString : nil
        )
    }

    /// `MM/dd/yy HH:mm:ss` for `pmset schedule wake`, local time.
    public static func oneShotString(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents(
            [.month, .day, .year, .hour, .minute, .second], from: date)
        let yy = (parts.year ?? 0) % 100
        return String(
            format: "%02d/%02d/%02d %02d:%02d:%02d",
            parts.month ?? 1, parts.day ?? 1, yy,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// Keep only valid `pmset` weekday letters, order MTWRFSU, default all.
    public static func normalizedWeekdays(_ raw: String) -> String {
        let allowed: [Character] = ["M", "T", "W", "R", "F", "S", "U"]
        let upper = raw.uppercased()
        let kept = allowed.filter { upper.contains($0) }
        return kept.isEmpty ? "MTWRFSU" : String(kept)
    }
}

/// What `pmset -g sched` currently reports (unprivileged read).
public struct SystemWakeState: Equatable, Sendable {
    /// One-shot scheduled wake/poweron times, if any.
    public var scheduledWakes: [Date]
    /// Raw repeating line, if any (e.g. "wakeorpoweron at 3:00:00AM every day").
    public var repeatingSummary: String?

    public init(scheduledWakes: [Date] = [], repeatingSummary: String? = nil) {
        self.scheduledWakes = scheduledWakes
        self.repeatingSummary = repeatingSummary
    }

    public static let empty = SystemWakeState()
}

/// Unprivileged reader for `pmset -g sched`.
public protocol WakeScheduleReading: AnyObject {
    func current() -> SystemWakeState
}

/// Parse `pmset -g sched` text into ``SystemWakeState``. Pure for tests.
public enum WakeScheduleParser {
    /// Real `pmset -g sched` output is sectioned, with the repeating event on
    /// the indented line after its header:
    /// ```
    /// Repeating power events:
    ///   wakeorpoweron at 3:00:00AM every day
    /// Scheduled power events:
    ///  [0]  wake at 07/18/2026 14:32:09 by '…'
    /// ```
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> SystemWakeState {
        var wakes: [Date] = []
        var repeating: String?
        /// True between the "Repeating power events:" header and the next
        /// section header, where the event line lives.
        var inRepeatingSection = false
        let oneShot = try? NSRegularExpression(
            pattern: #"\b(?:wake|wakeorpoweron|poweron)\s+at\s+(\d{1,2}/\d{1,2}/\d{2,4}\s+\d{1,2}:\d{2}:\d{2})"#,
            options: .caseInsensitive
        )
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("repeating"),
               let colon = trimmed.firstIndex(of: ":") {
                let rest = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty, rest.lowercased() != "none" {
                    repeating = rest
                    inRepeatingSection = false
                } else {
                    // Bare header: the event (if any) is on the next line.
                    inRepeatingSection = rest.isEmpty
                }
                continue
            }
            if inRepeatingSection {
                if trimmed.isEmpty || trimmed.hasSuffix(":") {
                    // Blank line or the next section header ends the section.
                    inRepeatingSection = false
                } else if trimmed.lowercased() != "none" {
                    repeating = trimmed
                    inRepeatingSection = false
                    continue
                }
            }
            if let match = oneShot?.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line)
            ),
               let range = Range(match.range(at: 1), in: line) {
                if let date = parseOneShotDate(String(line[range]), calendar: calendar) {
                    wakes.append(date)
                }
            }
        }
        return SystemWakeState(scheduledWakes: wakes.sorted(), repeatingSummary: repeating)
    }

    private static func parseOneShotDate(_ raw: String, calendar: Calendar) -> Date? {
        let formats = ["MM/dd/yy HH:mm:ss", "MM/dd/yyyy HH:mm:ss", "M/d/yy H:mm:ss", "M/d/yyyy H:mm:ss"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

/// Real backend: runs `pmset -g sched`.
public final class PMSetWakeScheduleReader: WakeScheduleReading {
    public init() {}

    public func current() -> SystemWakeState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "sched"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .empty
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return WakeScheduleParser.parse(text)
    }
}

/// Pure policy: whether a system wake should start a Keepresso session.
public enum WakeAndBrewPolicy {
    /// How close a wake must be to a configured schedule to count as "ours".
    public static let matchWindow: TimeInterval = 3 * 60

    /// `true` when `wakeDate` falls within ``matchWindow`` of the one-shot or
    /// of today's (or yesterday's, near midnight) repeating slot.
    public static func shouldStartSession(
        config: WakeScheduleConfig,
        wakeDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard config.startSessionOnWake, config.isActive else { return false }
        if let oneShot = config.oneShot,
           abs(wakeDate.timeIntervalSince(oneShot)) <= matchWindow {
            return true
        }
        guard config.repeatingEnabled else { return false }
        return isNearRepeatingSlot(config: config, date: wakeDate, calendar: calendar)
    }

    private static func isNearRepeatingSlot(
        config: WakeScheduleConfig,
        date: Date,
        calendar: Calendar
    ) -> Bool {
        // Each candidate slot counts on its own day's letter: the wake day's
        // slot when that day is configured, and the previous day's slot when
        // that day is (a 23:xx slot can wake the Mac just past midnight, on a
        // day that may not be in the set at all).
        let start = calendar.startOfDay(for: date)
        if config.repeatWeekdays.contains(Self.weekdayLetter(for: date, calendar: calendar)) {
            let slot = start.addingTimeInterval(TimeInterval(config.repeatSecondsFromMidnight))
            if abs(date.timeIntervalSince(slot)) <= matchWindow { return true }
        }
        if let prev = calendar.date(byAdding: .day, value: -1, to: start),
           config.repeatWeekdays.contains(Self.weekdayLetter(for: prev, calendar: calendar)) {
            let prevSlot = prev.addingTimeInterval(TimeInterval(config.repeatSecondsFromMidnight))
            if abs(date.timeIntervalSince(prevSlot)) <= matchWindow { return true }
        }
        return false
    }

    /// Map Calendar weekday (1=Sunday…7=Saturday) to `pmset` letters (U/M/T/W/R/F/S).
    public static func weekdayLetter(for date: Date, calendar: Calendar = .current) -> Character {
        let wd = calendar.component(.weekday, from: date)
        // 1 Sun … 7 Sat → U M T W R F S
        let map: [Character] = ["?", "U", "M", "T", "W", "R", "F", "S"]
        return map.indices.contains(wd) ? map[wd] : "M"
    }
}
