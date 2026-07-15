import Foundation

/// One detected AI-agent CLI session (a `claude`, `codex`, ... process running
/// in a terminal), with the CPU its process subtree is currently burning.
public struct AgentSession: Equatable, Hashable, Sendable {
    /// The agent root process id.
    public var pid: Int32
    /// The matched agent command, e.g. "claude".
    public var agent: String
    /// The controlling terminal ("s003"), or `nil` for a detached process.
    public var tty: String?
    /// The `pcpu` sum over the agent process and all its descendants, as a
    /// percentage of one core (can exceed 100 on multi-core work).
    public var cpuPercent: Double

    public init(pid: Int32, agent: String, tty: String?, cpuPercent: Double) {
        self.pid = pid
        self.agent = agent
        self.tty = tty
        self.cpuPercent = cpuPercent
    }

    /// A short display label: the agent plus its terminal ("claude (s003)"),
    /// falling back to the pid when there is no controlling terminal.
    public var label: String {
        if let tty { return "\(agent) (\(tty))" }
        return "\(agent) (pid \(pid))"
    }
}

/// The set of agent sessions detected in one scan.
public struct AgentSnapshot: Equatable, Sendable {
    public var sessions: [AgentSession]

    public init(sessions: [AgentSession] = []) {
        self.sessions = sessions
    }

    public static let empty = AgentSnapshot()
}

/// Abstraction over agent-session detection, so the trigger can be tested with
/// scripted snapshots. Mirrors the other monitor seams (``ProcessListing``).
public protocol AgentActivityMonitoring: AnyObject {
    /// The sessions detected by the most recent scan.
    var current: AgentSnapshot { get }
}

/// Real backend over `ps`: one `ps -axww -o pid=,ppid=,pcpu=,tty=,command=`
/// call yields every process with its parent and CPU share, from which agent
/// roots and their subtree CPU are computed (pure functions, unit-tested).
///
/// Same stale-while-revalidate shape as ``PSProcessLister``, and for the same
/// reason: ``current`` is read from the menu's `body` on the main thread and
/// must never block on `Process.waitUntilExit()`, so a stale snapshot is
/// returned immediately and a refresh runs on a detached task when it goes
/// stale.
public final class PSAgentActivityMonitor: AgentActivityMonitoring {
    /// The agent CLIs detected out of the box, matched against the root
    /// command's basename (never as a substring, so `grep claude` or a file
    /// name mentioning an agent can't count as a session). CLI binaries only:
    /// a bare "cursor" or "antigravity" would match the whole IDE app, whose
    /// process tree burns CPU constantly, so their terminal agents are listed
    /// by their actual command names instead (cursor-agent, agy).
    public static let agentCommands = [
        "claude", "codex", "gemini", "grok", "agy", "aider", "goose",
        "cursor-agent", "opencode", "amp", "copilot", "droid", "auggie", "qwen",
    ]

    /// Interpreter/runtime launchers whose first non-flag argument is the
    /// script that names the real tool (`node /opt/homebrew/bin/claude`).
    static let runtimeWrappers: Set<String> = ["node", "bun", "deno", "python", "python3"]

    /// One row of `ps` output.
    struct ProcessSample: Equatable {
        var pid: Int32
        var ppid: Int32
        var pcpu: Double
        var tty: String?
        var command: String
    }

    private let ttl: TimeInterval
    private let now: () -> Date
    /// Produces the raw `ps` output (`nil` on failure). Injectable so the
    /// cache/refresh logic can be unit-tested without spawning processes.
    private let fetch: @Sendable () -> String?
    private let lock = NSLock()
    private var cached: AgentSnapshot = .empty
    private var lastFetch: Date?
    private var isRefreshing = false

