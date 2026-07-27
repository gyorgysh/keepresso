import Foundation

/// One shared `/bin/ps` snapshot used by both ``PSProcessLister`` and
/// ``PSAgentActivityMonitor``, so a machine with process rules and agent rules
/// does not fork `ps` twice on the same cadence.
///
/// The rich column set (`pid,ppid,pcpu,tty,command`) is the source of truth;
/// command-only listings for process matching are derived from it. Results are
/// cached for ``ttl`` seconds behind a lock: concurrent callers share one in
/// flight run, and a fresh cache returns immediately without spawning again.
public final class SharedPSSnapshot: @unchecked Sendable {
    private let ttl: TimeInterval
    private let now: () -> Date
    private let run: @Sendable () -> String?
    private let lock = NSLock()
    private var cached: String?
    private var lastFetch: Date?

    public init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        run: @escaping @Sendable () -> String? = SharedPSSnapshot.runPS
    ) {
        self.ttl = ttl
        self.now = now
        self.run = run
    }

    /// Blocking fetch wrappers marked `@Sendable` so they can be handed to
    /// ``PSProcessLister`` / ``PSAgentActivityMonitor`` without a concurrency
    /// warning (the class itself is already `@unchecked Sendable`).
    @Sendable public func fetchRaw() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached, let lastFetch, now().timeIntervalSince(lastFetch) < ttl {
            return cached
        }
        let value = run()
        cached = value
        lastFetch = now()
        return value
    }

    /// Command-only listing derived from the rich snapshot, matching what
    /// ``PSProcessLister`` historically fetched with `ps -o command=`.
    @Sendable public func fetchCommandListing() -> String? {
        fetchRaw().map(Self.commandListing(fromRich:))
    }

    /// Pull the command field out of each rich `ps` line.
    public static func commandListing(fromRich raw: String) -> String {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            var rest = Substring(line)
            func nextToken() -> Substring? {
                let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard !trimmed.isEmpty else { return nil }
                let token = trimmed.prefix(while: { $0 != " " && $0 != "\t" })
                rest = trimmed.dropFirst(token.count)
                return token
            }
            // pid, ppid, pcpu, tty — then the remainder is the command.
            guard nextToken() != nil, nextToken() != nil,
                  nextToken() != nil, nextToken() != nil else { return nil }
            let command = rest.drop(while: { $0 == " " || $0 == "\t" })
            return command.isEmpty ? nil : String(command)
        }.joined(separator: "\n")
    }

    /// The real fetch: spawn rich-column `ps`. Shared by the default
    /// ``PSAgentActivityMonitor`` path and this snapshot's default `run`.
    @Sendable public static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,ppid=,pcpu=,tty=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(decoding: data, as: UTF8.self)
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}
