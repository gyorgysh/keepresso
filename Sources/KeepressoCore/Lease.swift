import CoreFoundation
import Foundation

/// Stable transport result for a terminal lease. Callers may release with
/// success, failure, or cancellation. Timeout is emitted only by the watchdog.
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
@MainActor
public protocol LeaseCommanding: AnyObject {
    func execute(_ command: LeaseCommand) -> LeaseCommandResponse
}

/// Cross-process signal sent after a lease mutation commits.
@MainActor
public protocol AgentLeaseAppSignaling: AnyObject {
    func leaseStateDidChange(launchIfNeeded: Bool)
}

/// Wakes the menu-bar app for new work and posts a Darwin notification for
/// every mutation. Child process output is discarded so CLI and MCP stdout
/// remain reserved for their machine-readable protocols.
@MainActor
public final class SystemAgentLeaseAppSignaler: AgentLeaseAppSignaling {
    public nonisolated static let appBundleIdentifier = "sh.gyorgy.keepresso"
    public nonisolated static let notificationName = "sh.gyorgy.keepresso.agent-lease-changed"

    public init() {}

    public func leaseStateDidChange(launchIfNeeded: Bool) {
        if launchIfNeeded {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", "-b", Self.appBundleIdentifier]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // The lease is already durable. App launch is best effort so a
                // missing bundle cannot turn a successful mutation into a lie.
            }
        }

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}

/// CLI and MCP adapter over the authoritative lease command service.
///
/// This type deliberately contains no persistence and no deadline logic. It
/// only validates transport values, maps stable DTOs, and signals the app after
/// a durable lifecycle mutation succeeds.
@MainActor
public final class AgentLeaseCommandAdapter: LeaseCommanding {
    private let service: AgentLeaseCommandServing
    private let appSignaler: AgentLeaseAppSignaling

    public init(
        service: AgentLeaseCommandServing,
        appSignaler: AgentLeaseAppSignaling
    ) {
        self.service = service
        self.appSignaler = appSignaler
    }

    public convenience init(
        persistence: AgentLeasePersisting,
        appSignaler: AgentLeaseAppSignaling
    ) throws {
        try self.init(
            service: AgentLeaseCommandService(persistence: persistence),
            appSignaler: appSignaler
        )
    }

    public convenience init(
        persistence: AgentLeasePersisting = FileAgentLeaseStore()
    ) throws {
        try self.init(
            persistence: persistence,
            appSignaler: SystemAgentLeaseAppSignaler()
        )
    }

    public func execute(_ command: LeaseCommand) -> LeaseCommandResponse {
        do {
            switch command {
            case .acquire(let owner, let agent, let task, let ttl, let maximum, let message):
                var attributes: [String: String] = [:]
                if let message { attributes["message"] = message }
                let response = try service.execute(.acquire(
                    id: nil,
                    metadata: AgentLeaseMetadata(
                        owner: owner,
                        agent: agent,
                        task: task,
                        attributes: attributes
                    ),
                    ttl: ttl.map(TimeInterval.init),
                    maxLifetime: maximum.map(TimeInterval.init)
                ))
                let lease = try requireLease(response)
                appSignaler.leaseStateDidChange(launchIfNeeded: true)
                return try success(
                    command: "acquire",
                    message: "Wake lease acquired.",
                    lease: lease
                )

            case .renew(let rawID, let ttl, let message):
                let id = try parseID(rawID)
                let wantedTTL = try ttl.map(TimeInterval.init) ?? existingTTL(for: id)
                let lease = try requireLease(service.execute(.renew(
                    id: id,
                    ttl: wantedTTL,
                    message: message
                )))
                appSignaler.leaseStateDidChange(launchIfNeeded: true)
                return try success(
                    command: "renew",
                    message: "Wake lease renewed.",
                    lease: lease
                )

            case .heartbeat(let rawID, let ttl, let message):
                let id = try parseID(rawID)
                let serviceResponse: AgentLeaseCommandResponse
                if let ttl {
                    serviceResponse = try service.execute(.renew(
                        id: id,
                        ttl: TimeInterval(ttl),
                        message: message
                    ))
                } else {
                    serviceResponse = try service.execute(.heartbeat(id: id, message: message))
                }
                let lease = try requireLease(serviceResponse)
                appSignaler.leaseStateDidChange(launchIfNeeded: true)
                return try success(
                    command: "heartbeat",
                    message: "Wake lease heartbeat accepted.",
                    lease: lease
                )

            case .release(let rawID, let result, let message):
                let id = try parseID(rawID)
                let outcome: AgentLeaseReleaseOutcome
                switch result {
                case .success:
                    outcome = .success
                case .failure:
                    outcome = .failure(reason: message)
                case .cancelled:
                    outcome = .cancelled(reason: message)
                case .timeout:
                    throw LeaseAdapterError.callerCannotDeclareTimeout
                }
                let lease = try requireLease(service.execute(.release(
                    id: id,
                    outcome: outcome,
                    message: message
                )))
                appSignaler.leaseStateDidChange(launchIfNeeded: false)
                return try success(
                    command: "release",
                    message: "Wake lease released.",
                    lease: lease
                )

            case .list(let filter):
                let leases = try requireLeases(service.execute(
                    .list(includeTerminal: filter.includeInactive)
                )).filter { lease in
                    (filter.owner == nil || lease.metadata.owner == filter.owner)
                        && (filter.agent == nil || lease.metadata.agent == filter.agent)
                        && (filter.task == nil || lease.metadata.task == filter.task)
                }
                return try success(
                    command: "list",
                    message: "Wake leases listed.",
                    leases: leases
                )

            case .status(let rawID):
                if let rawID {
                    let id = try parseID(rawID)
                    let lease = try requireStatus(service.execute(.status(id: id)))
                    guard let lease else {
                        return try failureWithStatus(
                            command: "status",
                            code: "not_found",
                            message: "Wake lease not found."
                        )
                    }
                    return try success(
                        command: "status",
                        message: "Wake lease found.",
                        lease: lease
                    )
                }
                return try success(
                    command: "status",
                    message: "Wake lease status reported."
                )
            }
        } catch {
            return failure(command: command.operation, error: error)
        }
    }

