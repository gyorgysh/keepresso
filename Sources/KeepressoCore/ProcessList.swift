import Foundation

/// Abstraction over the list of running processes, so a process-matching trigger
/// can be tested without inspecting the real system. Mirrors the other monitor
/// seams (``WorkspaceMonitoring``, ``PowerSourceMonitoring``).
///
/// Unlike ``WorkspaceMonitoring`` (which only sees GUI apps with bundle IDs),
/// this sees *every* process, including command-line tools and background jobs
/// like `node`, `python`, `ffmpeg`, or `claude`.
public protocol ProcessListing: AnyObject {
    /// The full command line of every currently running process.
    var current: [String] { get }
}

/// Real backend over `ps`. Lists each process's full, untruncated command line
/// (`ps -axww -o command=`). Spawning `ps` is not free, and the trigger engine
/// plus the menu can read ``current`` several times a second, so results are
/// cached for ``ttl`` seconds: repeated reads reuse one snapshot instead of
/// forking `ps` each time. A process starting or stopping doesn't need
/// sub-second reaction for a keep-awake decision, so a few seconds of staleness
/// is fine. The clock is injectable so the cache can be unit-tested.
///
/// ``current`` is read synchronously from the menu's `body` on the main
/// thread, so it must never block on `Process.waitUntilExit()` itself (see the
/// same hazard documented on ``ShellSystemProbe`` and ``PMSetSleepControl``: a
/// blocked main run loop can crash re-entrantly when a virtual display is
/// active). Instead, a stale cache is returned immediately and a refresh is
/// kicked off on a detached task when it goes stale.
public final class PSProcessLister: ProcessListing {
    private let ttl: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var cached: [String] = []
    private var lastFetch: Date?
    private var isRefreshing = false

    public init(ttl: TimeInterval = 3, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
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
                let fetched = self.run().map { $0.split(whereSeparator: \.isNewline).map(String.init) } ?? []
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

    private func run() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -a all users, -x include processes without a controlling terminal,
        // -ww no column-width truncation, -o command= full command line, no header.
        process.arguments = ["-axww", "-o", "command="]
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
