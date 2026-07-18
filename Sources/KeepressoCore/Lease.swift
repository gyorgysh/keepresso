import Darwin
import Foundation

/// The terminal outcome an agent supplies when releasing a wake lease.
public enum LeaseCompletionResult: String, Codable, CaseIterable, Sendable {
    case success
    case failure
    case cancelled
    case timeout
}

/// Whether a persisted wake lease can still require the Mac to remain awake.
public enum AgentWakeLeaseState: String, Codable, Sendable {
    case active
    case released
    case expired
}

/// One agent-owned request to keep the Mac awake.
public struct AgentWakeLeaseRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var owner: String
    public var agent: String
    public var task: String
    public var state: AgentWakeLeaseState
    public var ttlSeconds: Int
    public var maxLifetimeSeconds: Int
    public var acquiredAt: Date
    public var renewedAt: Date
    public var expiresAt: Date
    public var maxExpiresAt: Date
    public var releasedAt: Date?
    public var result: LeaseCompletionResult?
    public var message: String?

    public init(
        id: String,
        owner: String,
        agent: String,
        task: String,
        state: AgentWakeLeaseState = .active,
        ttlSeconds: Int,
        maxLifetimeSeconds: Int,
        acquiredAt: Date,
        renewedAt: Date,
        expiresAt: Date,
        maxExpiresAt: Date,
        releasedAt: Date? = nil,
        result: LeaseCompletionResult? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.agent = agent
        self.task = task
        self.state = state
        self.ttlSeconds = ttlSeconds
        self.maxLifetimeSeconds = maxLifetimeSeconds
        self.acquiredAt = acquiredAt
        self.renewedAt = renewedAt
        self.expiresAt = expiresAt
        self.maxExpiresAt = maxExpiresAt
        self.releasedAt = releasedAt
        self.result = result
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case id, owner, agent, task, state
        case ttlSeconds, maxLifetimeSeconds
        case acquiredAt, renewedAt, expiresAt, maxExpiresAt, releasedAt
        case result, message
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(owner, forKey: .owner)
        try container.encode(agent, forKey: .agent)
        try container.encode(task, forKey: .task)
        try container.encode(state, forKey: .state)
        try container.encode(ttlSeconds, forKey: .ttlSeconds)
        try container.encode(maxLifetimeSeconds, forKey: .maxLifetimeSeconds)
        try container.encode(acquiredAt, forKey: .acquiredAt)
        try container.encode(renewedAt, forKey: .renewedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(maxExpiresAt, forKey: .maxExpiresAt)
        if let releasedAt { try container.encode(releasedAt, forKey: .releasedAt) }
        else { try container.encodeNil(forKey: .releasedAt) }
        if let result { try container.encode(result, forKey: .result) }
        else { try container.encodeNil(forKey: .result) }
        if let message { try container.encode(message, forKey: .message) }
        else { try container.encodeNil(forKey: .message) }
    }
}

/// Optional exact-match filters for `lease list`.
public struct LeaseListFilter: Equatable, Sendable {
    public var owner: String?
    public var agent: String?
    public var task: String?
    public var includeInactive: Bool

    public init(
        owner: String? = nil,
        agent: String? = nil,
        task: String? = nil,
        includeInactive: Bool = false
    ) {
        self.owner = owner
        self.agent = agent
        self.task = task
        self.includeInactive = includeInactive
    }
}

/// A parsed lease operation shared by the CLI and MCP adapter.
public enum LeaseCommand: Equatable, Sendable {
    case acquire(
        owner: String,
        agent: String,
        task: String,
        ttlSeconds: Int?,
        maxLifetimeSeconds: Int?,
        message: String?
    )
    case renew(id: String, ttlSeconds: Int?, message: String?)
    case heartbeat(id: String, ttlSeconds: Int?, message: String?)
    case release(id: String, result: LeaseCompletionResult, message: String?)
    case list(LeaseListFilter)
    case status(id: String?)

