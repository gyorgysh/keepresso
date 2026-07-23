import Foundation

/// The result of one lease operation, rendered by the executables: the CLI
/// prints `human` (or `json`) and exits with `exitCode`; the MCP server wraps
/// `json` in a tool result.
public struct LeaseOutcome: Sendable {
    /// 0 ok, 1 local failure, 2 no app acknowledgment / app not running,
    /// 3 lease not found or already ended, 4 disabled by preference, 64 usage.
    public let exitCode: Int32
    public let json: String
    public let human: String
}

/// Client-side lease operations, shared verbatim by the `keepresso` CLI and
/// the MCP server so there is exactly one implementation. All effects are
/// injected: tests script the status-file sequence and never sleep.
///
/// The transport has no request/response channel. Acquire writes the record
/// file, rings the app's `keepresso://sync-leases` doorbell (launching it if
/// needed), then polls the app-written status snapshot until its lease id is
/// acknowledged. Heartbeat and release are plain file updates the app notices
/// on its next tick.
public struct LeaseClient {
    public var store: LeaseRecordStoring
    public var now: () -> Date
    public var readStatus: () -> StatusSnapshot?
    /// Ring the doorbell; false when the URL could not even be delivered.
    public var nudgeApp: () -> Bool
    public var sleep: (TimeInterval) -> Void
    public var isPidAlive: (Int32) -> Bool
    /// Recorded on acquired leases for `lease list`; advisory only.
    public var ownerPid: Int32?
    /// Used when acquire is given no `--owner`.
    public var defaultOwner: String

    /// How long acquire waits for the app to acknowledge (covers a cold app
    /// launch), and how often it looks.
    public static let ackTimeout: TimeInterval = 10
    public static let ackInterval: TimeInterval = 0.2
    /// The ack loop's iteration bound: the wall-clock deadline alone would
    /// stretch by the size of a backwards clock jump landing mid-acquire.
    static let maxAckPolls = Int(ackTimeout / ackInterval)

