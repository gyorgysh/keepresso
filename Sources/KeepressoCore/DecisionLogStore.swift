import Foundation

/// One decision-log line on disk (JSONL). Keeps the same fields as
/// ``SessionEvent`` plus an optional battery snapshot for awake stats.
public struct PersistedSessionEvent: Codable, Equatable, Sendable {
    public var date: Date
    public var began: Bool
    public var reason: String
    public var kind: SessionEventKind?
    /// Battery charge percent (0-100) when the event was recorded, or `nil`
    /// when on AC / unknown. Paired start/stop samples give consumption.
    public var batteryPercent: Int?

    public init(
        date: Date,
        began: Bool,
        reason: String,
        kind: SessionEventKind? = nil,
        batteryPercent: Int? = nil
    ) {
        self.date = date
        self.began = began
        self.reason = reason
        self.kind = kind
        self.batteryPercent = batteryPercent
    }

    public init(_ event: SessionEvent, batteryPercent: Int? = nil) {
        self.date = event.date
        self.began = event.began
        self.reason = event.reason
        self.kind = event.kind
        self.batteryPercent = batteryPercent
    }
}

/// File IO for the decision log. Core owns the pure codec; the host wires a
/// real store under Application Support (or a fake in tests).
public protocol LogPersisting: AnyObject, Sendable {
    /// Append one JSONL line (already newline-terminated UTF-8).
    func append(_ line: Data)
    /// Full file contents, or empty when the file is missing.
    func load() -> Data
    /// Replace the whole file (used after rotation).
    func replace(_ data: Data)
}

/// Real store: `~/Library/Application Support/Keepresso/decision-log.jsonl`.
public final class FileLogStore: LogPersisting, @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let dir = base.appendingPathComponent("Keepresso", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("decision-log.jsonl", isDirectory: false)
        }
    }

    public func append(_ line: Data) {
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    public func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return (try? Data(contentsOf: fileURL)) ?? Data()
    }

    public func replace(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Pure JSONL codec and size rotation for the decision log. No file IO.
public enum DecisionLogCodec {
    /// Soft cap before rotation rewrites the file (keeps roughly a month of
    /// typical use without unbounded growth).
    public static let maxFileBytes = 512 * 1024

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Encode one event as a single JSONL line including the trailing newline.
    public static func encodeLine(_ event: PersistedSessionEvent) -> Data? {
        guard var data = try? encoder.encode(event) else { return nil }
        data.append(contentsOf: [0x0A])
        return data
    }

    /// Decode every well-formed line; skip corrupt lines so a partial write
    /// never poisons the whole history.
    public static func decode(_ data: Data) -> [PersistedSessionEvent] {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        var events: [PersistedSessionEvent] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let event = try? decoder.decode(PersistedSessionEvent.self, from: lineData)
            else { continue }
            events.append(event)
        }
        return events
    }

    /// Drop oldest lines until the payload is at most ``maxFileBytes``. Pure.
    public static func rotate(_ data: Data, maxBytes: Int = maxFileBytes) -> Data {
        guard data.count > maxBytes else { return data }
        let events = decode(data)
        guard !events.isEmpty else { return Data() }
        // Keep a suffix of events that fit. Walk from the end.
        var kept: [PersistedSessionEvent] = []
        var size = 0
        for event in events.reversed() {
            guard let line = encodeLine(event) else { continue }
            if size + line.count > maxBytes, !kept.isEmpty { break }
            kept.append(event)
            size += line.count
        }
        var out = Data()
        out.reserveCapacity(size)
        for event in kept.reversed() {
            if let line = encodeLine(event) { out.append(line) }
        }
        return out
    }
}

/// Appends decision events to a ``LogPersisting`` store with size rotation.
/// Main-actor: owned by the app next to ``DecisionLog``.
@MainActor
public final class DecisionLogPersister {
    private let store: LogPersisting
    /// How many events to rehydrate into the in-memory log on launch.
    public static let loadLimit = DecisionLog.capacity

    public init(store: LogPersisting = FileLogStore()) {
        self.store = store
    }

    /// Load the newest events from disk for the in-memory log.
    public func loadRecent() -> [PersistedSessionEvent] {
        let all = DecisionLogCodec.decode(store.load())
        if all.count <= Self.loadLimit { return all }
        return Array(all.suffix(Self.loadLimit))
    }

