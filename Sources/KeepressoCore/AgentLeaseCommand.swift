import Foundation

/// A transport-neutral command for explicit AI wake leases.
///
/// CLI, Skill, and MCP adapters can decode this model and hand it to
/// ``AgentLeaseCommandService`` without reaching into registry persistence or
/// reproducing lifecycle rules.
public enum AgentLeaseCommand: Equatable, Sendable {
    case acquire(
        id: UUID?,
        metadata: AgentLeaseMetadata,
        ttl: TimeInterval?,
        maxLifetime: TimeInterval?
    )
    case heartbeat(id: UUID, message: String?)
    case renew(id: UUID, ttl: TimeInterval, message: String?)
    case release(id: UUID, outcome: AgentLeaseReleaseOutcome, message: String?)
    case list(includeTerminal: Bool)
    case status(id: UUID)
    case snapshot
}

extension AgentLeaseCommand: Codable {
    private enum Action: String, Codable {
        case acquire
        case heartbeat
        case renew
        case release
        case list
        case status
        case snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case id
        case metadata
        case ttl
        case maxLifetime
        case outcome
        case message
        case includeTerminal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(Action.self, forKey: .action)
        switch action {
        case .acquire:
            self = .acquire(
                id: try container.decodeIfPresent(UUID.self, forKey: .id),
                metadata: try container.decode(AgentLeaseMetadata.self, forKey: .metadata),
                ttl: try container.decodeIfPresent(TimeInterval.self, forKey: .ttl),
                maxLifetime: try container.decodeIfPresent(TimeInterval.self, forKey: .maxLifetime)
            )
        case .heartbeat:
            self = .heartbeat(
                id: try container.decode(UUID.self, forKey: .id),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case .renew:
            self = .renew(
                id: try container.decode(UUID.self, forKey: .id),
                ttl: try container.decode(TimeInterval.self, forKey: .ttl),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case .release:
            self = .release(
                id: try container.decode(UUID.self, forKey: .id),
                outcome: try container.decode(AgentLeaseReleaseOutcome.self, forKey: .outcome),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case .list:
            self = .list(
                includeTerminal: try container.decodeIfPresent(Bool.self, forKey: .includeTerminal) ?? true
            )
        case .status:
            self = .status(id: try container.decode(UUID.self, forKey: .id))
        case .snapshot:
            self = .snapshot
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .acquire(let id, let metadata, let ttl, let maxLifetime):
            try container.encode(Action.acquire, forKey: .action)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(metadata, forKey: .metadata)
            try container.encodeIfPresent(ttl, forKey: .ttl)
            try container.encodeIfPresent(maxLifetime, forKey: .maxLifetime)
        case .heartbeat(let id, let message):
            try container.encode(Action.heartbeat, forKey: .action)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(message, forKey: .message)
        case .renew(let id, let ttl, let message):
            try container.encode(Action.renew, forKey: .action)
            try container.encode(id, forKey: .id)
            try container.encode(ttl, forKey: .ttl)
            try container.encodeIfPresent(message, forKey: .message)
        case .release(let id, let outcome, let message):
            try container.encode(Action.release, forKey: .action)
            try container.encode(id, forKey: .id)
            try container.encode(outcome, forKey: .outcome)
            try container.encodeIfPresent(message, forKey: .message)
        case .list(let includeTerminal):
            try container.encode(Action.list, forKey: .action)
            try container.encode(includeTerminal, forKey: .includeTerminal)
        case .status(let id):
            try container.encode(Action.status, forKey: .action)
            try container.encode(id, forKey: .id)
        case .snapshot:
            try container.encode(Action.snapshot, forKey: .action)
        }
    }
}

public extension AgentLeaseCommand {
    static func heartbeat(id: UUID) -> Self {
        .heartbeat(id: id, message: nil)
    }

    static func renew(id: UUID, ttl: TimeInterval) -> Self {
        .renew(id: id, ttl: ttl, message: nil)
    }

    static func release(id: UUID, outcome: AgentLeaseReleaseOutcome) -> Self {
        .release(id: id, outcome: outcome, message: nil)
    }
}

/// The typed result of an ``AgentLeaseCommand``.
public enum AgentLeaseCommandResponse: Equatable, Sendable {
    case lease(AgentWakeLease)
    case leases([AgentWakeLease])
    case status(AgentWakeLease?)
    case snapshot(AgentLeaseSnapshot)
}

extension AgentLeaseCommandResponse: Codable {
    private enum Kind: String, Codable {
        case lease
        case leases
        case status
        case snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case lease
        case leases
        case snapshot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .lease:
            self = .lease(try container.decode(AgentWakeLease.self, forKey: .lease))
        case .leases:
            self = .leases(try container.decode([AgentWakeLease].self, forKey: .leases))
        case .status:
            self = .status(try container.decodeIfPresent(AgentWakeLease.self, forKey: .lease))
        case .snapshot:
            self = .snapshot(try container.decode(AgentLeaseSnapshot.self, forKey: .snapshot))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lease(let lease):
            try container.encode(Kind.lease, forKey: .kind)
            try container.encode(lease, forKey: .lease)
        case .leases(let leases):
            try container.encode(Kind.leases, forKey: .kind)
            try container.encode(leases, forKey: .leases)
        case .status(let lease):
            try container.encode(Kind.status, forKey: .kind)
            try container.encodeIfPresent(lease, forKey: .lease)
        case .snapshot(let snapshot):
            try container.encode(Kind.snapshot, forKey: .kind)
            try container.encode(snapshot, forKey: .snapshot)
        }
    }
}

@MainActor
public protocol AgentLeaseCommandServing: AnyObject {
    func execute(_ command: AgentLeaseCommand) throws -> AgentLeaseCommandResponse
}

/// Non-UI application service shared by command adapters.
@MainActor
public final class AgentLeaseCommandService: AgentLeaseCommandServing {
    private let registry: AgentLeaseRegistry