    public init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping @Sendable () -> String? = PSAgentActivityMonitor.runPS
    ) {
        self.ttl = ttl
        self.now = now
        self.fetch = fetch
    }

    public var current: AgentSnapshot {
        let (snapshot, shouldRefresh) = withLock { () -> (AgentSnapshot, Bool) in
            let isStale = lastFetch.map { now().timeIntervalSince($0) >= ttl } ?? true
            let shouldRefresh = isStale && !isRefreshing
            if shouldRefresh { isRefreshing = true }
            return (cached, shouldRefresh)
        }

        if shouldRefresh {
            Task.detached { [weak self] in
                guard let self else { return }
                let samples = self.fetch().map(Self.parse) ?? []
                let sessions = Self.sessions(from: samples)
                self.withLock {
                    self.cached = AgentSnapshot(sessions: sessions)
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

    /// Parse raw `ps -o pid=,ppid=,pcpu=,tty=,command=` output. Malformed
    /// lines are skipped; a `??` terminal becomes `nil`, and a `ttys003`
    /// terminal is shortened to `s003` for display.
    static func parse(_ raw: String) -> [ProcessSample] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            var rest = Substring(line)
            func nextToken() -> Substring? {
                let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard !trimmed.isEmpty else { return nil }
                let token = trimmed.prefix(while: { $0 != " " && $0 != "\t" })
                rest = trimmed.dropFirst(token.count)
                return token
            }
            guard let pidToken = nextToken(), let pid = Int32(pidToken),
                  let ppidToken = nextToken(), let ppid = Int32(ppidToken),
                  let cpuToken = nextToken(), let pcpu = Double(cpuToken),
                  let ttyToken = nextToken() else { return nil }
            let command = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard !command.isEmpty else { return nil }
            let tty: String? = ttyToken.contains("?")
                ? nil
                : String(ttyToken.hasPrefix("tty") ? ttyToken.dropFirst(3) : ttyToken)
            return ProcessSample(pid: pid, ppid: ppid, pcpu: pcpu, tty: tty, command: String(command))
        }
    }

    /// Reduce raw samples to agent sessions: find agent roots by command
    /// basename, fold matched processes with a matched ancestor into that
    /// ancestor (a claude-spawned subagent counts toward the parent session,
    /// not as its own row), and sum `pcpu` over each root's subtree (tool
    /// calls like builds and tests run as children and burn CPU even while
    /// the agent process itself waits).
    static func sessions(from samples: [ProcessSample], agents: [String] = agentCommands) -> [AgentSession] {
        var byPid: [Int32: ProcessSample] = [:]
        var children: [Int32: [Int32]] = [:]
        for sample in samples {
            byPid[sample.pid] = sample
            children[sample.ppid, default: []].append(sample.pid)
        }

        var matched: [Int32: String] = [:]
        for sample in samples {
            if let agent = agentName(for: sample.command, agents: agents) {
                matched[sample.pid] = agent
            }
        }

        // A matched pid whose ancestor chain holds another matched pid is not
        // a root. The visited set guards against ppid cycles in output raced
        // across process exits (a reused pid appearing as its own ancestor).
        func hasMatchedAncestor(_ pid: Int32) -> Bool {
            var visited: Set<Int32> = [pid]
            var current = byPid[pid]?.ppid ?? 0
            while current > 1, visited.insert(current).inserted {
                if matched[current] != nil { return true }
                current = byPid[current]?.ppid ?? 0
            }
            return false
        }

        func subtreeCPU(of root: Int32) -> Double {
            var total = 0.0
            var visited: Set<Int32> = []
            var stack = [root]
            while let pid = stack.popLast() {
                guard visited.insert(pid).inserted else { continue }
                total += byPid[pid]?.pcpu ?? 0
                stack.append(contentsOf: children[pid] ?? [])
            }
            return total
        }

        return matched.keys
            .filter { !hasMatchedAncestor($0) }
            .sorted()
            .compactMap { pid in
                guard let sample = byPid[pid], let agent = matched[pid] else { return nil }
                return AgentSession(pid: pid, agent: agent, tty: sample.tty, cpuPercent: subtreeCPU(of: pid))
            }
    }

    /// The agent a command line launches, or `nil`. Matches the basename of
    /// the executable (skipping a runtime wrapper like `node` and its flags to
    /// the script it runs), case-insensitively and exactly, never substring.
    static func agentName(for command: String, agents: [String]) -> String? {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first else { return nil }
        var candidate = basename(first)
        if runtimeWrappers.contains(candidate.lowercased()) {
            guard let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
            candidate = basename(script)
        }
        let lower = candidate.lowercased()
        return agents.first { $0.lowercased() == lower }
    }

    private static func basename(_ token: Substring) -> String {
        String(token.split(separator: "/").last ?? token)
    }

    /// The real fetch: spawn `ps` and return its raw output. The default for
    /// ``init(ttl:now:fetch:)``'s `fetch`.
    @Sendable public static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -a all users, -x include processes without a controlling terminal,
        // -ww no column-width truncation; pid/ppid for the process tree, pcpu
        // for the working verdict, tty for the session label, command last so
        // its embedded spaces can't shift the other columns.
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

/// Fires while any detected agent session is actively working, judged by its
/// subtree's smoothed CPU share.
///
/// The decision runs per session on an exponential moving average with
/// hysteresis, mirroring ``CPULoadTrigger``: an idle agent TUI sits around
/// 0-2% of a core (spinner redraws, heartbeats) while generation, tool calls,
/// and their child processes run well above 10%, so on at 8% and off at 3%
/// leaves a wide dead-band that doesn't flap. A genuinely zero-CPU stretch (a
/// long network wait) still reads as idle by design; the release grace the
/// factory wraps this trigger in is what bridges those, not the threshold.
public final class AgentActivityTrigger: Trigger {
    /// Smoothed subtree CPU (percent of one core) at which a session turns
    /// "working".
    public static let onThresholdPercent = 8.0
    /// The level the average must fall below before a working session turns
    /// "idle" again.
    public static let offThresholdPercent = 3.0
    /// Smoothing weight of each new sample; 0.3 at one sample per second
    /// settles a sustained change in a few seconds.
    static let alpha = 0.3
    /// The release grace the factory applies unless the rule overrides it.
    public static let defaultGrace: TimeInterval = 60

    /// Per-session EMA + hysteresis state.
    public struct State: Equatable, Sendable {
        public var average: Double?
        public var isWorking = false
        public init() {}
    }

    /// One session with its live working/idle verdict, for the menu.
    public struct SessionState: Equatable {
        public let session: AgentSession
        public let isWorking: Bool
    }

    private let monitor: AgentActivityMonitoring
    private var smoothing: [Int32: State] = [:]

    /// The sessions seen by the last ``tick()`` with their verdicts, a pure
    /// read for the menu's per-session rows.
    public private(set) var sessionStates: [SessionState] = []

    public init(monitor: AgentActivityMonitoring = PSAgentActivityMonitor()) {
        self.monitor = monitor
    }

    public var label: String { L("AI agent working") }

    /// Advance each session's smoothing by one reading. Done here (not in
    /// ``isSatisfied()``) so the EMA steps exactly once per reconcile; state
    /// for vanished pids is pruned, so a later session reusing a pid starts
    /// fresh.
    public func tick() {
        let sessions = monitor.current.sessions
        var next: [Int32: State] = [:]
        next.reserveCapacity(sessions.count)
        sessionStates = sessions.map { session in
            let stepped = Self.step(smoothing[session.pid] ?? State(), sample: session.cpuPercent)
            next[session.pid] = stepped
            return SessionState(session: session, isWorking: stepped.isWorking)
        }
        smoothing = next
    }

    public func isSatisfied() -> Bool {
        sessionStates.contains { $0.isWorking }
    }

    /// Pure decision step, exposed for direct unit testing.
    static func step(_ state: State, sample: Double) -> State {
        var next = state
        let clamped = max(sample, 0)
        next.average = state.average.map { $0 + alpha * (clamped - $0) } ?? clamped
        guard let average = next.average else {
            next.isWorking = false
            return next
        }
        next.isWorking = state.isWorking
            ? average >= Self.offThresholdPercent
            : average >= Self.onThresholdPercent
        return next
    }
}

extension AgentActivityTrigger: TriggerDetailProviding {
    public var detailRows: [RuleDetail] {
        sessionStates.map { RuleDetail(label: $0.session.label, active: $0.isWorking) }
    }
}
