import Foundation

/// Discovers tokenstat.ai's *local* automations so Keepresso can wake for them.
/// The host daemon persists jobs as one JSON file:
///
///     ~/Library/Application Support/ai.tokenstat.tokenstat/automations.json
///     { "jobs": [
///         { "id": "automation-…", "name": "Daily brief", "enabled": true,
///           "schedule": { "kind": "daily", "everySeconds": 0,
///                         "hour": 8, "minute": 0, "weekday": 0,
///                         "weekdays": 0 },
///           "nextRunAtMs": 1786428000000, "prompt": "…" } ] }
///
/// Kinds: `interval`, `daily`, `weekdays` (Mon–Fri), `weekly` (one day or a
/// multi-day `weekdays` bitset), `custom` (multi-day bitset). `once` is
/// run-on-demand only and is skipped. Only schedule, name, id, and enabled are
/// read. The prompt is never decoded or retained.
public struct TokenstatAutomationsReader: LocalAutomationReading {
    /// Yields the raw bytes of the automations file. Injected so tests feed
    /// JSON directly and the real path reads the data directory.
    private let loadFile: @Sendable () -> Data?

    public init(loadFile: @escaping @Sendable () -> Data?) {
        self.loadFile = loadFile
    }

    public func automations() -> [ScheduledAutomation] {
        guard let data = loadFile() else { return [] }
        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(File.self, from: data) else { return [] }
        var byID: [String: ScheduledAutomation] = [:]
        for job in file.jobs {
            guard let recurrence = Self.recurrence(for: job) else { continue }
            let automation = ScheduledAutomation(
                source: .tokenstat,
                key: job.id,
                name: job.name.isEmpty ? job.id : job.name,
                recurrence: recurrence,
                enabled: job.enabled
            )
            byID[automation.id] = automation
        }
        return byID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Map one tokenstat.ai job to a ``Recurrence``, or `nil` when there is
    /// nothing to wake for (once, malformed, or a period too short to be real).
    static func recurrence(for job: Job) -> Recurrence? {
        switch job.schedule.kind {
        case .once, .unknown:
            return nil
        case .daily:
            return wallClockCron(hour: job.schedule.hour, minute: job.schedule.minute, dayMask: nil)
        case .weekdays:
            // Monday through Friday, Monday = bit 0 → 0b0001_1111.
            return wallClockCron(hour: job.schedule.hour, minute: job.schedule.minute, dayMask: 0b0001_1111)
        case .weekly:
            let mask: UInt8
            if job.schedule.weekdays & 0b0111_1111 != 0 {
                mask = job.schedule.weekdays & 0b0111_1111
            } else if job.schedule.weekday <= 6 {
                mask = 1 << job.schedule.weekday
            } else {
                return nil
            }
            return wallClockCron(hour: job.schedule.hour, minute: job.schedule.minute, dayMask: mask)
        case .custom:
            let mask = job.schedule.weekdays & 0b0111_1111
            guard mask != 0 else { return nil }
            return wallClockCron(hour: job.schedule.hour, minute: job.schedule.minute, dayMask: mask)
        case .interval:
            // Floored at a minute, matching tokenstat's own validate.
            guard job.schedule.everySeconds >= 60 else { return nil }
            let every = TimeInterval(job.schedule.everySeconds)
            // Prefer the daemon's next fire so the wake aligns with when it
            // will actually run. Without one, anchor "now" at discovery time.
            let anchor: Date
            if let ms = job.nextRunAtMs {
                anchor = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            } else {
                anchor = Date()
            }
            return .interval(every: every, anchor: anchor)
        }
    }

    /// Build a 5-field cron for a wall-clock time. `dayMask` uses Monday = bit 0
    /// (tokenstat convention); cron uses Sunday = 0. `nil` means every day.
    static func wallClockCron(hour: UInt8, minute: UInt8, dayMask: UInt8?) -> Recurrence? {
        guard hour <= 23, minute <= 59 else { return nil }
        let dow: String
        if let mask = dayMask {
            var days: [String] = []
            for bit in 0..<7 where mask & (1 << bit) != 0 {
                // tokenstat Mon=0 → cron Mon=1; Sun bit 6 → cron 0.
                days.append(String((bit + 1) % 7))
            }
            guard !days.isEmpty else { return nil }
            dow = days.joined(separator: ",")
        } else {
            dow = "*"
        }
        let text = "\(minute) \(hour) * * \(dow)"
        guard let cron = CronExpression(text) else { return nil }
        return .cron(cron)
    }

    // MARK: - Wire shape

    struct File: Decodable {
        let jobs: [Job]

        // Lossy: a bad job is skipped rather than dropping the whole file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var jobs: [Job] = []
            if var array = try? c.nestedUnkeyedContainer(forKey: .jobs) {
                while !array.isAtEnd {
                    let before = array.currentIndex
                    if let job = try? array.decode(Job.self) {
                        jobs.append(job)
                    } else {
                        _ = try? array.decode(Discarded.self)
                    }
                    if array.currentIndex == before { break }
                }
            }
            self.jobs = jobs
        }

        private enum CodingKeys: String, CodingKey { case jobs }
    }

    struct Job: Decodable {
        let id: String
        let name: String
        let enabled: Bool
        let schedule: Schedule
        let nextRunAtMs: Int64?

        private enum CodingKeys: String, CodingKey {
            case id, name, enabled, schedule, nextRunAtMs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? Schedule()
            nextRunAtMs = try c.decodeIfPresent(Int64.self, forKey: .nextRunAtMs)
        }
    }

    struct Schedule: Decodable {
        enum Kind: String, Decodable {
            case once, interval, daily, weekdays, weekly, custom
            case unknown

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw) ?? .unknown
            }
        }

        var kind: Kind
        var everySeconds: UInt64
        var hour: UInt8
        var minute: UInt8
        /// Monday = 0, matching tokenstat and the calendar its app draws.
        var weekday: UInt8
        /// Multi-day bitset, Monday = bit 0 … Sunday = bit 6.
        var weekdays: UInt8

        init() {
            kind = .once
            everySeconds = 0
            hour = 0
            minute = 0
            weekday = 0
            weekdays = 0
        }

        private enum CodingKeys: String, CodingKey {
            case kind, everySeconds, hour, minute, weekday, weekdays
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .once
            everySeconds = try c.decodeIfPresent(UInt64.self, forKey: .everySeconds) ?? 0
            hour = try c.decodeIfPresent(UInt8.self, forKey: .hour) ?? 0
            minute = try c.decodeIfPresent(UInt8.self, forKey: .minute) ?? 0
            weekday = try c.decodeIfPresent(UInt8.self, forKey: .weekday) ?? 0
            weekdays = try c.decodeIfPresent(UInt8.self, forKey: .weekdays) ?? 0
        }
    }

    private struct Discarded: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

public extension TokenstatAutomationsReader {
    /// The real reader over tokenstat.ai's data-directory automations file.
    /// Failures (no tokenstat, no jobs) yield an empty list, not an error.
    static func real(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TokenstatAutomationsReader {
        let url = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("ai.tokenstat.tokenstat", isDirectory: true)
            .appendingPathComponent("automations.json")
        return TokenstatAutomationsReader {
            try? Data(contentsOf: url)
        }
    }
}
