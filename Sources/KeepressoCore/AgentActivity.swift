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
    /// Exact state reported by installed lifecycle hooks, or `nil` when this
    /// session has no live hook record; then transcript + CPU decide.
    public var hookState: AgentHooks.HookSessionState?
    /// Semantic activity token from the hook record ("running-command", ...).
    public var hookDetail: String?
    /// When the joined hook record was last written, so a newer transcript
    /// write can outrank its verdict.
    public var hookUpdatedAt: Date?
    /// Where the session runs, classified by the hook's ancestor walk.
    public var origin: AgentHooks.HookSessionOrigin?

    public init(
        pid: Int32,
        agent: String,
        tty: String?,
        cpuPercent: Double,
        hasFreshEvidence: Bool = false,
        hookState: AgentHooks.HookSessionState? = nil,
        hookDetail: String? = nil,
        origin: AgentHooks.HookSessionOrigin? = nil
    ) {
        self.pid = pid
        self.agent = agent
        self.tty = tty
        self.cpuPercent = cpuPercent
        self.hasFreshEvidence = hasFreshEvidence
        self.hookState = hookState
        self.hookDetail = hookDetail
        self.origin = origin
    }

    /// A short display label. The classified origin leads, so an app or IDE
    /// session is named as such ("claude (Claude app)") even when it holds a
    /// pty; terminal sessions show their tty ("claude (s003)"), and a session
    /// with neither origin nor tty falls back to the pid.
    public var label: String {
        switch origin {
        case .claudeApp: return "\(agent) (\(L("Claude app")))"
        case .ide: return "\(agent) (\(L("IDE")))"
        case .terminal where tty == nil: return "\(agent) (\(L("terminal")))"
        default:
            if let tty { return "\(agent) (\(tty))" }
            return "\(agent) (pid \(pid))"
        }
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
    /// The live hook records to join onto sessions. Injectable so the join
    /// and precedence logic is unit-testable without touching the disk.
    private let hookRecords: @Sendable (_ now: Date) -> [AgentHooks.HookRecord]
    /// Classifies where a terminal-less session runs (Claude app, IDE) by
    /// walking its ancestors, so app sessions are named even before any hook
    /// record exists. Injectable so the decoration is unit-testable.
    private let classifyOrigin: @Sendable (_ pid: Int32) -> AgentHooks.HookSessionOrigin?
    private let lock = NSLock()
    private var cached: AgentSnapshot = .empty
    private var lastFetch: Date?
    private var isRefreshing = false

    public init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping @Sendable () -> String? = PSAgentActivityMonitor.runPS,
        evidence: @escaping @Sendable (_ agent: String, _ cwd: String?) -> Date? = PSAgentActivityMonitor.transcriptActivity,
        hookRecords: @escaping @Sendable (_ now: Date) -> [AgentHooks.HookRecord] = { AgentHooks.readHookRecords(now: $0) },
        classifyOrigin: @escaping @Sendable (_ pid: Int32) -> AgentHooks.HookSessionOrigin? = { AgentHooks.classifyOrigin(abovePid: $0) }
    ) {
        self.ttl = ttl
        self.now = now
        self.fetch = fetch
        self.evidence = evidence
        self.hookRecords = hookRecords
        self.classifyOrigin = classifyOrigin
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
                // A transient `ps` failure keeps the previous snapshot: an
                // empty one would make the trigger prune every session's
                // smoothing state, and a mid-task session would rejoin with
                // a baseline learned at its working level.
                guard let raw = self.fetch() else {
                    self.withLock {
                        self.lastFetch = self.now()
                        self.isRefreshing = false
                    }
                    return
                }
                var sessions = Self.sessions(from: Self.parse(raw))
                // Decorate with transcript evidence: a session whose
                // transcript was written within the freshness window is
                // working, no matter what its CPU says.
                let scanTime = self.now()
                let cutoff = scanTime.addingTimeInterval(-Self.evidenceFreshWindow)
                var cwds: [Int32: String] = [:]
                var evidenceDates: [Int32: Date] = [:]
                for index in sessions.indices {
                    let session = sessions[index]
                    let cwd = Self.processCwd(session.pid)
                    if let cwd { cwds[session.pid] = cwd }
                    if let written = self.evidence(session.agent, cwd) {
                        evidenceDates[session.pid] = written
                        sessions[index].hasFreshEvidence = written >= cutoff
                    }
                    // Name sessions by their host (Claude app, IDE) up front;
                    // a joined hook record can still refine it. Every session
                    // is classified, not just terminal-less ones: an app can
                    // hold a pty for its embedded CLI, and the label promises
                    // to name such sessions by their host.
                    sessions[index].origin = self.classifyOrigin(session.pid)
                }
                // Stamp hook evidence: exact state edges beat both heuristics.
                sessions = Self.applyHookRecords(
                    self.hookRecords(scanTime), to: sessions, cwdOf: { cwds[$0] })
                // A not-working verdict older than a fresh transcript write
                // is stale information, not an edge: the main turn's Stop
                // hook fires while a background subagent works on (its
                // transcript keeps streaming, but it emits no hook event
                // until its next tool call), and a minute later the idle
                // nudge fires a Notification that writes a plain `waiting`
                // record for the same still-working session. Drop both and
                // let the evidence decide. `waiting-approval` stays: it
                // already reads as working, and the approval edge is exact.
                for index in sessions.indices {
                    let state = sessions[index].hookState
                    let overridable = state == .idle
                        || (state == .waiting && sessions[index].hookDetail != "waiting-approval")
                    if overridable,
                       sessions[index].hasFreshEvidence,
                       let stamped = sessions[index].hookUpdatedAt,
                       let written = evidenceDates[sessions[index].pid],
                       written > stamped {
                        sessions[index].hookState = nil
                        sessions[index].hookDetail = nil
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

    /// Joins hook records onto detected sessions: by the record's agent pid
    /// first (exact, survives two sessions sharing a directory), by working
    /// directory as the fallback, and only when that fallback is unambiguous
    /// (exactly one unclaimed session in that directory). Newest records win
    /// contested sessions. Pure, so tests script both sides.
    static func applyHookRecords(
        _ records: [AgentHooks.HookRecord],
        to sessions: [AgentSession],
        cwdOf: (Int32) -> String?
    ) -> [AgentSession] {
        guard !records.isEmpty, !sessions.isEmpty else { return sessions }
        var result = sessions
        var claimed: Set<Int> = []
        var unmatchedByPid: [AgentHooks.HookRecord] = []
        for record in records.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let pid = record.agentPid,
               let index = result.firstIndex(where: { $0.pid == pid }) {
                if claimed.insert(index).inserted { stamp(&result[index], with: record) }
            } else {
                unmatchedByPid.append(record)
            }
        }
        for record in unmatchedByPid {
            guard let cwd = record.cwd else { continue }
            let candidates = result.indices.filter {
                !claimed.contains($0) && cwdOf(result[$0].pid) == cwd
            }
            guard candidates.count == 1, let index = candidates.first else { continue }
            claimed.insert(index)
            stamp(&result[index], with: record)
        }
        return result
    }

    private static func stamp(_ session: inout AgentSession, with record: AgentHooks.HookRecord) {
        session.hookState = record.state
        session.hookDetail = record.detail
        session.hookUpdatedAt = record.updatedAt
        // A record with no classified origin must not erase what the ps-scan
        // ancestor walk already determined.
        if let origin = record.origin { session.origin = origin }
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
            return claudeTranscriptWrite(inProjectDir: "\(home)/.claude/projects/\(claudeProjectDirName(forCwd: cwd))")
        case "grok":
            // ~/.grok/sessions/<percent-encoded cwd>/ per-project session files.
            guard let cwd else { return nil }
            return newestModification(in: "\(home)/.grok/sessions/\(grokSessionDirName(forCwd: cwd))")
        case "codex":
            // ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl: date-keyed, not
            // cwd-keyed, so the day directories stand in for every session.
            // POSIX locale + Gregorian calendar, or a non-Gregorian user
            // calendar (e.g. Buddhist) renders a year no directory matches.
            // Yesterday is checked too: a rollout file is created at session
            // start, so a session spanning midnight keeps appending to the
            // previous day's directory.
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.calendar = Calendar(identifier: .gregorian)
            day.dateFormat = "yyyy/MM/dd"
            day.timeZone = .current
            let today = Date()
            return [today, today.addingTimeInterval(-86_400)]
                .compactMap { newestModification(in: "\(home)/.codex/sessions/\(day.string(from: $0))") }
                .max()
        default:
            return nil
        }
    }

    /// The newest write in a Claude Code project folder. Session transcripts
    /// sit directly in it, but a background subagent streams to
    /// `<session-id>/subagents/agent-*.jsonl` one level down, and appends
    /// there never touch the parent directories' mtimes; without descending,
    /// a subagent working alone leaves no visible evidence.
    static func claudeTranscriptWrite(inProjectDir path: String) -> Date? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return nil }
        var newest = newestModification(in: path)
        for name in names {
            let subagents = "\(path)/\(name)/subagents"
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: subagents, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let written = newestModification(in: subagents) else { continue }
            if newest.map({ written > $0 }) ?? true { newest = written }
        }
        return newest
    }

    /// Claude Code's per-project transcript folder name: the working
    /// directory with every non-alphanumeric character flattened to "-"
    /// (`/Users/x/git/pueev_web` becomes `-Users-x-git-pueev-web`). The
    /// alphanumeric class is ASCII-only (`[^a-zA-Z0-9]` upstream), so an
    /// accented letter in the path flattens too; keeping it would map the
    /// session to a directory that never exists.
    static func claudeProjectDirName(forCwd cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
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
    /// the script it runs) exactly and case-sensitively, never substring.
    /// Case matters: the Claude desktop app's Electron binary is `Claude`
    /// (as are its `Claude Helper` processes), while the CLI, including the
    /// copy embedded in that app, is `claude`. A case-blind match would root
    /// the session at the whole desktop app, whose process tree burns CPU
    /// constantly and hides the real agent process from hook joins.
    static func agentName(for command: String, agents: [String]) -> String? {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first else { return nil }
        var candidate = basename(first)
        if runtimeWrappers.contains(candidate.lowercased()) {
            guard let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
            candidate = basename(script)
        }
        if let agent = agents.first(where: { $0 == candidate }) { return agent }
        // An app-bundle binary's path can hold spaces anywhere before the
        // bundle ("~/Library/Application Support/Claude/claude-code/…"), which
        // the token split above mangles. The name after the last bundle marker
        // is unambiguous; agent names hold no spaces, so its first word is the
        // binary ("claude" for the Claude Code copy embedded in the desktop
        // app, "Claude" for the app itself, which case-sensitivity rejects).
        if let marker = command.range(of: "/Contents/MacOS/", options: .backwards) {
            let name = command[marker.upperBound...].prefix(while: { $0 != " " })
            return agents.first { $0 == name }
        }
        return nil
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
    /// tracks a TUI whose idle level shifts. It snaps *down* instantly. While
    /// working it creeps at the same rate but only toward the lowest average
    /// the episode has seen: bursty real work keeps its headroom (the bar
    /// never rises past the episode's own floor), while a session whose idle
    /// level rose *during* the episode (a leftover dev server, a warmed-up
    /// MCP server) settles flat at the new floor, the bar catches up, and the
    /// trigger releases instead of holding the Mac awake until process exit.
    static let baselineCreepPerTick = 0.05
    /// Smoothing weight of each new sample; 0.25 at one sample per second
    /// settles a sustained change in a few seconds while damping the sizable
    /// tick-to-tick noise of animated TUIs.
    static let alpha = 0.25
    /// The release grace the factory applies unless the rule overrides it.
    /// Three minutes: a minute is enough to bridge a typical zero-CPU network
    /// wait but not a slow model turn or a long-running tool call, and letting
    /// the Mac sleep out from under a working agent costs far more than a few
    /// idle minutes awake.
    public static let defaultGrace: TimeInterval = 180

    /// Per-session EMA + learned-baseline + hysteresis state.
    public struct State: Equatable, Sendable {
        public var average: Double?
        /// The session's learned idle CPU level (a decaying minimum of
        /// ``average``), or `nil` before the first sample.
        public var baseline: Double?
        /// The lowest ``average`` seen during the current working episode,
        /// the ceiling the baseline may creep toward while working; `nil`
        /// while idle.
        public var episodeFloor: Double?
        public var isWorking = false
        public init() {}
    }

    /// One session with its live working/idle verdict, for the menu.
    public struct SessionState: Equatable {
        public let session: AgentSession
        public let isWorking: Bool
    }

    private let monitor: AgentActivityMonitoring
    /// See ``AgentRule/countWaitingAsWorking``.
    public let countWaitingAsWorking: Bool
    private var smoothing: [Int32: State] = [:]
    /// Last tick's overall working verdict, so the host can detect the
    /// working → idle edge for outbound hooks.
    private var wasWorking = false

    /// The sessions seen by the last ``tick()`` with their verdicts, a pure
    /// read for the menu's per-session rows.
    public private(set) var sessionStates: [SessionState] = []

    /// True when this tick flipped from any-working to none-working. The host
    /// (AppModel) reads it after reconcile to fire the agent-idle hook. Cleared
    /// on the next tick that does not make the same edge.
    public private(set) var justWentIdle = false

    public init(
        monitor: AgentActivityMonitoring = PSAgentActivityMonitor(),
        countWaitingAsWorking: Bool = false
    ) {
        self.monitor = monitor
        self.countWaitingAsWorking = countWaitingAsWorking
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
                freshEvidence: session.hasFreshEvidence,
                hookState: session.hookState,
                hookDetail: session.hookDetail,
                countWaitingAsWorking: countWaitingAsWorking
            )
            next[session.pid] = stepped
            return SessionState(session: session, isWorking: stepped.isWorking)
        }
        smoothing = next
        let working = sessionStates.contains { $0.isWorking }
        justWentIdle = wasWorking && !working
        wasWorking = working
    }

    public func isSatisfied() -> Bool {
        sessionStates.contains { $0.isWorking }
    }

    /// Pure decision step, exposed for direct unit testing. A live hook state
    /// is an exact edge and decides outright: `working` is on; `waiting` is
    /// on for a pending approval always, and for the plain idle-nudge waiting
    /// only when ``countWaitingAsWorking`` is set; `idle` is off.
    /// Otherwise `freshEvidence` (a transcript written moments ago)
    /// is proof of work and wins; the CPU heuristic decides for agents that
    /// leave no transcript. The EMA and baseline advance on every tick
    /// regardless, so the CPU fallback stays warm if hooks disappear.
    static func step(
        _ state: State,
        sample: Double,
        freshEvidence: Bool = false,
        hookState: AgentHooks.HookSessionState? = nil,
        hookDetail: String? = nil,
        countWaitingAsWorking: Bool = false
    ) -> State {
        var next = state
        let clamped = max(sample, 0)
        let average = state.average.map { $0 + alpha * (clamped - $0) } ?? clamped
        next.average = average

        // Learn the idle level while idle: snap down to any new minimum,
        // drift upward slowly toward the observed average. While working it
        // never snaps down (a mid-task dip must not read as "new idle
        // level") and creeps upward only toward the lowest average this
        // episode has seen: bursty work keeps its headroom, but an idle
        // floor that rose during the episode (a leftover child process) is
        // eventually adopted as the new baseline, or the session would stay
        // "working" until its process exits (see ``baselineCreepPerTick``).
        var baseline = state.baseline ?? average
        if state.isWorking {
            let floor = min(state.episodeFloor ?? average, average)
            next.episodeFloor = floor
            if floor > baseline {
                baseline = min(baseline + Self.baselineCreepPerTick, floor)
            }
        } else {
            next.episodeFloor = nil
            baseline = average < baseline ? average : min(baseline + Self.baselineCreepPerTick, average)
        }
        next.baseline = baseline

        if let hookState {
            let waitingCounts = hookDetail == "waiting-approval" || countWaitingAsWorking
            next.isWorking = hookState == .working
                || (hookState == .waiting && waitingCounts)
        } else {
            let delta = state.isWorking ? Self.offDeltaPercent : Self.onDeltaPercent
            next.isWorking = freshEvidence
                || average >= baseline + delta
                || average >= Self.hardWorkingFloorPercent
        }
        return next
    }
}

