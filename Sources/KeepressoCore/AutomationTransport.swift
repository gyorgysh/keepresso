import Foundation

/// The one JSON dialect every automation surface speaks (CLI output, MCP tool
/// results, the wake request file): ISO-8601 dates, pretty-printed, sorted
/// keys, so output stays stable for scripts and tests.
public enum AutomationJSON {
    public static func encode<T: Encodable>(_ payload: T) -> String {
        String(decoding: encodeData(payload) ?? Data("{}".utf8), as: UTF8.self)
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