    private func success(
        command: String,
        message: String,
        lease: AgentWakeLease? = nil,
        leases: [AgentWakeLease]? = nil
    ) throws -> LeaseCommandResponse {
        let snapshot = try requireSnapshot(service.execute(.snapshot))
        return LeaseCommandResponse(
            ok: true,
            command: command,
            code: "ok",
            message: message,
            lease: lease.map(Self.record),
            leases: leases.map { $0.map(Self.record) },
            status: Self.summary(snapshot.leases)
        )
    }

    private func failureWithStatus(
        command: String,
        code: String,
        message: String
    ) throws -> LeaseCommandResponse {
        let snapshot = try requireSnapshot(service.execute(.snapshot))
        var response = LeaseCommandResponse.failure(command: command, code: code, message: message)
        response.status = Self.summary(snapshot.leases)
        return response
    }

    private func existingTTL(for id: UUID) throws -> TimeInterval {
        guard let lease = try requireStatus(service.execute(.status(id: id))) else {
            throw AgentLeaseRegistryError.leaseNotFound(id)
        }
        return lease.ttl
    }

    private func parseID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw LeaseAdapterError.invalidLeaseID }
        return id
    }

    private func requireLease(_ response: AgentLeaseCommandResponse) throws -> AgentWakeLease {
        guard case .lease(let lease) = response else { throw LeaseAdapterError.unexpectedResponse }
        return lease
    }

    private func requireLeases(_ response: AgentLeaseCommandResponse) throws -> [AgentWakeLease] {
        guard case .leases(let leases) = response else { throw LeaseAdapterError.unexpectedResponse }
        return leases
    }

    private func requireStatus(_ response: AgentLeaseCommandResponse) throws -> AgentWakeLease? {
        guard case .status(let lease) = response else { throw LeaseAdapterError.unexpectedResponse }
        return lease
    }

    private func requireSnapshot(_ response: AgentLeaseCommandResponse) throws -> AgentLeaseSnapshot {
        guard case .snapshot(let snapshot) = response else { throw LeaseAdapterError.unexpectedResponse }
        return snapshot
    }

    private func failure(command: String, error: Error) -> LeaseCommandResponse {
        switch error {
        case LeaseAdapterError.invalidLeaseID:
            return .failure(
                command: command,
                code: "invalid_arguments",
                message: "lease id must be a UUID."
            )
        case LeaseAdapterError.callerCannotDeclareTimeout:
            return .failure(
                command: command,
                code: "invalid_arguments",
                message: "timeout is recorded automatically by the lease watchdog."
            )
        case AgentLeaseRegistryError.invalidOwner,
             AgentLeaseRegistryError.invalidTTL,
             AgentLeaseRegistryError.invalidMaxLifetime:
            return .failure(
                command: command,
                code: "invalid_arguments",
                message: "lease owner and durations must be valid."
            )
        case AgentLeaseRegistryError.leaseNotFound:
            return .failure(command: command, code: "not_found", message: "Wake lease not found.")
        case AgentLeaseRegistryError.leaseNotActive:
            return .failure(command: command, code: "not_active", message: "Wake lease is not active.")
        case AgentLeaseRegistryError.leaseAlreadyExists:
            return .failure(command: command, code: "already_exists", message: "Wake lease already exists.")
        default:
            return .failure(
                command: command,
                code: "store_error",
                message: error.localizedDescription
            )
        }
    }

    private static func record(_ lease: AgentWakeLease) -> AgentWakeLeaseRecord {
        let state: AgentWakeLeaseState
        let result: LeaseCompletionResult?
        let reason: String?
        switch lease.state {
        case .active:
            state = .active
            result = nil
            reason = nil
        case .success:
            state = .released
            result = .success
            reason = nil
        case .failure(let value):
            state = .released
            result = .failure
            reason = value
        case .timeout:
            state = .expired
            result = .timeout
            reason = nil
        case .cancelled(let value):
            state = .released
            result = .cancelled
            reason = value
        }
        return AgentWakeLeaseRecord(
            id: lease.id.uuidString.lowercased(),
            owner: lease.metadata.owner,
            agent: lease.metadata.agent ?? "",
            task: lease.metadata.task ?? "",
            state: state,
            ttlSeconds: Int(lease.ttl),
            maxLifetimeSeconds: Int(lease.maxLifetime),
            acquiredAt: lease.acquiredAt,
            renewedAt: lease.heartbeatAt,
            expiresAt: lease.expiresAt,
            maxExpiresAt: lease.maxLifetimeAt,
            releasedAt: lease.completedAt,
            result: result,
            message: reason ?? lease.metadata.attributes["message"]
        )
    }

    private static func summary(_ leases: [AgentWakeLease]) -> LeaseStatusSummary {
        let active = leases.count { $0.state == .active }
        let expired = leases.count { $0.state == .timeout }
        return LeaseStatusSummary(
            wakeRequired: active > 0,
            activeCount: active,
            releasedCount: leases.count - active - expired,
            expiredCount: expired,
            totalCount: leases.count
        )
    }
}

private enum LeaseAdapterError: Error {
    case invalidLeaseID
    case callerCannotDeclareTimeout
    case unexpectedResponse
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
        guard let result = LeaseCompletionResult(rawValue: rawResult), result != .timeout else {
            throw CLIUsageError("--result must be success, failure, or cancelled")
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