    public var operation: String {
        switch self {
        case .acquire: return "acquire"
        case .renew: return "renew"
        case .heartbeat: return "heartbeat"
        case .release: return "release"
        case .list: return "list"
        case .status: return "status"
        }
    }
}

/// Aggregate state returned with every successful lease response.
public struct LeaseStatusSummary: Codable, Equatable, Sendable {
    public var wakeRequired: Bool
    public var activeCount: Int
    public var releasedCount: Int
    public var expiredCount: Int
    public var totalCount: Int

    public init(
        wakeRequired: Bool,
        activeCount: Int,
        releasedCount: Int,
        expiredCount: Int,
        totalCount: Int
    ) {
        self.wakeRequired = wakeRequired
        self.activeCount = activeCount
        self.releasedCount = releasedCount
        self.expiredCount = expiredCount
        self.totalCount = totalCount
    }
}

/// Stable JSON envelope emitted by the CLI and embedded in MCP tool results.
/// Every top-level key is encoded, with unavailable payloads represented by null.
public struct LeaseCommandResponse: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var ok: Bool
    public var command: String
    public var code: String
    public var message: String
    public var lease: AgentWakeLeaseRecord?
    public var leases: [AgentWakeLeaseRecord]?
    public var status: LeaseStatusSummary?

    public init(
        ok: Bool,
        command: String,
        code: String,
        message: String,
        lease: AgentWakeLeaseRecord? = nil,
        leases: [AgentWakeLeaseRecord]? = nil,
        status: LeaseStatusSummary? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.ok = ok
        self.command = command
        self.code = code
        self.message = message
        self.lease = lease
        self.leases = leases
        self.status = status
    }

    public static func failure(command: String, code: String, message: String) -> Self {
        Self(ok: false, command: command, code: code, message: message)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ok, command, code, message, lease, leases, status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(ok, forKey: .ok)
        try container.encode(command, forKey: .command)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        if let lease { try container.encode(lease, forKey: .lease) }
        else { try container.encodeNil(forKey: .lease) }
        if let leases { try container.encode(leases, forKey: .leases) }
        else { try container.encodeNil(forKey: .leases) }
        if let status { try container.encode(status, forKey: .status) }
        else { try container.encodeNil(forKey: .status) }
    }
}

/// Deterministic lease-response encoding for scripts and protocol adapters.
public enum LeaseJSON {
    public static func encode(_ response: LeaseCommandResponse, prettyPrinted: Bool = true) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(response) else { return nil }
        if prettyPrinted { data.append(0x0A) }
        return data
    }
}

/// The small command seam used by the CLI executable and MCP server.
public protocol LeaseCommanding: AnyObject {
    func execute(_ command: LeaseCommand) -> LeaseCommandResponse
}

/// Atomic read, modify, and write access to persisted leases.
public protocol LeaseRecordStoring: AnyObject {
    func update(_ transform: (inout [AgentWakeLeaseRecord]) throws -> Void) throws
}

public enum LeaseFileStoreError: Error, LocalizedError {
    case cannotOpenLock
    case cannotLock
    case invalidDocument

    public var errorDescription: String? {
        switch self {
        case .cannotOpenLock: return "Could not open the lease store lock."
        case .cannotLock: return "Could not lock the lease store."
        case .invalidDocument: return "The lease store is not valid JSON."
        }
    }
}

private struct LeaseFileDocument: Codable {
    var schemaVersion: Int
    var leases: [AgentWakeLeaseRecord]

    init(leases: [AgentWakeLeaseRecord]) {
        schemaVersion = 1
        self.leases = leases
    }
}

/// A standalone JSON lease store shared by `keepresso` and `keepresso-mcp`.
/// A sibling advisory-lock file protects read-modify-write cycles across processes.
public final class JSONLeaseFileStore: LeaseRecordStoring {
    public let fileURL: URL
    private let lockURL: URL

