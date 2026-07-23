import Foundation

// MARK: - Request record

/// One wake-schedule change asked for by an outside tool through the CLI or
/// the MCP server. Same transport as leases: the request travels as a
/// validated file, never as URL parameters, and the app only honors it while
/// the default-off "allow automation to change the wake schedule" preference
/// is enabled. One pending request at a time; a newer write replaces it.
public struct AutomationWakeRequest: Codable, Equatable, Sendable {
    /// Caller-supplied UUID; the acknowledgment key in `status.json`.
    public var requestId: String
    /// One-shot wake instant, or nil.
    public var oneShot: Date?
    /// `MTWRFSU` subset for a repeating wake, or nil.
    public var repeatDays: String?
    /// `HH:MM` 24-hour local time for the repeating wake, or nil.
    public var repeatTime: String?
    public var requestedAt: Date

    /// Nothing to install: the request asks to clear Keepresso's schedule.
    public var isClear: Bool {
        oneShot == nil && repeatDays == nil && repeatTime == nil
    }

    public init(
        requestId: String,
        oneShot: Date? = nil,
        repeatDays: String? = nil,
        repeatTime: String? = nil,
        requestedAt: Date
    ) {
        self.requestId = requestId
        self.oneShot = oneShot
        self.repeatDays = repeatDays
        self.repeatTime = repeatTime
        self.requestedAt = requestedAt
    }
}

/// How one request ended, stamped into `status.json` for the client's poll.
public enum AutomationWakeOutcome: String, Codable, Sendable {
    case applied
    case disabled
    case invalid
    case helperUnavailable
}

// MARK: - Policy

/// Pure validation and mapping for wake requests. The file is untrusted
/// input, so everything is checked again app-side no matter what the writing
/// client validated.
public enum AutomationWakeControl {
    /// One-shots must be at least this far out (a wake for "now" is
    /// meaningless) and at most a year out (a typo, not a plan).
    public static let minLead: TimeInterval = 30
    public static let maxLead: TimeInterval = 366 * 24 * 3600

    public enum Verdict: Equatable, Sendable {
        /// Install this config, or clear when nil. Session-on-wake behavior
        /// is merged from the user's existing schedule by the caller.
        case apply(WakeScheduleConfig?)
        case invalid(String)
    }

    public static func adjudicate(_ request: AutomationWakeRequest, now: Date) -> Verdict {
        guard AutomationLease.canonicalId(request.requestId) != nil else {
            return .invalid("requestId is not a UUID")
        }
        if request.isClear { return .apply(nil) }
        if let oneShot = request.oneShot {
            guard oneShot > now.addingTimeInterval(minLead) else {
                return .invalid("the wake time has already passed or is too soon")
            }
            guard oneShot < now.addingTimeInterval(maxLead) else {
                return .invalid("the wake time is more than a year away")
            }
        }
        // Repeating parts come together or not at all.
        let wantsRepeat = request.repeatDays != nil || request.repeatTime != nil
        if wantsRepeat {
            guard let days = request.repeatDays, let time = request.repeatTime else {
                return .invalid("a repeating wake needs both days and a time")
            }
            guard hasValidWeekdays(days) else {
                return .invalid("no valid weekday letters (use MTWRFSU)")
            }
            guard CLIRequest.isValidClockTime(time) else {
                return .invalid("'\(time)' is not a 24-hour time like 07:30")
            }
        }
        var config = WakeScheduleConfig()
        config.oneShot = request.oneShot
        if wantsRepeat, let days = request.repeatDays, let time = request.repeatTime {
            config.repeatingEnabled = true
            config.repeatWeekdays = WakeScheduleConfig.normalizedWeekdays(days)
            config.repeatSecondsFromMidnight = secondsFromMidnight(time)
        }
        return .apply(config)
    }

    /// Strict weekday check for the automation surface: at least one real
    /// `MTWRFSU` letter. Deliberately not ``WakeScheduleConfig/normalizedWeekdays(_:)``,
    /// which forgives junk by defaulting to every day; an API caller's junk
    /// should be an error, not a daily wake.
    public static func hasValidWeekdays(_ raw: String) -> Bool {
        raw.uppercased().contains { "MTWRFSU".contains($0) }
    }

    static func secondsFromMidnight(_ clockTime: String) -> Int {
        let parts = clockTime.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return 0 }
        return hour * 3600 + minute * 60
    }
}

// MARK: - Request file

/// The single pending request file under Application Support, next to the
/// lease directory. Same IO contract: atomic, best-effort, errors swallowed.
public enum AutomationWakeRequestFile {
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keepresso", isDirectory: true)
            .appendingPathComponent("automation-requests", isDirectory: true)
            .appendingPathComponent("wake.json")
    }

    public static func write(_ request: AutomationWakeRequest, to url: URL = defaultURL()) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(request) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL = defaultURL()) -> AutomationWakeRequest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AutomationWakeRequest.self, from: data)
    }

    public static func delete(at url: URL = defaultURL()) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Client