    public init(
        store: LeaseRecordStoring,
        now: @escaping () -> Date = Date.init,
        readStatus: @escaping () -> StatusSnapshot? = { StatusFile.read() },
        nudgeApp: @escaping () -> Bool,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        isPidAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM },
        ownerPid: Int32? = nil,
        defaultOwner: String = NSUserName()
    ) {
        self.store = store
        self.now = now
        self.readStatus = readStatus
        self.nudgeApp = nudgeApp
        self.sleep = sleep
        self.isPidAlive = isPidAlive
        self.ownerPid = ownerPid
        self.defaultOwner = defaultOwner
    }

    // MARK: - Operations

    public func run(_ command: CLIRequest.LeaseCommand) -> LeaseOutcome {
        switch command {
        case .acquire(let id, let owner, let tool, let task, let ttl, let maxLifetime, _):
            return acquire(
                id: id, owner: owner, tool: tool, task: task,
                ttlSeconds: ttl, maxLifetimeSeconds: maxLifetime
            )
        case .heartbeat(let id, let ttl, _):
            return heartbeat(id: id, ttlSeconds: ttl)
        case .release(let id, _):
            return release(id: id)
        case .list:
            return list()
        }
    }

    public func acquire(
        id: String,
        owner: String?,
        tool: String,
        task: String,
        ttlSeconds: Int,
        maxLifetimeSeconds: Int?
    ) -> LeaseOutcome {
        let instant = now()
        let ttl = AutomationLease.clampedTTL(ttlSeconds)
        let lifetime = AutomationLease.clampedMaxLifetime(maxLifetimeSeconds, ttl: ttl)

        // Idempotent re-acquire: the same id refreshing a still-live lease
        // keeps its createdAt so the lifetime ceiling stays anchored to the
        // original acquisition. Anything ended (or never seen) starts fresh.
        let existing = store.loadAll().first { $0.id == id }
        let renewed = existing.map { AutomationLease.adjudicate($0, now: instant) == .live } ?? false
        let record = AutomationLeaseRecord(
            id: id,
            owner: AutomationLease.sanitized(owner ?? defaultOwner),
            tool: AutomationLease.sanitized(tool),
            task: AutomationLease.sanitized(task),
            ownerPid: ownerPid,
            createdAt: renewed ? existing!.createdAt : instant,
            updatedAt: instant,
            ttlSeconds: ttl,
            maxLifetimeSeconds: lifetime,
            state: .active
        )
        store.write(record)

        guard nudgeApp() else {
            rollBack(id: id, renewed: renewed, previous: existing)
            return failure(2, "could not reach the Keepresso app. Is it installed?")
        }

        // Poll for the acknowledgment. Failing closed matters here: a record
        // the app never confirmed must not linger and silently hold the Mac
        // awake once the app next launches.
        let deadline = instant.addingTimeInterval(Self.ackTimeout)
        var polls = 0
        while true {
            if let snapshot = readStatus(), isPidAlive(snapshot.pid) {
                if snapshot.leasesEnabled == false {
                    rollBack(id: id, renewed: renewed, previous: existing)
                    return failure(4, "automation leases are disabled in Keepresso's preferences.")
                }
                if snapshot.leaseIDs?.contains(id) == true {
                    struct Payload: Codable {
                        var acquired: Bool, id: String, renewed: Bool
                        var expiresAt: Date, isActive: Bool
                    }
                    let payload = Payload(
                        acquired: true, id: id, renewed: renewed,
                        expiresAt: AutomationLease.expiryDate(of: record),
                        isActive: snapshot.isActive
                    )
                    var human = renewed
                        ? "Lease \(id) renewed."
                        : "Lease \(id) acquired."
                    if !snapshot.isActive {
                        human += " Keepresso is safety-paused. The Mac is not being held awake right now."
                    }
                    return LeaseOutcome(exitCode: 0, json: encode(payload), human: human)
                }
            }
            polls += 1
            guard now() < deadline, polls <= Self.maxAckPolls else { break }
            sleep(Self.ackInterval)
        }
        rollBack(id: id, renewed: renewed, previous: existing)
        return failure(2, "the Keepresso app did not acknowledge the lease. Update the app if it predates automation leases.")
    }

    /// Undo a failed acquire without collateral damage: a fresh record is
    /// deleted, but a renewal restores the previously acknowledged record, so
    /// a lost doorbell or a slow ack on a retry cannot end a lease that was
    /// live before it.
    private func rollBack(id: String, renewed: Bool, previous: AutomationLeaseRecord?) {
        if renewed, let previous {
            store.write(previous)
        } else {
            store.delete(id: id)
        }
    }

    public func heartbeat(id: String, ttlSeconds: Int?) -> LeaseOutcome {
        let instant = now()
        guard let record = store.loadAll().first(where: { $0.id == id }) else {
            return failure(3, "no lease with id \(id).")
        }
        guard AutomationLease.adjudicate(record, now: instant) == .live else {
            struct Payload: Codable { var error: String, id: String, state: String, endReason: String? }
            let state = record.state == .active ? "expired" : record.state.rawValue
            let payload = Payload(
                error: "lease is no longer live", id: id,
                state: state, endReason: record.endReason
            )
            return LeaseOutcome(
                exitCode: 3,
                json: encode(payload),
                human: "Lease \(id) is \(state). Acquire a new lease to continue."
            )
        }
        var fresh = record
        fresh.updatedAt = instant
        if let ttlSeconds {
            // The horizon may move, the ceiling may not: the skill, the MCP
            // tool description, and the UI all promise heartbeats can never
            // extend the maximum lifetime, so the new ttl is capped at the
            // recorded ceiling instead of raising it (the read-side clamp
            // floors the lifetime at the ttl).
            fresh.ttlSeconds = min(
                AutomationLease.clampedTTL(ttlSeconds), fresh.maxLifetimeSeconds)
        }
        store.write(fresh)

        let snapshot = readStatus()
        let appRunning = snapshot.map { isPidAlive($0.pid) } ?? false
        struct Payload: Codable {
            var id: String, expiresAt: Date, appRunning: Bool, isActive: Bool
        }
        let payload = Payload(
            id: id,
            expiresAt: AutomationLease.expiryDate(of: fresh),
            appRunning: appRunning,
            isActive: appRunning && snapshot?.isActive == true
        )
        if payload.isActive {
            return LeaseOutcome(exitCode: 0, json: encode(payload), human: "Lease \(id) extended.")
        }
        if appRunning {
            // The lease is extended and will resume, but a safety pause
            // (battery, thermal) means nothing holds the Mac awake right
            // now; the caller must not assume it stayed up.
            return LeaseOutcome(
                exitCode: 0,
                json: encode(payload),
                human: "Lease \(id) extended, but Keepresso is safety-paused. The Mac is not being held awake right now."
            )
        }
        // The record is written (leases survive an app relaunch), but nothing
        // is holding the Mac awake right now; the caller should know.
        return LeaseOutcome(
            exitCode: 2,
            json: encode(payload),
            human: "Lease \(id) extended, but the Keepresso app is not running."
        )
    }

    public func release(id: String) -> LeaseOutcome {
        struct Payload: Codable { var id: String, released: Bool }
        let instant = now()
        if var record = store.loadAll().first(where: { $0.id == id }), record.state == .active {
            record.state = .released
            record.endedAt = instant
            record.endReason = "released"
            store.write(record)
        }
        // Idempotent: releasing a missing or already ended lease is success.
        return LeaseOutcome(
            exitCode: 0,
            json: encode(Payload(id: id, released: true)),
            human: "Lease \(id) released."
        )
    }

    public func list() -> LeaseOutcome {
        struct Listed: Codable {
            var id: String, owner: String, tool: String, task: String
            var state: String, expiresAt: Date?, endReason: String?, ownerPid: Int32?
        }
        struct Payload: Codable { var leases: [Listed] }
        let instant = now()
        let listed = store.loadAll()
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            .map { record -> Listed in
                let live = AutomationLease.adjudicate(record, now: instant) == .live
                let state = live || record.state != .active ? record.state.rawValue : "expired"
                return Listed(
                    id: record.id,
                    owner: AutomationLease.sanitized(record.owner),
                    tool: AutomationLease.sanitized(record.tool),
                    task: AutomationLease.sanitized(record.task),
                    state: state,
                    expiresAt: live ? AutomationLease.expiryDate(of: record) : record.endedAt,
                    endReason: record.endReason,
                    ownerPid: record.ownerPid
                )
            }
        let human = listed.isEmpty
            ? "No leases."
            : listed.map { lease in
                let head = "\(lease.id.prefix(8))  \(lease.state.padding(toLength: 8, withPad: " ", startingAt: 0))"
                return "\(head)  \(lease.tool): \(lease.task)"
            }.joined(separator: "\n")
        return LeaseOutcome(exitCode: 0, json: encode(Payload(leases: listed)), human: human)
    }

    // MARK: - Rendering

    private func failure(_ code: Int32, _ message: String) -> LeaseOutcome {
        struct Payload: Codable { var error: String }
        return LeaseOutcome(exitCode: code, json: encode(Payload(error: message)), human: message)
    }

    private func encode<T: Encodable>(_ payload: T) -> String {
        AutomationJSON.encode(payload)
    }
}

public extension LeaseClient {
    /// The production client: real clock, real files, `open -g` doorbell.
    /// Used identically by the CLI and the MCP server. `ownerPid` should be
    /// the invoking process (`getppid()` from the CLI, the client pid over
    /// MCP is not knowable, so the server passes its own parent too).
    static func real(ownerPid: Int32? = nil) -> LeaseClient {
        LeaseClient(
            store: FileLeaseStore(),
            nudgeApp: AppDoorbell.ring,
            ownerPid: ownerPid
        )
    }
}
