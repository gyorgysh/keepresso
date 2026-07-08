import Foundation

/// What Background Task Management's own records say about the app and its
/// helper daemon, distilled from `sfltool dumpbtm` output.
public struct BTMFindings: Equatable, Sendable {
    /// The daemon record's effective state, worst-to-best across the
    /// duplicate records BTM keeps per store.
    public enum DaemonState: Equatable, Sendable {
        /// A record exists and is enabled; the registration itself is fine
        /// (an unresponsive daemon then points at launchd or the binary).
        case enabled
        /// The record exists but the user's Background Activity switch is
        /// off. No amount of re-registering flips it; only the user can.
        case disabled
        /// BTM refuses the item outright (it does this to team-less
        /// executables, and keeps a tombstone like this after unregister).
        case disallowed
        /// No daemon record at all: registering is the fix.
        case missing
    }

    public var daemonState: DaemonState
    /// Absolute paths of copies of the app that BTM still tracks inside a
    /// Trash folder. Poison: BTM's bookmark keeps resolving there and it
    /// then disables the daemon on every revalidation pass.
    public var staleCopyPaths: [String]

    public init(daemonState: DaemonState, staleCopyPaths: [String]) {
        self.daemonState = daemonState
        self.staleCopyPaths = staleCopyPaths
    }
}

/// Parses `sfltool dumpbtm` output. The dump is the only view into BTM's
/// records: `SMAppService.status` reported `.enabled` on a live machine while
/// the daemon record underneath sat disabled, so the health check consults
/// the records themselves before deciding whether a repair can help at all.
public enum BTMInspection {
    /// Distill the dump into what matters for this app: the daemon record's
    /// state and any tracked copies of the app rotting in a Trash folder.
    public static func findings(
        inDump dump: String,
        bundleIdentifier: String,
        helperLabel: String
    ) -> BTMFindings {
        let records = parseRecords(dump)

        var staleCopies: [String] = []
        for record in records where record.type?.contains("app") == true {
            let matchesApp = record.bundleIdentifier == bundleIdentifier
                || record.identifier?.hasSuffix(".\(bundleIdentifier)") == true
            guard matchesApp,
                  let urlString = record.url,
                  let url = URL(string: urlString), url.isFileURL,
                  StaleBundleSweep.isInTrash(url)
            else { continue }
            let path = url.standardizedFileURL.path
            if !staleCopies.contains(path) { staleCopies.append(path) }
        }

        let daemons = records.filter {
            $0.type?.contains("daemon") == true
                && $0.identifier?.hasSuffix(helperLabel) == true
        }
        let state: BTMFindings.DaemonState = if daemons.contains(where: \.isEnabled) {
            .enabled
        } else if daemons.contains(where: \.isDisallowed) {
            .disallowed
        } else if !daemons.isEmpty {
            .disabled
        } else {
            .missing
        }
        return BTMFindings(daemonState: state, staleCopyPaths: staleCopies)
    }

    /// One record block from the dump.
    struct Record {
        var fields: [String: String] = [:]

        var type: String? { fields["Type"] }
        var identifier: String? { fields["Identifier"] }
        var bundleIdentifier: String? { fields["Bundle Identifier"] }
        var url: String? { fields["URL"] }

        /// Tokens inside the disposition brackets, e.g.
        /// `[disabled, allowed, not notified] (0x2)` → disabled, allowed, ...
        private var dispositionFlags: [String] {
            guard let raw = fields["Disposition"],
                  let open = raw.firstIndex(of: "["),
                  let close = raw.firstIndex(of: "]")
            else { return [] }
            return raw[raw.index(after: open)..<close]
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        // Exact token matches: "disabled" contains "enabled" as a substring.
        var isEnabled: Bool { dispositionFlags.contains("enabled") }
        var isDisallowed: Bool { dispositionFlags.contains("disallowed") }
    }

    /// Split the dump into records. A record starts at a bare `#N:` line;
    /// the `#1: some.identifier` lines inside an "Embedded Item Identifiers"
    /// list carry a value after the colon and must not start one.
    static func parseRecords(_ dump: String) -> [Record] {
        var records: [Record] = []
        var current: Record?
        for rawLine in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isRecordHeader(line) {
                if let current { records.append(current) }
                current = Record()
                continue
            }
            guard current != nil,
                  let colon = line.range(of: ": ")
            else { continue }
            let key = String(line[..<colon.lowerBound])
            let value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            // First writer wins: an embedded-items list must not overwrite
            // the record's own fields.
            if current?.fields[key] == nil { current?.fields[key] = value }
        }
        if let current { records.append(current) }
        return records
    }

    /// A bare `#N:` line (all digits, nothing after the colon).
    private static func isRecordHeader(_ line: String) -> Bool {
        guard line.hasPrefix("#"), line.hasSuffix(":") else { return false }
        let digits = line.dropFirst().dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}

/// Source of the raw dump, injectable so tests feed fixtures.
public protocol BTMDumpProviding: Sendable {
    /// The `sfltool dumpbtm` output, or nil when unavailable (some macOS
    /// versions gate it behind root; callers then fall back to acting blind).
    func dumpBTM() -> String?
}

/// The real dump: `/usr/bin/sfltool dumpbtm`, prompt-free. Blocking; run it
/// off the main actor.
public struct SFLToolBTMDumper: BTMDumpProviding {
    public init() {}

    public func dumpBTM() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        process.arguments = ["dumpbtm"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }
}
