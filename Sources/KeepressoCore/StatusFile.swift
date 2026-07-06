import Foundation

/// A machine-readable mirror of the session state, written by the app to
/// `~/Library/Application Support/Keepresso/status.json` whenever the state
/// changes, so `keepresso status` can answer from outside the process.
///
/// The App Group is Team-ID-scoped and sandbox-signed, so a plain file is the
/// channel a separately invoked CLI can always read. The snapshot carries the
/// writer's pid: readers use `kill(pid, 0)` to tell a live state from one left
/// behind by a crash.
public struct StatusSnapshot: Codable, Equatable, Sendable {
    public var isActive: Bool
    /// When a timed session ends, or `nil` for indefinite/trigger-held ones.
    public var endsAt: Date?
    public var triggersEnabled: Bool
    public var triggersPaused: Bool
    /// The writing app's marketing version, for support and mismatch checks.
    public var appVersion: String?
    /// The writing app's process id.
    public var pid: Int32
    public var writtenAt: Date

    public init(
        isActive: Bool,
        endsAt: Date? = nil,
        triggersEnabled: Bool = false,
        triggersPaused: Bool = false,
        appVersion: String? = nil,
        pid: Int32,
        writtenAt: Date
    ) {
        self.isActive = isActive
        self.endsAt = endsAt
        self.triggersEnabled = triggersEnabled
        self.triggersPaused = triggersPaused
        self.appVersion = appVersion
        self.pid = pid
        self.writtenAt = writtenAt
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
