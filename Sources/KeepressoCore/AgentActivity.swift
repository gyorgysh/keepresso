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
    /// Whether the agent's session transcript on disk was written to within
    /// the freshness window: direct evidence it is working right now, no CPU
    /// guessing involved. Always false for agents without a known transcript.
    public var hasFreshEvidence: Bool

    public init(pid: Int32, agent: String, tty: String?, cpuPercent: Double, hasFreshEvidence: Bool = false) {
        self.pid = pid
        self.agent = agent
        self.tty = tty
        self.cpuPercent = cpuPercent
        self.hasFreshEvidence = hasFreshEvidence
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

    /// How recently a session transcript must have been written to count as
    /// live evidence of work. Transcripts stream continuously during
    /// generation and tool turns, so a short window keeps the idle flip snappy.
    public static let evidenceFreshWindow: TimeInterval = 15

    private let ttl: TimeInterval
    private let now: () -> Date
    /// Produces the raw `ps` output (`nil` on failure). Injectable so the
    /// cache/refresh logic can be unit-tested without spawning processes.
    private let fetch: @Sendable () -> String?
    /// Latest transcript write for (agent, cwd), or `nil` when the agent has
    /// no known transcript. Injectable so evidence logic is unit-testable.
    private let evidence: @Sendable (_ agent: String, _ cwd: String?) -> Date?
    private let lock = NSLock()
    private var cached: AgentSnapshot = .empty
    private var lastFetch: Date?
    private var isRefreshing = false

    public init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping @Sendable () -> String? = PSAgentActivityMonitor.runPS,
        evidence: @escaping @Sendable (_ agent: String, _ cwd: String?) -> Date? = PSAgentActivityMonitor.transcriptActivity
    ) {
        self.ttl = ttl
        self.now = now
        self.fetch = fetch
        self.evidence = evidence
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
                var sessions = Self.sessions(from: samples)
                // Decorate with transcript evidence: a session whose
                // transcript was written within the freshness window is
                // working, no matter what its CPU says.
                let cutoff = self.now().addingTimeInterval(-Self.evidenceFreshWindow)
                for index in sessions.indices {
                    let session = sessions[index]
                    if let written = self.evidence(session.agent, Self.processCwd(session.pid)) {
                        sessions[index].hasFreshEvidence = written >= cutoff
                    }
                }
                self.withLock {
                    self.cached = AgentSnapshot(sessions: sessions)
                    self.lastFetch = self.now()
                    self.isRefreshing = false
                }
            }
        }
        return snapshot
    }

    /// The working directory of a (same-user) process, or `nil`.
    static func processCwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
        }
    }

    /// When this agent last wrote to its on-disk session data for `cwd`, or
    /// `nil` for agents whose transcripts we don't know how to find. This is
    /// the "real work" signal: claude, grok, and codex all stream session
    /// files continuously while working.
    @Sendable public static func transcriptActivity(agent: String, cwd: String?) -> Date? {
        let home = NSHomeDirectory()
        switch agent {
        case "claude":
            // ~/.claude/projects/<cwd with every non-alphanumeric as "-">/*.jsonl
            guard let cwd else { return nil }
            return newestModification(in: "\(home)/.claude/projects/\(claudeProjectDirName(forCwd: cwd))")
        case "grok":
            // ~/.grok/sessions/<percent-encoded cwd>/ per-project session files.
            guard let cwd else { return nil }
            return newestModification(in: "\(home)/.grok/sessions/\(grokSessionDirName(forCwd: cwd))")
        case "codex":
            // ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl: date-keyed, not
            // cwd-keyed, so today's directory stands in for every session.
            let day = DateFormatter()
            day.dateFormat = "yyyy/MM/dd"
            day.timeZone = .current
            return newestModification(in: "\(home)/.codex/sessions/\(day.string(from: Date()))")
        default:
            return nil
        }
    }

    /// Claude Code's per-project transcript folder name: the working
    /// directory with every non-alphanumeric character flattened to "-"
    /// (`/Users/x/git/pueev_web` becomes `-Users-x-git-pueev-web`).
    static func claudeProjectDirName(forCwd cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Grok's per-project session folder name: the working directory
    /// percent-encoded with only RFC 3986 unreserved characters kept
    /// (`/Users/x/git/demo` becomes `%2FUsers%2Fx%2Fgit%2Fdemo`).
    static func grokSessionDirName(forCwd cwd: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: unreserved) ?? cwd
    }

    /// The newest modification date among the files directly inside `path`,
    /// or `nil` when the directory doesn't exist or is empty.
    private static func newestModification(in path: String) -> Date? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return nil }
        var newest: Date?
        for name in names {
            guard let date = (try? manager.attributesOfItem(atPath: "\(path)/\(name)"))?[.modificationDate] as? Date else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
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
/// subtree's smoothed CPU share relative to that session's own idle level.
///
/// Fixed thresholds don't generalize across agents: an idle claude sits near
/// 0-2% of a core, an idle grok near 2-3%, and an idle agy animates at 6-12%,
/// while their working levels differ just as much. So each session learns a
/// baseline (a decaying minimum of its smoothed CPU) and "working" means the
/// average has risen a dead-band above that baseline, with hysteresis so a
/// level hovering at the boundary doesn't flap. An absolute floor catches a
/// session that is born busy (its baseline is first learned at the working
/// level, so the relative test alone would miss it). A genuinely zero-CPU
/// stretch (a long network wait) still reads as idle by design; the release
/// grace the factory wraps this trigger in is what bridges those, not the
/// thresholds.
public final class AgentActivityTrigger: Trigger {
    /// How far (percent of one core) the average must rise above the
    /// session's baseline to turn "working".
    public static let onDeltaPercent = 4.0
    /// How far above the baseline the average must stay to remain "working";
    /// below it the session turns idle again (the hysteresis dead-band).
    public static let offDeltaPercent = 1.5
    /// Smoothed CPU at which a session is working no matter its baseline: no
    /// agent idles this hot, and it covers a session first seen mid-task.
    public static let hardWorkingFloorPercent = 20.0
    /// How fast the learned baseline drifts upward per tick while idle, so it
    /// tracks a TUI whose idle level shifts. It snaps *down* instantly, and
    /// is frozen while working so a long task can't erode its own headroom.
    static let baselineCreepPerTick = 0.05
    /// Smoothing weight of each new sample; 0.25 at one sample per second
    /// settles a sustained change in a few seconds while damping the sizable
    /// tick-to-tick noise of animated TUIs.
    static let alpha = 0.25
    /// The release grace the factory applies unless the rule overrides it.
    public static let defaultGrace: TimeInterval = 60

    /// Per-session EMA + learned-baseline + hysteresis state.
    public struct State: Equatable, Sendable {
        public var average: Double?
        /// The session's learned idle CPU level (a decaying minimum of
        /// ``average``), or `nil` before the first sample.
        public var baseline: Double?
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
            let stepped = Self.step(
                smoothing[session.pid] ?? State(),
                sample: session.cpuPercent,
                freshEvidence: session.hasFreshEvidence
            )
            next[session.pid] = stepped
            return SessionState(session: session, isWorking: stepped.isWorking)
        }
        smoothing = next
    }

    public func isSatisfied() -> Bool {
        sessionStates.contains { $0.isWorking }
    }

    /// Pure decision step, exposed for direct unit testing. `freshEvidence`
    /// (a transcript written moments ago) is proof of work and wins outright;
    /// the CPU heuristic decides for agents that leave no transcript.
    static func step(_ state: State, sample: Double, freshEvidence: Bool = false) -> State {
        var next = state
        let clamped = max(sample, 0)
        let average = state.average.map { $0 + alpha * (clamped - $0) } ?? clamped
        next.average = average

        // Learn the idle level while idle: snap down to any new minimum,
        // drift upward slowly toward the observed average. Frozen entirely
        // while working: a working session must neither raise the bar it is
        // measured against nor drag the bar down with it as it winds down
        // (a mid-task dip would otherwise read as "new idle level" and flip
        // the verdict while the task is still running).
        var baseline = state.baseline ?? average
        if !state.isWorking {
            baseline = average < baseline ? average : min(baseline + Self.baselineCreepPerTick, average)
        }
        next.baseline = baseline

        let delta = state.isWorking ? Self.offDeltaPercent : Self.onDeltaPercent
        next.isWorking = freshEvidence
            || average >= baseline + delta
            || average >= Self.hardWorkingFloorPercent
        return next
    }
}

extension AgentActivityTrigger: TriggerDetailProviding {
    public var detailRows: [RuleDetail] {
        sessionStates.map { RuleDetail(label: $0.session.label, active: $0.isWorking) }
    }
}