    public init(fileURL: URL = JSONLeaseFileStore.defaultURL()) {
        self.fileURL = fileURL
        self.lockURL = fileURL.appendingPathExtension("lock")
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keepresso", isDirectory: true)
            .appendingPathComponent("wake-leases.json", isDirectory: false)
    }

    public func update(_ transform: (inout [AgentWakeLeaseRecord]) throws -> Void) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LeaseFileStoreError.cannotOpenLock }
        defer { Darwin.close(descriptor) }
        var lock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        guard fcntl(descriptor, F_SETLKW, &lock) == 0 else {
            throw LeaseFileStoreError.cannotLock
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = fcntl(descriptor, F_SETLK, &lock)
        }

        var leases = try loadUnlocked()
        try transform(&leases)
        try encodeDocument(leases).write(to: fileURL, options: .atomic)
    }

    private func loadUnlocked() throws -> [AgentWakeLeaseRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw LeaseFileStoreError.invalidDocument
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(LeaseFileDocument.self, from: data),
              document.schemaVersion == 1
        else { throw LeaseFileStoreError.invalidDocument }
        return document.leases
    }

    private func encodeDocument(_ leases: [AgentWakeLeaseRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(LeaseFileDocument(leases: leases))
    }
}

/// Default lease command implementation over the standalone JSON store.
public final class FileLeaseCommander: LeaseCommanding {
    public static let defaultTTLSeconds = 5 * 60
    public static let defaultMaxLifetimeSeconds = 24 * 60 * 60

    private let store: LeaseRecordStoring
    private let now: () -> Date
    private let makeID: () -> String

    public init(
        store: LeaseRecordStoring = JSONLeaseFileStore(),
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.now = now
        self.makeID = makeID
    }

    public func execute(_ command: LeaseCommand) -> LeaseCommandResponse {
        let instant = now()
        do {
            switch command {
            case .acquire(let owner, let agent, let task, let ttl, let maxLifetime, let message):
                return try acquire(
                    owner: owner,
                    agent: agent,
                    task: task,
                    ttlSeconds: ttl ?? Self.defaultTTLSeconds,
                    maxLifetimeSeconds: maxLifetime ?? Self.defaultMaxLifetimeSeconds,
                    message: message,
                    at: instant
                )
            case .renew(let id, let ttl, let message):
                return try extend(id: id, ttlSeconds: ttl, message: message, operation: "renew", at: instant)
            case .heartbeat(let id, let ttl, let message):
                return try extend(id: id, ttlSeconds: ttl, message: message, operation: "heartbeat", at: instant)
            case .release(let id, let result, let message):
                return try release(id: id, result: result, message: message, at: instant)
            case .list(let filter):
                return try list(filter: filter, at: instant)
            case .status(let id):
                return try status(id: id, at: instant)
            }
        } catch {
            return .failure(
                command: command.operation,
                code: "store_error",
                message: error.localizedDescription
            )
        }
    }

    private func acquire(
        owner: String,
        agent: String,
        task: String,
        ttlSeconds: Int,
        maxLifetimeSeconds: Int,
        message: String?,
        at instant: Date
    ) throws -> LeaseCommandResponse {
        guard isPresent(owner), isPresent(agent), isPresent(task) else {
            return .failure(
                command: "acquire", code: "invalid_arguments",
                message: "owner, agent, and task must be non-empty."
            )
        }
        guard ttlSeconds > 0, maxLifetimeSeconds > 0, ttlSeconds <= maxLifetimeSeconds else {
            return .failure(
                command: "acquire", code: "invalid_arguments",
                message: "ttl must be positive and no greater than max-lifetime."
            )
        }

        var acquired: AgentWakeLeaseRecord?
        var snapshot: [AgentWakeLeaseRecord] = []
        try store.update { leases in
            Self.expireLeases(&leases, at: instant)
            let maxExpiry = instant.addingTimeInterval(TimeInterval(maxLifetimeSeconds))
            let expiry = min(
                instant.addingTimeInterval(TimeInterval(ttlSeconds)),
                maxExpiry
            )
            let lease = AgentWakeLeaseRecord(
                id: makeID(),
                owner: owner,
                agent: agent,
                task: task,
                ttlSeconds: ttlSeconds,
                maxLifetimeSeconds: maxLifetimeSeconds,
                acquiredAt: instant,
                renewedAt: instant,
                expiresAt: expiry,
                maxExpiresAt: maxExpiry,
                message: message
            )
            leases.append(lease)
            acquired = lease
            snapshot = leases
        }
        return LeaseCommandResponse(
            ok: true,
            command: "acquire",
            code: "ok",
            message: "Wake lease acquired.",
            lease: acquired,
            status: Self.summary(snapshot)
        )
    }

