import Foundation
import Darwin

/// User and task identity attached to an explicit AI keep-awake lease.
///
/// `owner` is the caller responsible for the lease, such as a Codex task id or
/// a local automation name. `agent` and `task` are optional display metadata.
/// Extra string attributes let future CLI and MCP adapters add identifiers
/// without changing the persisted schema.
public struct AgentLeaseMetadata: Codable, Equatable, Hashable, Sendable {
    public var owner: String
    public var agent: String?
    public var task: String?
    public var attributes: [String: String]

    public init(
        owner: String,
        agent: String? = nil,
        task: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.owner = owner
        self.agent = agent
        self.task = task
        self.attributes = attributes
    }
}

/// The live or terminal state of an explicit AI keep-awake lease.
public enum AgentLeaseState: Equatable, Hashable, Sendable {
    case active
    case success
    case failure(reason: String?)
    case timeout
    case cancelled(reason: String?)

    public var isTerminal: Bool {
        self != .active
    }
}

extension AgentLeaseState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    private enum Kind: String, Codable {
        case active
        case success
        case failure
        case timeout
        case cancelled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .active:
            self = .active
        case .success:
            self = .success
        case .failure:
            self = .failure(reason: try container.decodeIfPresent(String.self, forKey: .reason))
        case .timeout:
            self = .timeout
        case .cancelled:
            self = .cancelled(reason: try container.decodeIfPresent(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .active:
            try container.encode(Kind.active, forKey: .kind)
        case .success:
            try container.encode(Kind.success, forKey: .kind)
        case .failure(let reason):
            try container.encode(Kind.failure, forKey: .kind)
            try container.encodeIfPresent(reason, forKey: .reason)
        case .timeout:
            try container.encode(Kind.timeout, forKey: .kind)
        case .cancelled(let reason):
            try container.encode(Kind.cancelled, forKey: .kind)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

/// A caller-selected terminal result for ``AgentLeaseRegistry/release(_:outcome:)``.
/// Timeout is reserved for the registry watchdog.
public enum AgentLeaseReleaseOutcome: Equatable, Hashable, Sendable {
    case success
    case failure(reason: String?)
    case cancelled(reason: String?)

    fileprivate var state: AgentLeaseState {
        switch self {
        case .success: return .success
        case .failure(let reason): return .failure(reason: reason)
        case .cancelled(let reason): return .cancelled(reason: reason)
        }
    }
}

extension AgentLeaseReleaseOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    private enum Kind: String, Codable {
        case success
        case failure
        case cancelled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .success:
            self = .success
        case .failure:
            self = .failure(reason: try container.decodeIfPresent(String.self, forKey: .reason))
        case .cancelled:
            self = .cancelled(reason: try container.decodeIfPresent(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success:
            try container.encode(Kind.success, forKey: .kind)
        case .failure(let reason):
            try container.encode(Kind.failure, forKey: .kind)
            try container.encodeIfPresent(reason, forKey: .reason)
        case .cancelled(let reason):
            try container.encode(Kind.cancelled, forKey: .kind)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

/// One explicit request from an AI agent to keep the Mac awake.
public struct AgentWakeLease: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var metadata: AgentLeaseMetadata
    public var acquiredAt: Date
    public var heartbeatAt: Date
    public var expiresAt: Date
    /// The TTL applied by a plain heartbeat. A renewal may replace it.
    public var ttl: TimeInterval
    /// Absolute lifetime measured from ``acquiredAt``. Heartbeats never extend it.
    public var maxLifetime: TimeInterval
    public var state: AgentLeaseState
    /// When a terminal state was recorded, or `nil` while active.
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        metadata: AgentLeaseMetadata,
        acquiredAt: Date,
        heartbeatAt: Date,
        expiresAt: Date,
        ttl: TimeInterval,
        maxLifetime: TimeInterval,
        state: AgentLeaseState = .active,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.acquiredAt = acquiredAt
        self.heartbeatAt = heartbeatAt
        self.expiresAt = expiresAt
        self.ttl = ttl
        self.maxLifetime = maxLifetime
        self.state = state
        self.completedAt = completedAt
    }

    public var maxLifetimeAt: Date {
        acquiredAt.addingTimeInterval(maxLifetime)
    }

    public var isActive: Bool {
        state == .active
    }
}

/// The durable JSON payload shared by app, CLI, Skill, or MCP adapters.
public struct AgentLeasePersistenceState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var leases: [AgentWakeLease]

    public init(
        schemaVersion: Int = AgentLeasePersistenceState.currentSchemaVersion,
        leases: [AgentWakeLease] = []
    ) {
        self.schemaVersion = schemaVersion
        self.leases = leases
    }

    public static let empty = AgentLeasePersistenceState()
}

/// Transactional persistence for the explicit lease registry.
///
/// `update` must serialize the load, mutation, and save as one operation. This
/// prevents two separately launched callers from replacing each other's leases.
public protocol AgentLeasePersisting: AnyObject {
    func load() throws -> AgentLeasePersistenceState

    @discardableResult
    func update(
        _ mutation: (inout AgentLeasePersistenceState) throws -> Void
    ) throws -> AgentLeasePersistenceState
}

public enum FileAgentLeaseStoreError: Error, Equatable, Sendable {
    case cannotOpenLock(path: String, errorNumber: Int32)
    case cannotLock(path: String, errorNumber: Int32)
    case unsupportedSchemaVersion(Int)
    case cannotQuarantine(path: String)
}

public enum AgentLeasePersistenceValidationError: Error, Equatable, Sendable {
    case duplicateLeaseID(UUID)
    case invalidLease(UUID)
}

/// Stable JSON codec shared by the app, CLI, Skill, and MCP adapters.
/// The top-level ``AgentLeasePersistenceState/schemaVersion`` is validated on
/// every decode so older binaries never overwrite a future format.
public enum AgentLeaseFileCodec {
    public static func encode(_ state: AgentLeasePersistenceState) throws -> Data {
        try validate(state)
        return try encoder.encode(state)
    }

    public static func decode(_ data: Data) throws -> AgentLeasePersistenceState {
        let state = try decoder.decode(AgentLeasePersistenceState.self, from: data)
        guard state.schemaVersion == AgentLeasePersistenceState.currentSchemaVersion else {
            throw FileAgentLeaseStoreError.unsupportedSchemaVersion(state.schemaVersion)
        }
        try validate(state)
        return state
    }

    private static func validate(_ state: AgentLeasePersistenceState) throws {
        var identifiers: Set<UUID> = []
        for lease in state.leases {
            guard identifiers.insert(lease.id).inserted else {
                throw AgentLeasePersistenceValidationError.duplicateLeaseID(lease.id)
            }
            let owner = lease.metadata.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let timestamps = [
                lease.acquiredAt,
                lease.heartbeatAt,
                lease.expiresAt,
            ] + (lease.completedAt.map { [$0] } ?? [])
            let timestampsAreFinite = timestamps.allSatisfy {
                $0.timeIntervalSinceReferenceDate.isFinite
            }
            let durationsAreSafe = validDuration(lease.ttl)
                && validDuration(lease.maxLifetime)
            let maximumDeadline = lease.maxLifetimeAt
            let ttlDeadline = lease.heartbeatAt.addingTimeInterval(lease.ttl)
            let timelineIsOrdered = lease.heartbeatAt >= lease.acquiredAt
                && lease.expiresAt >= lease.heartbeatAt
                && lease.expiresAt <= min(ttlDeadline, maximumDeadline)
            let completionIsConsistent: Bool
            if lease.isActive {
                completionIsConsistent = lease.completedAt == nil
            } else if let completedAt = lease.completedAt {
                completionIsConsistent = completedAt >= lease.heartbeatAt
            } else {
                completionIsConsistent = false
            }
            guard !owner.isEmpty,
                  timestampsAreFinite,
                  maximumDeadline.timeIntervalSinceReferenceDate.isFinite,
                  ttlDeadline.timeIntervalSinceReferenceDate.isFinite,
                  durationsAreSafe,
                  timelineIsOrdered,
                  completionIsConsistent
            else {
                throw AgentLeasePersistenceValidationError.invalidLease(lease.id)
            }
        }
    }

    private static func validDuration(_ value: TimeInterval) -> Bool {
        value.isFinite
            && value > 0
            && value <= AgentLeaseRegistry.maximumAllowedLifetime
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Unix seconds retain subsecond precision across a write and reload,
        // preventing a local timestamp roundoff from looking like an external
        // heartbeat on the next refresh.
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// One in-process mutex per lease file. `flock` supplies the cross-process
/// boundary; this registry also makes separate store instances in one process
/// serialize before they enter the file-lock path.
private final class AgentLeaseProcessLockRegistry: @unchecked Sendable {
    static let shared = AgentLeaseProcessLockRegistry()

    private let lock = NSLock()
    private var locks: [String: NSLock] = [:]

    func mutex(for path: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = locks[path] { return existing }
        let created = NSLock()
        locks[path] = created
        return created
    }
}

/// JSON lease storage under Application Support.
///
/// Every read-modify-write holds a sibling lock file with `flock`, then writes
/// the JSON atomically. Invalid JSON is moved to a uniquely named `.corrupt`
/// sibling before an empty state is returned, preserving the bad bytes for
/// diagnostics while allowing the registry to recover.
public final class FileAgentLeaseStore: AgentLeasePersisting, @unchecked Sendable {
    public let fileURL: URL
    public let lockURL: URL

    private let fileManager: FileManager
    private let processMutex: NSLock

    /// Stable shared location used by every process that participates in the
    /// explicit lease protocol.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Keepresso", isDirectory: true)
            .appendingPathComponent("wake-leases.json", isDirectory: false)
    }

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultURL(fileManager: fileManager)
        self.lockURL = self.fileURL.appendingPathExtension("lock")
        self.processMutex = AgentLeaseProcessLockRegistry.shared.mutex(for: self.lockURL.path)
    }

    public func load() throws -> AgentLeasePersistenceState {
        try withExclusiveLock {
            try loadLocked()
        }
    }

    @discardableResult
    public func update(
        _ mutation: (inout AgentLeasePersistenceState) throws -> Void
    ) throws -> AgentLeasePersistenceState {
        try withExclusiveLock {
            var state = try loadLocked()
            let original = state
            try mutation(&state)
            state.schemaVersion = AgentLeasePersistenceState.currentSchemaVersion
            if state != original {
                try writeLocked(state)
            }
            return state
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        processMutex.lock()
        defer { processMutex.unlock() }

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw FileAgentLeaseStoreError.cannotOpenLock(
                path: lockURL.path,
                errorNumber: errno
            )
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw FileAgentLeaseStoreError.cannotLock(
                path: lockURL.path,
                errorNumber: errno
            )
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func loadLocked() throws -> AgentLeasePersistenceState {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            try quarantineLocked()
            return .empty
        }

        do {
            return try AgentLeaseFileCodec.decode(data)
        } catch let error as FileAgentLeaseStoreError {
            throw error
        } catch {
            try quarantineLocked()
            return .empty
        }
    }

    private func writeLocked(_ state: AgentLeasePersistenceState) throws {
        let data = try AgentLeaseFileCodec.encode(state)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func quarantineLocked() throws {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let suffix = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        let quarantine = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(stem).corrupt-\(UUID().uuidString).\(suffix)",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: fileURL, to: quarantine)
        } catch {
            throw FileAgentLeaseStoreError.cannotQuarantine(path: fileURL.path)
        }
    }

}

/// Why an active lease reached its watchdog deadline.
public enum AgentLeaseTimeoutCause: String, Codable, Equatable, Hashable, Sendable {
    case ttl
    case maximumLifetime
}

public enum AgentLeaseEventKind: String, Codable, Equatable, Hashable, Sendable {
    case acquired
    case heartbeat
    case renewed
    case released
    case timedOut
    case restored
    case changed
}

/// Whether a lifecycle edge originated in this registry, another process, or
/// restart recovery. Consumers can use this to keep an auditable log when CLI
/// and MCP clients update the shared lease file outside the app process.
public enum AgentLeaseEventSource: String, Codable, Equatable, Hashable, Sendable {
    case local
    case external
    case recovery
}

/// One lifecycle edge emitted after its durable transaction succeeds.
public struct AgentLeaseLifecycleEvent: Codable, Equatable, Sendable {
    public var date: Date
    public var kind: AgentLeaseEventKind
    public var source: AgentLeaseEventSource
    public var lease: AgentWakeLease
    public var previousState: AgentLeaseState?
    public var timeoutCause: AgentLeaseTimeoutCause?

    public init(
        date: Date,
        kind: AgentLeaseEventKind,
        source: AgentLeaseEventSource = .local,
        lease: AgentWakeLease,
        previousState: AgentLeaseState? = nil,
        timeoutCause: AgentLeaseTimeoutCause? = nil
    ) {
        self.date = date
        self.kind = kind
        self.source = source
        self.lease = lease
        self.previousState = previousState
        self.timeoutCause = timeoutCause
    }
}

/// Script-friendly status for all explicit AI wake leases.
public struct AgentLeaseSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var leases: [AgentWakeLease]
    public var activeCount: Int
    public var shouldKeepAwake: Bool
    public var nextDeadline: Date?

    public init(capturedAt: Date, leases: [AgentWakeLease]) {
        self.capturedAt = capturedAt
        self.leases = leases
        let active = leases.filter(\.isActive)
        self.activeCount = active.count
        self.shouldKeepAwake = !active.isEmpty
        self.nextDeadline = active.map { min($0.expiresAt, $0.maxLifetimeAt) }.min()
    }

    public var activeLeases: [AgentWakeLease] {
        leases.filter(\.isActive)
    }
}

public enum AgentLeaseRegistryError: Error, Equatable, Sendable {
    case invalidOwner
    case invalidTTL
    case invalidMaxLifetime
    case invalidTerminalRetentionLimit
    case leaseAlreadyExists(UUID)
    case leaseNotFound(UUID)
    case leaseNotActive(UUID)
}

public typealias AgentLeaseEventHandler = @MainActor (AgentLeaseLifecycleEvent) -> Void
public typealias AgentLeaseSnapshotHandler = @MainActor (AgentLeaseSnapshot) -> Void

/// Main-actor registry for explicit AI keep-awake leases.
///
/// Active leases form a union: ``currentSnapshot/shouldKeepAwake`` remains true
/// until the final active lease reaches a terminal state. The host calls
/// ``watchdogTick()`` from its injected timer, matching SessionController's
/// host-driven reconciliation seam.
@MainActor
public final class AgentLeaseRegistry {
    public nonisolated static let defaultTTL: TimeInterval = 5 * 60
    public nonisolated static let defaultMaxLifetime: TimeInterval = 24 * 60 * 60
    /// Hard safety ceiling for caller-supplied TTLs and maximum lifetimes.
    /// A forgotten lease can therefore never become an effectively permanent
    /// global sleep override, even if a client supplies a mistaken value.
    public nonisolated static let maximumAllowedLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// Maximum completed records kept in the shared file. Active records are
    /// never removed by retention pruning.
    public nonisolated static let defaultTerminalRetentionLimit = 256
    /// Small tolerance for wall-clock correction across process boundaries.
    /// A lease dated further into the future is safer to expire than to let it
    /// move the seven-day ceiling forward.
    private nonisolated static let maximumFutureClockSkew: TimeInterval = 5 * 60

    public var onEvent: AgentLeaseEventHandler?
    public var onSnapshotChange: AgentLeaseSnapshotHandler?
    /// Lifecycle events synthesized while opening durable state. Hosts that
    /// cannot install callbacks until construction finishes can replay these
    /// into notifications and audit logs without losing offline timeouts.
    public private(set) var initialRecoveryEvents: [AgentLeaseLifecycleEvent] = []

    private let persistence: AgentLeasePersisting
    private let now: () -> Date
    private let defaultTTL: TimeInterval
    private let defaultMaxLifetime: TimeInterval
    private let terminalRetentionLimit: Int
    private var persisted: AgentLeasePersistenceState

    public init(
        persistence: AgentLeasePersisting = FileAgentLeaseStore(),
        defaultTTL: TimeInterval = AgentLeaseRegistry.defaultTTL,
        defaultMaxLifetime: TimeInterval = AgentLeaseRegistry.defaultMaxLifetime,
        terminalRetentionLimit: Int = AgentLeaseRegistry.defaultTerminalRetentionLimit,
        now: @escaping () -> Date = Date.init,
        onEvent: AgentLeaseEventHandler? = nil,
        onSnapshotChange: AgentLeaseSnapshotHandler? = nil
    ) throws {
        guard Self.isValidDuration(defaultTTL, atMost: Self.maximumAllowedLifetime) else {
            throw AgentLeaseRegistryError.invalidTTL
        }
        guard Self.isValidDuration(defaultMaxLifetime, atMost: Self.maximumAllowedLifetime) else {
            throw AgentLeaseRegistryError.invalidMaxLifetime
        }
        guard terminalRetentionLimit >= 0 else {
            throw AgentLeaseRegistryError.invalidTerminalRetentionLimit
        }

        self.persistence = persistence
        self.defaultTTL = defaultTTL
        self.defaultMaxLifetime = defaultMaxLifetime
        self.terminalRetentionLimit = terminalRetentionLimit
        self.now = now
        self.onEvent = onEvent
        self.onSnapshotChange = onSnapshotChange
        self.persisted = .empty

        let instant = now()
        var timeoutEvents: [AgentLeaseLifecycleEvent] = []
        let restored = try persistence.update { state in
            timeoutEvents = Self.expireDueLeases(in: &state, at: instant)
            Self.pruneTerminalLeases(in: &state, retaining: terminalRetentionLimit)
        }
        self.persisted = restored

        var recoveryEvents = Self.sorted(restored.leases.filter(\.isActive)).map { lease in
            AgentLeaseLifecycleEvent(
                date: instant,
                kind: .restored,
                source: .recovery,
                lease: lease
            )
        }
        for event in timeoutEvents {
            var recoveryEvent = event
            recoveryEvent.source = .recovery
            recoveryEvents.append(recoveryEvent)
        }
        initialRecoveryEvents = recoveryEvents
        for event in recoveryEvents { onEvent?(event) }
        onSnapshotChange?(makeSnapshot(at: instant))
    }

    /// Last synchronized status without touching disk.
    public var currentSnapshot: AgentLeaseSnapshot {
        makeSnapshot(at: now())
    }

    public var shouldKeepAwake: Bool {
        persisted.leases.contains { $0.isActive }
    }

    /// Acquire a new lease. Supplying an id lets an adapter make retries
    /// idempotent by checking ``status(for:refreshFromDisk:)`` first.
    @discardableResult
    public func acquire(
        id: UUID = UUID(),
        metadata: AgentLeaseMetadata,
        ttl: TimeInterval? = nil,
        maxLifetime: TimeInterval? = nil
    ) throws -> AgentWakeLease {
        guard !metadata.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentLeaseRegistryError.invalidOwner
        }
        let wantedTTL = ttl ?? defaultTTL
        let wantedMaximum = maxLifetime ?? defaultMaxLifetime
        guard Self.isValidDuration(wantedTTL, atMost: Self.maximumAllowedLifetime) else {
            throw AgentLeaseRegistryError.invalidTTL
        }
        guard Self.isValidDuration(wantedMaximum, atMost: Self.maximumAllowedLifetime) else {
            throw AgentLeaseRegistryError.invalidMaxLifetime
        }

        let instant = now()
        var result: AgentWakeLease?
        var operationError: AgentLeaseRegistryError?
        var events: [AgentLeaseLifecycleEvent] = []
        var externallyObserved: AgentLeasePersistenceState?
        let updated = try persistence.update { state in
            externallyObserved = state
            defer {
                Self.pruneTerminalLeases(in: &state, retaining: terminalRetentionLimit)
            }
            events.append(contentsOf: Self.expireDueLeases(in: &state, at: instant))
            guard !state.leases.contains(where: { $0.id == id }) else {
                operationError = .leaseAlreadyExists(id)
                return
            }
            let lease = AgentWakeLease(
                id: id,
                metadata: metadata,
                acquiredAt: instant,
                heartbeatAt: instant,
                expiresAt: min(
                    instant.addingTimeInterval(wantedTTL),
                    instant.addingTimeInterval(wantedMaximum)
                ),
                ttl: wantedTTL,
                maxLifetime: wantedMaximum
            )
            state.leases.append(lease)
            result = lease
            events.append(AgentLeaseLifecycleEvent(date: instant, kind: .acquired, lease: lease))
        }
        adopt(
            updated,
            externallyObserved: externallyObserved ?? updated,
            at: instant,
            events: events
        )
        if let operationError { throw operationError }
        return result!
    }

    /// Convenience acquire overload for callers that do not need attributes.
    @discardableResult
    public func acquire(
        id: UUID = UUID(),
        owner: String,
        agent: String? = nil,
        task: String? = nil,
        ttl: TimeInterval? = nil,
        maxLifetime: TimeInterval? = nil
    ) throws -> AgentWakeLease {
        try acquire(
            id: id,
            metadata: AgentLeaseMetadata(owner: owner, agent: agent, task: task),
            ttl: ttl,
            maxLifetime: maxLifetime
        )
    }

    /// Extend a lease using its existing TTL.
    @discardableResult
    public func heartbeat(
        _ id: UUID,
        message: String? = nil
    ) throws -> AgentWakeLease {
        try updateHeartbeat(
            id,
            newTTL: nil,
            message: message,
            eventKind: .heartbeat
        )
    }

    /// Replace the heartbeat TTL and extend the lease, without changing its
    /// maximum lifetime measured from acquisition.
    @discardableResult
    public func renew(
        _ id: UUID,
        ttl: TimeInterval,
        message: String? = nil
    ) throws -> AgentWakeLease {
        guard Self.isValidDuration(ttl, atMost: Self.maximumAllowedLifetime) else {
            throw AgentLeaseRegistryError.invalidTTL
        }
        return try updateHeartbeat(
            id,
            newTTL: ttl,
            message: message,
            eventKind: .renewed
        )
    }

    /// Move one active lease to a caller-selected terminal state.
    @discardableResult
    public func release(
        _ id: UUID,
        outcome: AgentLeaseReleaseOutcome = .success,
        message: String? = nil
    ) throws -> AgentWakeLease {
        let instant = now()
        var result: AgentWakeLease?
        var operationError: AgentLeaseRegistryError?
        var events: [AgentLeaseLifecycleEvent] = []
        var externallyObserved: AgentLeasePersistenceState?
        let updated = try persistence.update { state in
            externallyObserved = state
            defer {
                Self.pruneTerminalLeases(in: &state, retaining: terminalRetentionLimit)
            }
            events.append(contentsOf: Self.expireDueLeases(in: &state, at: instant))
            guard let index = state.leases.firstIndex(where: { $0.id == id }) else {
                operationError = .leaseNotFound(id)
                return
            }
            guard state.leases[index].isActive else {
                operationError = .leaseNotActive(id)
                return
            }
            let previous = state.leases[index].state
            state.leases[index].state = outcome.state
            state.leases[index].completedAt = instant
            if let message {
                state.leases[index].metadata.attributes["message"] = message
            }
            result = state.leases[index]
            events.append(AgentLeaseLifecycleEvent(
                date: instant,
                kind: .released,
                lease: state.leases[index],
                previousState: previous
            ))
        }
        adopt(
            updated,
            externallyObserved: externallyObserved ?? updated,
            at: instant,
            events: events
        )
        if let operationError { throw operationError }
        return result!
    }

    /// List leases from the latest durable state by default. Pass false for a
    /// pure read of this registry's most recent snapshot.
    public func list(
        includeTerminal: Bool = true,
        refreshFromDisk: Bool = true
    ) throws -> [AgentWakeLease] {
        if refreshFromDisk { _ = try refresh() }
        let leases = includeTerminal ? persisted.leases : persisted.leases.filter(\.isActive)
        return Self.sorted(leases)
    }

    public func status(
        for id: UUID,
        refreshFromDisk: Bool = true
    ) throws -> AgentWakeLease? {
        if refreshFromDisk { _ = try refresh() }
        return persisted.leases.first { $0.id == id }
    }

    /// Reload cross-process changes and apply watchdog deadlines transactionally.
    @discardableResult
    public func refresh() throws -> AgentLeaseSnapshot {
        try reconcileDeadlines()
    }

    /// Host-driven TTL and maximum-lifetime watchdog tick.
    @discardableResult
    public func watchdogTick() throws -> AgentLeaseSnapshot {
        try reconcileDeadlines()
    }

    private func updateHeartbeat(
        _ id: UUID,
        newTTL: TimeInterval?,
        message: String?,
        eventKind: AgentLeaseEventKind
    ) throws -> AgentWakeLease {
        let instant = now()
        var result: AgentWakeLease?
        var operationError: AgentLeaseRegistryError?
        var events: [AgentLeaseLifecycleEvent] = []
        var externallyObserved: AgentLeasePersistenceState?
        let updated = try persistence.update { state in
            externallyObserved = state
            defer {
                Self.pruneTerminalLeases(in: &state, retaining: terminalRetentionLimit)
            }
            events.append(contentsOf: Self.expireDueLeases(in: &state, at: instant))
            guard let index = state.leases.firstIndex(where: { $0.id == id }) else {
                operationError = .leaseNotFound(id)
                return
            }
            guard state.leases[index].isActive else {
                operationError = .leaseNotActive(id)
                return
            }
            if let newTTL { state.leases[index].ttl = newTTL }
            if let message {
                state.leases[index].metadata.attributes["message"] = message
            }
            state.leases[index].heartbeatAt = instant
            state.leases[index].expiresAt = min(
                instant.addingTimeInterval(state.leases[index].ttl),
                state.leases[index].maxLifetimeAt
            )
            result = state.leases[index]
            events.append(AgentLeaseLifecycleEvent(
                date: instant,
                kind: eventKind,
                lease: state.leases[index],
                previousState: .active
            ))
        }
        adopt(
            updated,
            externallyObserved: externallyObserved ?? updated,
            at: instant,
            events: events
        )
        if let operationError { throw operationError }
        return result!
    }

    private func reconcileDeadlines() throws -> AgentLeaseSnapshot {
        let instant = now()
        var events: [AgentLeaseLifecycleEvent] = []
        var externallyObserved: AgentLeasePersistenceState?
        let updated = try persistence.update { state in
            externallyObserved = state
            defer {
                Self.pruneTerminalLeases(in: &state, retaining: terminalRetentionLimit)
            }
            events = Self.expireDueLeases(in: &state, at: instant)
        }
        adopt(
            updated,
            externallyObserved: externallyObserved ?? updated,
            at: instant,
            events: events
        )
        return makeSnapshot(at: instant)
    }

    private func adopt(
        _ updated: AgentLeasePersistenceState,
        externallyObserved: AgentLeasePersistenceState,
        at instant: Date,
        events: [AgentLeaseLifecycleEvent]
    ) {
        let changed = updated != persisted
        let externalEvents = Self.externalLifecycleEvents(
            from: persisted,
            to: externallyObserved,
            discoveredAt: instant
        )
        persisted = updated
        for event in externalEvents { onEvent?(event) }
        for event in events { onEvent?(event) }
        if changed { onSnapshotChange?(makeSnapshot(at: instant)) }
    }

    private func makeSnapshot(at instant: Date) -> AgentLeaseSnapshot {
        AgentLeaseSnapshot(capturedAt: instant, leases: Self.sorted(persisted.leases))
    }

    private static func expireDueLeases(
        in state: inout AgentLeasePersistenceState,
        at instant: Date
    ) -> [AgentLeaseLifecycleEvent] {
        var events: [AgentLeaseLifecycleEvent] = []
        for index in state.leases.indices where state.leases[index].isActive {
            let lease = state.leases[index]
            let latestToleratedTimestamp = instant.addingTimeInterval(maximumFutureClockSkew)
            let latestSafeDeadline = instant.addingTimeInterval(maximumAllowedLifetime)
            let effectiveDeadline = min(lease.expiresAt, lease.maxLifetimeAt)
            let cause: AgentLeaseTimeoutCause?
            if lease.acquiredAt > latestToleratedTimestamp
                || lease.heartbeatAt > latestToleratedTimestamp
                || effectiveDeadline > latestSafeDeadline {
                cause = .maximumLifetime
            } else if instant >= lease.maxLifetimeAt {
                cause = .maximumLifetime
            } else if instant >= lease.expiresAt {
                cause = .ttl
            } else {
                cause = nil
            }
            guard let cause else { continue }
            let previous = state.leases[index].state
            state.leases[index].state = .timeout
            state.leases[index].completedAt = instant
            events.append(AgentLeaseLifecycleEvent(
                date: instant,
                kind: .timedOut,
                lease: state.leases[index],
                previousState: previous,
                timeoutCause: cause
            ))
        }
        return events
    }

    private static func pruneTerminalLeases(
        in state: inout AgentLeasePersistenceState,
        retaining limit: Int
    ) {
        let terminal = state.leases.filter { $0.state.isTerminal }
        guard terminal.count > limit else { return }
        let retainedIDs = Set(terminal.sorted {
            let firstDate = $0.completedAt ?? $0.acquiredAt
            let secondDate = $1.completedAt ?? $1.acquiredAt
            if firstDate != secondDate { return firstDate > secondDate }
            return $0.id.uuidString > $1.id.uuidString
        }.prefix(limit).map(\.id))
        state.leases.removeAll {
            $0.state.isTerminal && !retainedIDs.contains($0.id)
        }
    }

    /// Infer lifecycle edges applied by another process since this registry's
    /// previous snapshot. File transactions are serialized, but callbacks are
    /// process-local, so a reload must surface those edges explicitly.
    private static func externalLifecycleEvents(
        from previous: AgentLeasePersistenceState,
        to updated: AgentLeasePersistenceState,
        discoveredAt instant: Date
    ) -> [AgentLeaseLifecycleEvent] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.leases.map { ($0.id, $0) })
        var events: [AgentLeaseLifecycleEvent] = []

        for lease in sorted(updated.leases) {
            let prior = previousByID[lease.id]
            guard prior != lease else { continue }

            if prior == nil {
                var activeVersion = lease
                activeVersion.state = .active
                activeVersion.completedAt = nil
                activeVersion.heartbeatAt = lease.acquiredAt
                activeVersion.expiresAt = min(
                    lease.acquiredAt.addingTimeInterval(lease.ttl),
                    lease.maxLifetimeAt
                )
                events.append(AgentLeaseLifecycleEvent(
                    date: lease.acquiredAt,
                    kind: .acquired,
                    source: .external,
                    lease: activeVersion
                ))

                if lease.heartbeatAt > lease.acquiredAt {
                    var heartbeatVersion = lease
                    heartbeatVersion.state = .active
                    heartbeatVersion.completedAt = nil
                    events.append(AgentLeaseLifecycleEvent(
                        date: lease.heartbeatAt,
                        kind: .heartbeat,
                        source: .external,
                        lease: heartbeatVersion,
                        previousState: .active
                    ))
                }

                if lease.state == .timeout {
                    events.append(AgentLeaseLifecycleEvent(
                        date: lease.completedAt ?? instant,
                        kind: .timedOut,
                        source: .external,
                        lease: lease,
                        previousState: .active,
                        timeoutCause: timeoutCause(for: lease)
                    ))
                } else if lease.state.isTerminal {
                    events.append(AgentLeaseLifecycleEvent(
                        date: lease.completedAt ?? instant,
                        kind: .released,
                        source: .external,
                        lease: lease,
                        previousState: .active
                    ))
                }
                continue
            }

            let kind: AgentLeaseEventKind
            let date: Date
            let inferredTimeoutCause: AgentLeaseTimeoutCause?
            if prior?.isActive == true, lease.isActive {
                kind = prior?.ttl == lease.ttl ? .heartbeat : .renewed
                date = lease.heartbeatAt
                inferredTimeoutCause = nil
            } else if prior?.isActive == true, lease.state == .timeout {
                kind = .timedOut
                date = lease.completedAt ?? instant
                inferredTimeoutCause = timeoutCause(for: lease)
            } else if prior?.isActive == true, lease.state.isTerminal {
                kind = .released
                date = lease.completedAt ?? instant
                inferredTimeoutCause = nil
            } else {
                kind = .changed
                date = instant
                inferredTimeoutCause = nil
            }

            events.append(AgentLeaseLifecycleEvent(
                date: date,
                kind: kind,
                source: .external,
                lease: lease,
                previousState: prior?.state,
                timeoutCause: inferredTimeoutCause
            ))
        }
        return events.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.lease.id != $1.lease.id {
                return $0.lease.id.uuidString < $1.lease.id.uuidString
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private static func timeoutCause(for lease: AgentWakeLease) -> AgentLeaseTimeoutCause {
        guard let completedAt = lease.completedAt else { return .ttl }
        return completedAt >= lease.maxLifetimeAt ? .maximumLifetime : .ttl
    }

    private static func sorted(_ leases: [AgentWakeLease]) -> [AgentWakeLease] {
        leases.sorted {
            if $0.acquiredAt != $1.acquiredAt { return $0.acquiredAt < $1.acquiredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func isValidDuration(
        _ value: TimeInterval,
        atMost maximum: TimeInterval
    ) -> Bool {
        value.isFinite && value > 0 && value <= maximum
    }
}