/// Client-side wake operations, shared by the CLI and the MCP server like
/// ``LeaseClient``. `status` is a direct unprivileged `pmset -g sched` read;
/// `set` and `clear` write the request file, ring the same doorbell leases
/// use, and poll `status.json` for the stamped outcome.
public struct WakeClient {
    public var now: () -> Date
    public var writeRequest: (AutomationWakeRequest) -> Void
    public var readStatus: () -> StatusSnapshot?
    public var nudgeApp: () -> Bool
    public var sleep: (TimeInterval) -> Void
    public var isPidAlive: (Int32) -> Bool
    public var readSched: () -> SystemWakeState
    public var generateId: () -> String

    public init(
        now: @escaping () -> Date = Date.init,
        writeRequest: @escaping (AutomationWakeRequest) -> Void = { AutomationWakeRequestFile.write($0) },
        readStatus: @escaping () -> StatusSnapshot? = { StatusFile.read() },
        nudgeApp: @escaping () -> Bool,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        isPidAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM },
        readSched: @escaping () -> SystemWakeState = { PMSetWakeScheduleReader().current() },
        generateId: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.now = now
        self.writeRequest = writeRequest
        self.readStatus = readStatus
        self.nudgeApp = nudgeApp
        self.sleep = sleep
        self.isPidAlive = isPidAlive
        self.readSched = readSched
        self.generateId = generateId
    }

    public func status() -> LeaseOutcome {
        struct Report: Codable {
            var scheduledWakes: [Date]
            var repeatingSummary: String?
        }
        let state = readSched()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = Report(scheduledWakes: state.scheduledWakes, repeatingSummary: state.repeatingSummary)
        let data = (try? encoder.encode(report)) ?? Data("{}".utf8)
        var lines: [String] = []
        if state.scheduledWakes.isEmpty && state.repeatingSummary == nil {
            lines.append("No scheduled wakes.")
        }
        for wake in state.scheduledWakes {
            lines.append("Wake at \(wake)")
        }
        if let repeating = state.repeatingSummary {
            lines.append("Repeating: \(repeating)")
        }
        return LeaseOutcome(
            exitCode: 0,
            json: String(decoding: data, as: UTF8.self),
            human: lines.joined(separator: "\n")
        )
    }

    /// Set (or, with an all-nil request, clear) the schedule and wait for the
    /// app's verdict. The request file is deleted by the app when processed,
    /// and deleted here on timeout so an unprocessed request cannot fire
    /// arbitrarily later.
    public func apply(
        oneShot: Date?,
        repeatDays: String?,
        repeatTime: String?
    ) -> LeaseOutcome {
        let instant = now()
        let request = AutomationWakeRequest(
            requestId: generateId(),
            oneShot: oneShot,
            repeatDays: repeatDays,
            repeatTime: repeatTime,
            requestedAt: instant
        )
        // Reject client-side what the app would reject anyway, without a
        // round trip.
        if case .invalid(let reason) = AutomationWakeControl.adjudicate(request, now: instant) {
            return failure(64, reason)
        }
        writeRequest(request)
        guard nudgeApp() else {
            AutomationWakeRequestFile.delete()
            return failure(2, "could not reach the Keepresso app. Is it installed?")
        }
        let deadline = instant.addingTimeInterval(LeaseClient.ackTimeout)
        while true {
            if let snapshot = readStatus(), isPidAlive(snapshot.pid),
               snapshot.lastWakeRequestId == request.requestId,
               let outcome = snapshot.lastWakeRequestOutcome
                   .flatMap(AutomationWakeOutcome.init(rawValue:)) {
                return render(outcome, request: request)
            }
            guard now() < deadline else { break }
            sleep(LeaseClient.ackInterval)
        }
        AutomationWakeRequestFile.delete()
        return failure(2, "the Keepresso app did not acknowledge the wake request. Update the app if it predates automation wake control.")
    }

    private func render(_ outcome: AutomationWakeOutcome, request: AutomationWakeRequest) -> LeaseOutcome {
        struct Payload: Codable {
            var requestId: String
            var outcome: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(
            Payload(requestId: request.requestId, outcome: outcome.rawValue))) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        switch outcome {
        case .applied:
            let human = request.isClear ? "Wake schedule cleared." : "Wake schedule applied."
            return LeaseOutcome(exitCode: 0, json: json, human: human)
        case .disabled:
            return LeaseOutcome(
                exitCode: 4, json: json,
                human: "automation wake control is disabled in Keepresso's preferences.")
        case .invalid:
            return LeaseOutcome(exitCode: 64, json: json, human: "the app rejected the wake request as invalid.")
        case .helperUnavailable:
            return LeaseOutcome(
                exitCode: 1, json: json,
                human: "installing a wake schedule needs the administrator helper (Preferences > General).")
        }
    }

    private func failure(_ code: Int32, _ message: String) -> LeaseOutcome {
        struct Payload: Codable { var error: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(Payload(error: message))) ?? Data("{}".utf8)
        return LeaseOutcome(exitCode: code, json: String(decoding: data, as: UTF8.self), human: message)
    }
}

public extension WakeClient {
    /// The production client, sharing the lease doorbell.
    static func real() -> WakeClient {
        WakeClient(nudgeApp: {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", CLIRequest.RemoteCommand.syncLeases.urlString]
            do {
                try open.run()
            } catch {
                return false
            }
            open.waitUntilExit()
            return open.terminationStatus == 0
        })
    }
}