    private func extend(
        id: String,
        ttlSeconds: Int?,
        message: String?,
        operation: String,
        at instant: Date
    ) throws -> LeaseCommandResponse {
        guard isPresent(id), ttlSeconds == nil || ttlSeconds! > 0 else {
            return .failure(
                command: operation, code: "invalid_arguments",
                message: "lease id and ttl must be valid."
            )
        }
        var found: AgentWakeLeaseRecord?
        var failure: LeaseCommandResponse?
        var snapshot: [AgentWakeLeaseRecord] = []
        try store.update { leases in
            Self.expireLeases(&leases, at: instant)
            guard let index = leases.firstIndex(where: { $0.id == id }) else {
                failure = .failure(command: operation, code: "not_found", message: "Wake lease not found.")
                snapshot = leases
                return
            }
            guard leases[index].state == .active else {
                failure = .failure(
                    command: operation,
                    code: leases[index].state == .expired ? "expired" : "not_active",
                    message: leases[index].state == .expired
                        ? "Wake lease has expired."
                        : "Wake lease is not active."
                )
                found = leases[index]
                snapshot = leases
                return
            }
            let ttl = ttlSeconds ?? leases[index].ttlSeconds
            let expiry = min(
                instant.addingTimeInterval(TimeInterval(ttl)),
                leases[index].maxExpiresAt
            )
            guard expiry > instant else {
                leases[index].state = .expired
                leases[index].result = .timeout
                failure = .failure(command: operation, code: "expired", message: "Wake lease has expired.")
                found = leases[index]
                snapshot = leases
                return
            }
            leases[index].ttlSeconds = ttl
            leases[index].renewedAt = instant
            leases[index].expiresAt = expiry
            if let message { leases[index].message = message }
            found = leases[index]
            snapshot = leases
        }
        if var failure {
            failure.lease = found
            failure.status = Self.summary(snapshot)
            return failure
        }
        return LeaseCommandResponse(
            ok: true,
            command: operation,
            code: "ok",
            message: operation == "heartbeat" ? "Wake lease heartbeat accepted." : "Wake lease renewed.",
            lease: found,
            status: Self.summary(snapshot)
        )
    }

    private func release(
        id: String,
        result: LeaseCompletionResult,
        message: String?,
        at instant: Date
    ) throws -> LeaseCommandResponse {
        guard isPresent(id) else {
            return .failure(command: "release", code: "invalid_arguments", message: "lease id is required.")
        }
        var found: AgentWakeLeaseRecord?
        var missing = false
        var snapshot: [AgentWakeLeaseRecord] = []
        try store.update { leases in
            Self.expireLeases(&leases, at: instant)
            guard let index = leases.firstIndex(where: { $0.id == id }) else {
                missing = true
                snapshot = leases
                return
            }
            if leases[index].state == .active {
                leases[index].state = .released
                leases[index].releasedAt = instant
                leases[index].result = result
                if let message { leases[index].message = message }
            }
            found = leases[index]
            snapshot = leases
        }
        if missing {
            return .failure(command: "release", code: "not_found", message: "Wake lease not found.")
        }
        return LeaseCommandResponse(
            ok: true,
            command: "release",
            code: "ok",
            message: "Wake lease released.",
            lease: found,
            status: Self.summary(snapshot)
        )
    }