    public init(registry: AgentLeaseRegistry) {
        self.registry = registry
    }

    public convenience init(
        persistence: AgentLeasePersisting = FileAgentLeaseStore(),
        defaultTTL: TimeInterval = AgentLeaseRegistry.defaultTTL,
        defaultMaxLifetime: TimeInterval = AgentLeaseRegistry.defaultMaxLifetime,
        terminalRetentionLimit: Int = AgentLeaseRegistry.defaultTerminalRetentionLimit,
        now: @escaping () -> Date = Date.init,
        onEvent: AgentLeaseEventHandler? = nil,
        onSnapshotChange: AgentLeaseSnapshotHandler? = nil
    ) throws {
        try self.init(registry: AgentLeaseRegistry(
            persistence: persistence,
            defaultTTL: defaultTTL,
            defaultMaxLifetime: defaultMaxLifetime,
            terminalRetentionLimit: terminalRetentionLimit,
            now: now,
            onEvent: onEvent,
            onSnapshotChange: onSnapshotChange
        ))
    }

    public func execute(_ command: AgentLeaseCommand) throws -> AgentLeaseCommandResponse {
        switch command {
        case .acquire(let id, let metadata, let ttl, let maxLifetime):
            let wantedID = id ?? UUID()
            do {
                return .lease(try registry.acquire(
                    id: wantedID,
                    metadata: metadata,
                    ttl: ttl,
                    maxLifetime: maxLifetime
                ))
            } catch AgentLeaseRegistryError.leaseAlreadyExists where id != nil {
                // A caller-selected identifier makes acquire safe to retry
                // after a response is lost. Return the same active lease only
                // when the full supplied request agrees, otherwise surface a
                // conflict instead of silently adopting unrelated work.
                guard let existing = try registry.status(for: wantedID),
                      existing.isActive,
                      existing.metadata == metadata,
                      ttl == nil || existing.ttl == ttl,
                      maxLifetime == nil || existing.maxLifetime == maxLifetime
                else {
                    throw AgentLeaseRegistryError.leaseAlreadyExists(wantedID)
                }
                return .lease(existing)
            }
        case .heartbeat(let id, let message):
            return .lease(try registry.heartbeat(id, message: message))
        case .renew(let id, let ttl, let message):
            return .lease(try registry.renew(id, ttl: ttl, message: message))
        case .release(let id, let outcome, let message):
            return .lease(try registry.release(id, outcome: outcome, message: message))
        case .list(let includeTerminal):
            return .leases(try registry.list(includeTerminal: includeTerminal))
        case .status(let id):
            return .status(try registry.status(for: id))
        case .snapshot:
            return .snapshot(try registry.refresh())
        }
    }
}