    /// Full history for stats (already rotation-capped on disk).
    public func loadAll() -> [PersistedSessionEvent] {
        DecisionLogCodec.decode(store.load())
    }

    /// Persist one event and rotate when the file grows past the soft cap.
    public func append(_ event: PersistedSessionEvent) {
        guard let line = DecisionLogCodec.encodeLine(event) else { return }
        store.append(line)
        let data = store.load()
        if data.count > DecisionLogCodec.maxFileBytes {
            store.replace(DecisionLogCodec.rotate(data))
        }
    }
}

// MARK: - Awake stats

/// One calendar day's held-awake summary.
public struct AwakeDayStats: Equatable, Identifiable, Sendable {
    /// Start of the local calendar day.
    public var dayStart: Date
    public var heldSeconds: TimeInterval
    /// Most common start reason that day, when any.
    public var primaryReason: String?
    /// Sum of battery percent dropped across completed sessions that day
    /// (start and stop both had a battery reading). `nil` when unknown.
    public var batteryConsumed: Int?

    public var id: Date { dayStart }

    public init(
        dayStart: Date,
        heldSeconds: TimeInterval,
        primaryReason: String? = nil,
        batteryConsumed: Int? = nil
    ) {
        self.dayStart = dayStart
        self.heldSeconds = heldSeconds
        self.primaryReason = primaryReason
        self.batteryConsumed = batteryConsumed
    }
}

/// Aggregated held-awake stats over recent days.
public struct AwakeStats: Equatable, Sendable {
    public var days: [AwakeDayStats]
    public var totalHeldSeconds: TimeInterval

    public init(days: [AwakeDayStats] = [], totalHeldSeconds: TimeInterval = 0) {
        self.days = days
        self.totalHeldSeconds = totalHeldSeconds
    }

    public static let empty = AwakeStats()
}

/// Pure aggregation of a decision log into daily held-awake stats.
public enum AwakeStatsAggregator {
    /// Pair starts with the next stop, attribute duration to local calendar
    /// days (a session spanning midnight splits), and sum battery drop when
    /// both ends have a percentage.
    public static func summarize(
        events: [PersistedSessionEvent],
        now: Date = Date(),
        dayCount: Int = 7,
        calendar: Calendar = .current
    ) -> AwakeStats {
        let sorted = events.sorted { $0.date < $1.date }
        var openStart: PersistedSessionEvent?
        var dayHeld: [Date: TimeInterval] = [:]
        var dayReasons: [Date: [String: Int]] = [:]
        var dayBattery: [Date: Int] = [:]

        for event in sorted {
            if event.began {
                openStart = event
                let day = calendar.startOfDay(for: event.date)
                dayReasons[day, default: [:]][event.reason, default: 0] += 1
            } else if let start = openStart {
                addDuration(
                    from: start.date, to: event.date,
                    into: &dayHeld, calendar: calendar
                )
                if let b0 = start.batteryPercent, let b1 = event.batteryPercent, b0 >= b1 {
                    let day = calendar.startOfDay(for: start.date)
                    dayBattery[day, default: 0] += (b0 - b1)
                }
                openStart = nil
            }
        }
        // Still-open session counts through `now`.
        if let start = openStart {
            addDuration(from: start.date, to: now, into: &dayHeld, calendar: calendar)
        }

        let today = calendar.startOfDay(for: now)
        var days: [AwakeDayStats] = []
        for offset in (0 ..< dayCount).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let held = dayHeld[day] ?? 0
            let primary = dayReasons[day]?
                .max(by: { $0.value < $1.value })?
                .key
            let battery = dayBattery[day]
            days.append(AwakeDayStats(
                dayStart: day,
                heldSeconds: held,
                primaryReason: primary,
                batteryConsumed: battery
            ))
        }
        let total = days.reduce(0) { $0 + $1.heldSeconds }
        return AwakeStats(days: days, totalHeldSeconds: total)
    }

    private static func addDuration(
        from start: Date,
        to end: Date,
        into dayHeld: inout [Date: TimeInterval],
        calendar: Calendar
    ) {
        guard end > start else { return }
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let sliceEnd = min(end, nextDay)
            dayHeld[dayStart, default: 0] += sliceEnd.timeIntervalSince(cursor)
            cursor = sliceEnd
        }
    }
}