    private func list(filter: LeaseListFilter, at instant: Date) throws -> LeaseCommandResponse {
        var matching: [AgentWakeLeaseRecord] = []
        var snapshot: [AgentWakeLeaseRecord] = []
        try store.update { leases in
            Self.expireLeases(&leases, at: instant)
            matching = leases.filter { lease in
                (filter.includeInactive || lease.state == .active)
                    && (filter.owner == nil || lease.owner == filter.owner)
                    && (filter.agent == nil || lease.agent == filter.agent)
                    && (filter.task == nil || lease.task == filter.task)
            }
            snapshot = leases
        }
        return LeaseCommandResponse(
            ok: true,
            command: "list",
            code: "ok",
            message: "Wake leases listed.",
            leases: matching,
            status: Self.summary(snapshot)
        )
    }

    private func status(id: String?, at instant: Date) throws -> LeaseCommandResponse {
        var found: AgentWakeLeaseRecord?
        var snapshot: [AgentWakeLeaseRecord] = []
        try store.update { leases in
            Self.expireLeases(&leases, at: instant)
            if let id { found = leases.first(where: { $0.id == id }) }
            snapshot = leases
        }
        if id != nil, found == nil {
            var response = LeaseCommandResponse.failure(
                command: "status", code: "not_found", message: "Wake lease not found."
            )
            response.status = Self.summary(snapshot)
            return response
        }
        return LeaseCommandResponse(
            ok: true,
            command: "status",
            code: "ok",
            message: id == nil ? "Wake lease status reported." : "Wake lease found.",
            lease: found,
            status: Self.summary(snapshot)
        )
    }

    private func isPresent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func expireLeases(_ leases: inout [AgentWakeLeaseRecord], at instant: Date) {
        for index in leases.indices where leases[index].state == .active {
            if instant >= leases[index].expiresAt || instant >= leases[index].maxExpiresAt {
                leases[index].state = .expired
                leases[index].result = .timeout
            }
        }
    }

    private static func summary(_ leases: [AgentWakeLeaseRecord]) -> LeaseStatusSummary {
        let active = leases.count { $0.state == .active }
        let released = leases.count { $0.state == .released }
        let expired = leases.count { $0.state == .expired }
        return LeaseStatusSummary(
            wakeRequired: active > 0,
            activeCount: active,
            releasedCount: released,
            expiredCount: expired,
            totalCount: leases.count
        )
    }
}

/// Strict parser for the `keepresso lease` command group.
public enum LeaseCLIParser {
    public static func parse(_ arguments: [String]) throws -> LeaseCommand {
        guard let verb = arguments.first else {
            throw CLIUsageError("lease needs a command: acquire, renew, heartbeat, release, list, or status")
        }
        let rest = Array(arguments.dropFirst())
        switch verb {
        case "acquire": return try parseAcquire(rest)
        case "renew": return try parseExtend(rest, heartbeat: false)
        case "heartbeat": return try parseExtend(rest, heartbeat: true)
        case "release": return try parseRelease(rest)
        case "list": return try parseList(rest)
        case "status": return try parseStatus(rest)
        default: throw CLIUsageError("unknown lease command '\(verb)'")
        }
    }

    private static func parseAcquire(_ arguments: [String]) throws -> LeaseCommand {
        var options = try parseOptions(
            arguments,
            valued: ["--owner", "--agent", "--task", "--ttl", "--max-lifetime", "--message"]
        )
        let owner = try required("--owner", from: &options)
        let agent = try required("--agent", from: &options)
        let task = try required("--task", from: &options)
        let ttl = try positiveInt(take("--ttl", from: &options), name: "--ttl")
        let maxLifetime = try positiveInt(
            take("--max-lifetime", from: &options), name: "--max-lifetime")
        let message = take("--message", from: &options)
        try rejectLeftovers(options)
        return .acquire(
            owner: owner,
            agent: agent,
            task: task,
            ttlSeconds: ttl,
            maxLifetimeSeconds: maxLifetime,
            message: message
        )
    }

