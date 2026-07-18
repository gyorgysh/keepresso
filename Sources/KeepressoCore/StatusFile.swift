import Foundation
import Darwin

/// A machine-readable mirror of the session state, written by the app to
/// `~/Library/Application Support/Keepresso/status.json` whenever the state
/// changes, so `keepresso status` can answer from outside the process.
///
/// The App Group is Team-ID-scoped and sandbox-signed, so a plain file is the
/// channel a separately invoked CLI can always read. The snapshot carries the
/// writer's pid, process-start token, and heartbeat timestamp. Readers require
/// all three, so a crash followed by PID reuse cannot authenticate stale
/// closed-lid readiness.
public struct StatusSnapshot: Codable, Equatable, Sendable {
    public var isActive: Bool
    /// When a timed session ends, or `nil` for indefinite/trigger-held ones.
    public var endsAt: Date?
    public var triggersEnabled: Bool
    public var triggersPaused: Bool
    /// Explicit Agent leases currently contributing to the wake union.
    public var activeAgentLeaseCount: Int?
    /// Earliest TTL or maximum-lifetime deadline among active Agent leases.
    public var nextAgentLeaseDeadline: Date?
    /// Stable unattended phase for scripts, such as preparing or awaitingLease.
    public var unattendedPhase: String?
    /// Whether closed-lid protection is available while idle, or confirmed
    /// active while unattended work owns the session.
    public var closedLidProtectionReady: Bool?
    /// Nearest enabled local Codex automation run known to the app.
    public var nextCodexRun: Date?
    /// The writing app's marketing version, for support and mismatch checks.
    public var appVersion: String?
    /// The writing app's process id.
    public var pid: Int32
    /// Microseconds since the Unix epoch when that exact process started.
    public var processStartToken: UInt64?
    public var writtenAt: Date

    public init(
        isActive: Bool,
        endsAt: Date? = nil,
        triggersEnabled: Bool = false,
        triggersPaused: Bool = false,
        activeAgentLeaseCount: Int? = nil,
        nextAgentLeaseDeadline: Date? = nil,
        unattendedPhase: String? = nil,
        closedLidProtectionReady: Bool? = nil,
        nextCodexRun: Date? = nil,
        appVersion: String? = nil,
        pid: Int32,
        processStartToken: UInt64? = nil,
        writtenAt: Date
    ) {
        self.isActive = isActive
        self.endsAt = endsAt
        self.triggersEnabled = triggersEnabled
        self.triggersPaused = triggersPaused
        self.activeAgentLeaseCount = activeAgentLeaseCount
        self.nextAgentLeaseDeadline = nextAgentLeaseDeadline
        self.unattendedPhase = unattendedPhase
        self.closedLidProtectionReady = closedLidProtectionReady
        self.nextCodexRun = nextCodexRun
        self.appVersion = appVersion
        self.pid = pid
        self.processStartToken = processStartToken
        self.writtenAt = writtenAt
    }
}

/// Authenticates a status heartbeat against the exact process instance.
public enum StatusSnapshotLiveness {
    public static let maximumHeartbeatAge: TimeInterval = 5
    public static let maximumFutureSkew: TimeInterval = 2

    public static func isLive(
        _ snapshot: StatusSnapshot,
        now: Date = Date(),
        startTokenForPID: (Int32) -> UInt64? = StatusProcessIdentity.startToken
    ) -> Bool {
        let age = now.timeIntervalSince(snapshot.writtenAt)
        guard age >= -maximumFutureSkew,
              age <= maximumHeartbeatAge,
              let expected = snapshot.processStartToken,
              let actual = startTokenForPID(snapshot.pid),
              expected == actual
        else { return false }
        return true
    }
}

public enum StatusProcessIdentity {
    /// Kernel process start time, stable for the process lifetime and changed
    /// when the numeric PID is reused.
    public static func startToken(pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        let seconds = info.pbi_start_tvsec
        let microseconds = UInt64(info.pbi_start_tvusec)
        guard seconds <= (UInt64.max - microseconds) / 1_000_000 else { return nil }
        return seconds * 1_000_000 + microseconds
    }
}

/// Reads and writes the status snapshot. Dates are ISO 8601 so the JSON stays
/// friendly to scripts (`jq .endsAt`), not just to this decoder.
public enum StatusFile {
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keepresso", isDirectory: true)
            .appendingPathComponent("status.json")
    }

    /// Atomic best-effort write, creating the folder on first use. Errors are
    /// swallowed on purpose: status is advisory and must never break a tick.
    public static func write(_ snapshot: StatusSnapshot, to url: URL = defaultURL()) {
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL = defaultURL()) -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(StatusSnapshot.self, from: data)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
