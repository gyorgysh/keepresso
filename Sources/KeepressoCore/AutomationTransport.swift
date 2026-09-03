import Darwin
import Foundation

/// The one JSON dialect every automation surface speaks (CLI output, MCP tool
/// results, the wake request file): ISO-8601 dates, pretty-printed, sorted
/// keys, so output stays stable for scripts and tests.
public enum AutomationJSON {
    public static func encode<T: Encodable>(_ payload: T) -> String {
        String(decoding: encodeData(payload) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Accept both `2026-08-25T07:30:00Z` and the fractional-second form
    /// agents often emit (`...00.000Z`). The stock formatter with
    /// `.withFractionalSeconds` *requires* a fraction, so try that first and
    /// fall back to the plain internet-date form.
    public static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    public static func encodeData<T: Encodable>(_ payload: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

/// Rings the app's `keepresso://sync-leases` doorbell via `open -g`, launching
/// the app in the background if needed. The one production nudge shared by
/// the lease and wake clients; false when the URL could not even be delivered.
public enum AppDoorbell {
    public static func ring() -> Bool {
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
    }
}

/// Cross-process exclusive lock for the automation file stores (leases and
/// the pending wake request). `flock` on a sidecar file serializes the
/// check-then-write that compare-and-swap and claim need; atomic file
/// replaces alone cannot.
enum FileExclusiveLock {
    static func withLock<T>(directory: URL, name: String = ".lock", _ body: () -> T) -> T {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name, isDirectory: false).path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        // A signal can interrupt the wait (EINTR); retry rather than run the
        // body unlocked, which would silently defeat the compare-and-swap.
        var locked = false
        while true {
            if flock(fd, LOCK_EX) == 0 {
                locked = true
                break
            }
            if errno != EINTR { break }
        }
        defer { if locked { flock(fd, LOCK_UN) } }
        return body()
    }
}