    private static func parseExtend(_ arguments: [String], heartbeat: Bool) throws -> LeaseCommand {
        guard let id = arguments.first, !id.hasPrefix("-") else {
            throw CLIUsageError("\(heartbeat ? "heartbeat" : "renew") needs a lease id")
        }
        var options = try parseOptions(
            Array(arguments.dropFirst()), valued: ["--ttl", "--message"])
        let ttl = try positiveInt(take("--ttl", from: &options), name: "--ttl")
        let message = take("--message", from: &options)
        try rejectLeftovers(options)
        return heartbeat
            ? .heartbeat(id: id, ttlSeconds: ttl, message: message)
            : .renew(id: id, ttlSeconds: ttl, message: message)
    }

    private static func parseRelease(_ arguments: [String]) throws -> LeaseCommand {
        guard let id = arguments.first, !id.hasPrefix("-") else {
            throw CLIUsageError("release needs a lease id")
        }
        var options = try parseOptions(
            Array(arguments.dropFirst()), valued: ["--result", "--message"])
        let rawResult = take("--result", from: &options) ?? LeaseCompletionResult.success.rawValue
        guard let result = LeaseCompletionResult(rawValue: rawResult) else {
            throw CLIUsageError("--result must be success, failure, cancelled, or timeout")
        }
        let message = take("--message", from: &options)
        try rejectLeftovers(options)
        return .release(id: id, result: result, message: message)
    }

    private static func parseList(_ arguments: [String]) throws -> LeaseCommand {
        var options = try parseOptions(
            arguments,
            valued: ["--owner", "--agent", "--task"],
            flags: ["--all"]
        )
        let filter = LeaseListFilter(
            owner: take("--owner", from: &options),
            agent: take("--agent", from: &options),
            task: take("--task", from: &options),
            includeInactive: take("--all", from: &options) != nil
        )
        try rejectLeftovers(options)
        return .list(filter)
    }

    private static func parseStatus(_ arguments: [String]) throws -> LeaseCommand {
        guard arguments.count <= 1 else { throw CLIUsageError("status takes at most one lease id") }
        if let id = arguments.first, id.hasPrefix("-") {
            throw CLIUsageError("status takes a lease id without an option name")
        }
        return .status(id: arguments.first)
    }

    /// Parse options into a map. A present flag is stored as "true".
    private static func parseOptions(
        _ arguments: [String],
        valued: Set<String>,
        flags: Set<String> = []
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard valued.contains(option) || flags.contains(option) else {
                throw CLIUsageError("unknown lease option '\(option)'")
            }
            guard result[option] == nil else {
                throw CLIUsageError("lease option '\(option)' was provided more than once")
            }
            if flags.contains(option) {
                result[option] = "true"
                index += 1
            } else {
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("\(option) needs a value")
                }
                let value = arguments[index + 1]
                guard !value.isEmpty else { throw CLIUsageError("\(option) needs a non-empty value") }
                result[option] = value
                index += 2
            }
        }
        return result
    }

    private static func required(_ key: String, from options: inout [String: String]) throws -> String {
        guard let value = options.removeValue(forKey: key),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CLIUsageError("acquire needs \(key)") }
        return value
    }

    private static func take(_ key: String, from options: inout [String: String]) -> String? {
        options.removeValue(forKey: key)
    }

    private static func positiveInt(_ raw: String?, name: String) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw), value > 0 else {
            throw CLIUsageError("\(name) must be a positive whole number of seconds")
        }
        return value
    }

    private static func rejectLeftovers(_ options: [String: String]) throws {
        if let key = options.keys.sorted().first {
            throw CLIUsageError("unused lease option '\(key)'")
        }
    }
}
