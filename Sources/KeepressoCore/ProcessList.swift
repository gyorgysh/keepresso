import Foundation

/// Abstraction over the list of running processes, so a process-matching trigger
/// can be tested without inspecting the real system. Mirrors the other monitor
/// seams (``WorkspaceMonitoring``, ``PowerSourceMonitoring``).
///
/// Unlike ``WorkspaceMonitoring`` (which only sees GUI apps with bundle IDs),
/// this sees *every* process, including command-line tools and background jobs
/// like `node`, `python`, `ffmpeg`, or `claude`.
public protocol ProcessListing: AnyObject {
    var current: [String] { get }
}

/// ``current`` is read synchronously from the menu's `body` on the main
/// thread, so it must never block on `Process.waitUntilExit()` itself (see the
/// same hazard documented on ``ShellSystemProbe`` and ``PMSetSleepControl``: a
/// blocked main run loop can crash re-entrantly when a virtual display is
/// active). Instead, a stale cache is returned immediately and a refresh is
/// kicked off on a detached task when it goes stale.
public final class PSProcessLister: ProcessListing {
    private let ttl: TimeInterval
    private let now: () -> Date
    private let fetch: @Sendable () -> String?
    private let lock = NSLock()
    private var cached: [String] = []
    private var lastFetch: Date?
    private var isRefreshing = false

    public init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping @Sendable () -> String? = PSProcessLister.runPS
    ) {
        self.ttl = ttl
        self.now = now
        self.fetch = fetch
    }

    public var current: [String] {
        let (snapshot, shouldRefresh) = withLock { () -> ([String], Bool) in
            let isStale = lastFetch.map { now().timeIntervalSince($0) >= ttl } ?? true
            let shouldRefresh = isStale && !isRefreshing
            if shouldRefresh { isRefreshing = true }
            return (cached, shouldRefresh)
        }

        if shouldRefresh {
            Task.detached { [weak self] in
                guard let self else { return }
                guard let raw = self.fetch() else {
                    self.withLock {
                        self.lastFetch = self.now()
                        self.isRefreshing = false
                    }
                    return
                }
                let fetched = raw.split(whereSeparator: \.isNewline).map(String.init)
                self.withLock {
                    self.cached = fetched
                    self.lastFetch = self.now()
                    self.isRefreshing = false
                }
            }
        }
        return snapshot
    }

    /// Wraps ``lock`` in a synchronous call so the lock/unlock pair is never
    /// invoked directly from an async context (`NSLock` is `noasync`).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The real fetch: spawn `ps` and return its raw output. The default for
    /// ``init(ttl:now:fetch:)``'s `fetch`.
    @Sendable public static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -a all users, -x include processes without a controlling terminal,
        // -ww no column-width truncation, -o command= full command line, no header.
        process.arguments = ["-axww", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
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
