import Foundation

// MARK: - Record

/// One bounded keep-awake lease granted to an outside tool (an AI agent, a
/// render script, a backup job). The record lives as a small JSON file that
/// the granting process writes and the app polls, mirroring the agent-hooks
/// transport: there is no request/response channel, the file is the message
/// and the persistence at once. TTL expiry on the app's reconcile tick is the
/// sole crash safety net, so a client that dies without releasing can hold
/// the Mac awake for at most one TTL.
public struct AutomationLeaseRecord: Codable, Equatable, Sendable {
    /// The lease's terminal or live state. Clients write `active` and
    /// `released`; the app writes `expired` and `revoked`.
    public enum State: String, Codable, Sendable {
        case active
        case released
        case expired
        case revoked
    }

    /// Caller-supplied UUID, canonical lowercased form. Doubles as the
    /// idempotency key: re-acquiring an active id refreshes it in place.
    public var id: String
    /// Who asked (a user name, a service name). Display only.
    public var owner: String
    /// The tool holding the lease ("claude-code", "ffmpeg-batch"). Display only.
    public var tool: String
    /// One-line task label for the menu. Display only.
    public var task: String
    /// The acquiring process's parent pid, advisory: shown by `lease list`,
    /// never used for reaping (TTL is the safety net).
    public var ownerPid: Int32?
    public var createdAt: Date
    /// Last acquire or heartbeat. Liveness horizon is `updatedAt + ttl`.
    public var updatedAt: Date
    public var ttlSeconds: Int
    /// Hard ceiling heartbeats cannot extend, anchored to `createdAt`.
    public var maxLifetimeSeconds: Int
    public var state: State
    public var endedAt: Date?
    public var endReason: String?

    public init(
        id: String,
        owner: String,
        tool: String,
        task: String,
        ownerPid: Int32? = nil,
        createdAt: Date,
        updatedAt: Date,
        ttlSeconds: Int,
        maxLifetimeSeconds: Int,
        state: State = .active,
        endedAt: Date? = nil,
        endReason: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.tool = tool
        self.task = task
        self.ownerPid = ownerPid
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ttlSeconds = ttlSeconds
        self.maxLifetimeSeconds = maxLifetimeSeconds
        self.state = state
        self.endedAt = endedAt
        self.endReason = endReason
    }
}

// MARK: - Policy

/// Pure lease policy: validation, clamps, and adjudication. Everything here
/// is deterministic over injected time so tests never wait.
public enum AutomationLease {
    /// TTL bounds: long enough that a 1 Hz judge never flaps, short enough
    /// that a crashed client cannot hold the Mac awake past a day.
    public static let ttlRange = 10...86_400
    /// Absolute lifetime ceiling (7 days). A hostile or confused request can
    /// never create a near-permanent hold.
    public static let maxLifetimeCap = 604_800
    /// How long a terminal record stays on disk so acquire-ack polls and
    /// `lease list` can observe it before pruning.
    public static let terminalRetention: TimeInterval = 60

    /// The caller's id in canonical form, or nil for anything that is not a
    /// plain UUID. The pure-parser gate for the one untrusted value that
    /// becomes a file name.
    public static func canonicalId(_ raw: String) -> String? {
        UUID(uuidString: raw).map { $0.uuidString.lowercased() }
    }

    /// Display text defense: control characters stripped, length capped.
    /// Applied on write and again on read, the file is untrusted input.
    public static func sanitized(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(200))
    }

    public static func clampedTTL(_ requested: Int) -> Int {
        min(max(requested, ttlRange.lowerBound), ttlRange.upperBound)
    }

    /// The effective max lifetime: capped at seven days, never below the TTL.
    public static func clampedMaxLifetime(_ requested: Int?, ttl: Int) -> Int {
        max(min(requested ?? maxLifetimeCap, maxLifetimeCap), ttl)
    }

    /// When the record stops being live: the earlier of the heartbeat horizon
    /// and the absolute lifetime ceiling (clamps re-applied, the file is
    /// untrusted).
    public static func expiryDate(of record: AutomationLeaseRecord) -> Date {
        let ttl = clampedTTL(record.ttlSeconds)
        let lifetime = clampedMaxLifetime(record.maxLifetimeSeconds, ttl: ttl)
        return min(
            record.updatedAt.addingTimeInterval(TimeInterval(ttl)),
            record.createdAt.addingTimeInterval(TimeInterval(lifetime))
        )
    }

    /// The engine's judgment of one record at one instant.
    public enum Verdict: Equatable, Sendable {
        /// Counts as demand; keeps the Mac awake.
        case live
        /// Active on disk but past its horizon; stamp it `expired`.
        case lapsed(reason: String)
        /// Already ended; prune once `terminalRetention` has passed.
        case terminal(prune: Bool)
    }

    public static func adjudicate(_ record: AutomationLeaseRecord, now: Date) -> Verdict {
        guard record.state == .active else {
            let endedAt = record.endedAt ?? .distantPast
            return .terminal(prune: now.timeIntervalSince(endedAt) > terminalRetention)
        }
        guard now < expiryDate(of: record) else {
            let ttl = clampedTTL(record.ttlSeconds)
            let lifetime = clampedMaxLifetime(record.maxLifetimeSeconds, ttl: ttl)
            let cappedByLifetime = record.createdAt.addingTimeInterval(TimeInterval(lifetime))
                <= record.updatedAt.addingTimeInterval(TimeInterval(ttl))
            return .lapsed(reason: cappedByLifetime ? "lifetime-cap" : "ttl-expired")
        }
        return .live
    }
}

