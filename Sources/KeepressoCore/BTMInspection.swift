import Foundation

/// What Background Task Management's own records say about the app and its
/// helper daemon, distilled from `sfltool dumpbtm` output.
public struct BTMFindings: Equatable, Sendable {
    /// The daemon record's effective state, worst-to-best across the
    /// duplicate records BTM keeps per store.
    public enum DaemonState: Equatable, Sendable {
        case enabled
        case disabled
        case disallowed
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

    struct Record {
        var fields: [String: String] = [:]

        var type: String? { fields["Type"] }
        var identifier: String? { fields["Identifier"] }
        var bundleIdentifier: String? { fields["Bundle Identifier"] }
        var url: String? { fields["URL"] }

        private var dispositionFlags: [String] {
            guard let raw = fields["Disposition"],
                  let open = raw.firstIndex(of: "["),
                  let close = raw.firstIndex(of: "]"),
                  open < close
            else { return [] }
            return raw[raw.index(after: open)..<close]
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

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
        process.standardError = FileHandle.nullDevice
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