extension AgentActivityTrigger: TriggerDetailProviding {
    public var detailRows: [RuleDetail] {
        sessionStates.map {
            RuleDetail(
                label: Self.rowLabel(for: $0), active: $0.isWorking,
                animated: $0.isWorking, agent: $0.session.agent)
        }
    }

    /// "claude (s003) - running command": the session label plus, when hooks
    /// report one, what it is doing (or waiting on) right now.
    static func rowLabel(for state: SessionState) -> String {
        let detail: String?
        if state.session.hookState == .waiting {
            detail = Self.detailText(forToken: state.session.hookDetail ?? "waiting")
        } else if state.isWorking {
            detail = state.session.hookDetail.flatMap(Self.detailText(forToken:))
        } else {
            detail = nil
        }
        guard let detail else { return state.session.label }
        return "\(state.session.label) - \(detail)"
    }

    /// Localizes a semantic detail token written by the hook CLI. Tokens stay
    /// language-neutral on disk so every UI language renders its own text.
    static func detailText(forToken token: String) -> String? {
        switch token {
        case "running-command": return L("running command")
        case "editing": return L("editing")
        case "reading": return L("reading")
        case "searching": return L("searching")
        case "subagent": return L("running subagent")
        case "browsing": return L("browsing")
        case "waiting-approval": return L("waiting for approval")
        case "waiting": return L("waiting")
        default:
            guard token.hasPrefix("tool:") else { return nil }
            return L("using %@", String(token.dropFirst("tool:".count)))
        }
    }
}