// MARK: - Store

/// Persistence seam for lease records, so the engine's tests script
/// snapshots without touching the filesystem.
public protocol LeaseRecordStoring: AnyObject {
    /// Every parseable record. Implementations may discard files that can
    /// never become valid (unparseable, or named outside the id scheme).
    func loadAll() -> [AutomationLeaseRecord]
    func write(_ record: AutomationLeaseRecord)
    func delete(id: String)
}

/// Real store: one JSON file per lease under Application Support, next to
/// `agent-hooks/`. Atomic best-effort IO with errors swallowed, the same
/// contract as ``StatusFile`` and ``AgentHooks``: leases are advisory and
/// must never break a tick.
public final class FileLeaseStore: LeaseRecordStoring {
    private let directory: URL

    /// `~/Library/Application Support/Keepresso/automation-leases/`.
    public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keepresso", isDirectory: true)
            .appendingPathComponent("automation-leases", isDirectory: true)
    }

    public init(directory: URL = FileLeaseStore.defaultDirectoryURL()) {
        self.directory = directory
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The record's file name; the id was validated as a UUID, but flatten
    /// anything path-hostile anyway, mirroring the agent-hooks rule.
    static func fileName(forId id: String) -> String {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return "\(safe.isEmpty ? "lease" : safe).json"
    }

    public func loadAll() -> [AutomationLeaseRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        var records: [AutomationLeaseRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? Self.decoder.decode(AutomationLeaseRecord.self, from: data),
                  AutomationLease.canonicalId(record.id) == record.id
            else {
                // Unparseable or mis-identified files can never become valid
                // leases; our directory, our mess.
                try? FileManager.default.removeItem(at: file)
                continue
            }
            records.append(record)
        }
        return records
    }

    public func write(_ record: AutomationLeaseRecord) {
        guard let data = try? Self.encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(
            to: directory.appendingPathComponent(Self.fileName(forId: record.id)),
            options: .atomic
        )
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(Self.fileName(forId: id)))
    }
}

// MARK: - Engine

/// One live lease, as the session controller and the menu see it.
public struct LeaseSummary: Equatable, Sendable {
    public let id: String
    public let owner: String
    public let tool: String
    public let task: String
    public let expiresAt: Date

    public init(id: String, owner: String, tool: String, task: String, expiresAt: Date) {
        self.id = id
        self.owner = owner
        self.tool = tool
        self.task = task
        self.expiresAt = expiresAt
    }
}

/// The controller's lease seam, ticked from `reconcile` so a fake clock
/// drives expiry in tests exactly like every other time input.
@MainActor
public protocol LeaseProviding: AnyObject {
    /// Rescan, expire what lapsed, prune what is long ended, and return the
    /// leases that count as demand right now.
    func tick(now: Date) -> [LeaseSummary]
    /// An explicit user stop: every live lease turns terminal so the session
    /// cannot flap back on the next tick. Clients learn of the revocation
    /// from their next heartbeat.
    func revokeAll(now: Date)
}

/// Real engine over a record store. Scanning a handful of small files at
/// 1 Hz matches the agent-hooks cost profile.
@MainActor
public final class LeaseEngine: LeaseProviding {
    private let store: LeaseRecordStoring

    public init(store: LeaseRecordStoring = FileLeaseStore()) {
        self.store = store
    }

    public func tick(now: Date) -> [LeaseSummary] {
        var live: [LeaseSummary] = []
        for record in store.loadAll() {
            switch AutomationLease.adjudicate(record, now: now) {
            case .live:
                live.append(LeaseSummary(
                    id: record.id,
                    owner: AutomationLease.sanitized(record.owner),
                    tool: AutomationLease.sanitized(record.tool),
                    task: AutomationLease.sanitized(record.task),
                    expiresAt: AutomationLease.expiryDate(of: record)
                ))
            case .lapsed(let reason):
                var ended = record
                ended.state = .expired
                ended.endedAt = now
                ended.endReason = reason
                store.write(ended)
            case .terminal(let prune):
                if prune { store.delete(id: record.id) }
            }
        }
        // Stable order for the menu: soonest expiry first, id as tiebreaker.
        return live.sorted {
            ($0.expiresAt, $0.id) < ($1.expiresAt, $1.id)
        }
    }

    public func revokeAll(now: Date) {
        for record in store.loadAll() where record.state == .active {
            var ended = record
            ended.state = .revoked
            ended.endedAt = now
            ended.endReason = "stopped-by-user"
            store.write(ended)
        }
    }
}
