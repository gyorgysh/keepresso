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
    /// Whether only on-disk evidence may call this session working, with the
    /// CPU heuristic skipped entirely.
    ///
    /// For an agent embedded in a running editor, whose host process is up
    /// whether or not anything is being asked of it, CPU is not weak evidence
    /// but misleading evidence: measured on Antigravity's `language_server`, it
    /// read 0.0 through a working stretch (the agent was waiting on a command
    /// that burned nothing) and blipped to 0.9 while idle. A learned baseline
    /// can't rescue a signal that moves the wrong way.
    public var evidenceOnly: Bool

    public init(
        pid: Int32,
        agent: String,
        tty: String?,
        cpuPercent: Double,
        hasFreshEvidence: Bool = false,
        hookState: AgentHooks.HookSessionState? = nil,
        hookDetail: String? = nil,
        origin: AgentHooks.HookSessionOrigin? = nil,
        evidenceOnly: Bool = false
    ) {
        self.evidenceOnly = evidenceOnly
        self.pid = pid
        self.agent = agent
        self.tty = tty
        self.cpuPercent = cpuPercent
        self.hasFreshEvidence = hasFreshEvidence
        self.hookState = hookState
        self.hookDetail = hookDetail
        self.hookUpdatedAt = nil
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
    /// name mentioning an agent can't count as a session), with the resolved
    /// executable path as a second chance (see ``resolvedAgentName(for:agents:pathOf:)``).
    /// CLI binaries only: a bare "cursor" or "antigravity" would match the
    /// whole IDE app, whose process tree burns CPU constantly, so their
    /// terminal agents are listed by their actual command names instead
    /// (cursor-agent, agy).
    public static let agentCommands = [
        "claude", "codex", "gemini", "grok", "agy", "aider", "goose",
        "cursor-agent", "opencode", "opencode2", "amp", "copilot", "droid",
        "auggie", "qwen", "pi", "hermes", "kilo", "dsh", "muse",
    ]

    /// The names that may also be matched against a *component* of a resolved
    /// executable path, rather than only against a command's basename.
    ///
    /// Path matching is what finds a tool the command line doesn't name: a
    /// versioned Claude Code binary (`.../claude/versions/2.1.219`), or Cursor
    /// launched through its bare `agent` alias
    /// (`.../cursor-agent/versions/<v>/node`). It is also much looser, because
    /// any directory anywhere in the path can satisfy it, so the short names
    /// are held back from it: a user whose home is `/Users/pi` would otherwise
    /// have every process they run matched as an agent, and `amp` and `agy`
    /// are only a little less likely to appear as some unrelated folder.
    /// Those short names, and ``pathMatchExcludedAgents``, are still detected
    /// by their command's basename, which is exact; they just don't get the
    /// fuzzier second chance.
    static let pathMatchMinimumLength = 4
    /// Four-letter names that are still too common as folder names to trust
    /// in a path (`kilo` matches `/Users/kilo/...`, `muse` matches
    /// `/Users/muse/...` and `~/.local/share/muse/...`). Basename matching
    /// still finds them; they just skip the fuzzier second chance, like `pi`.
    /// Muse's live binary is `muse-bin-<version>`, matched by prefix in
    /// ``agentName(for:agents:)``, so excluding it from path matching does
    /// not hide a real session.
    static let pathMatchExcludedAgents: Set<String> = ["kilo", "muse"]
    public static let pathMatchableAgents = agentCommands.filter {
        $0.count >= pathMatchMinimumLength && !pathMatchExcludedAgents.contains($0)
    }

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

    /// Agents whose session store is written in bursts rather than streamed,
    /// with the window each one needs.
    ///
    /// Antigravity writes its conversation database around each agent step, not
    /// continuously: measured over a working session, writes landed a median 5s
    /// apart, with occasional gaps into the tens of seconds.
    ///
    /// Deliberately not widened past the worst gap. A window is only there to
    /// keep a row from blinking between steps; bridging a genuine pause is the
    /// rule's grace period, which is longer, user-visible and user-adjustable.
    /// Padding here would silently add itself to that grace, so a finished
    /// agent would hold the Mac awake for the sum of the two.
    static let evidenceWindowOverrides: [String: TimeInterval] = [
        "antigravity": 20,
        "agy": 20,
        // Bionic streams chat into per-project SQLite (WAL moves between
        // `.sqlite` / `-wal` / `-shm`). Live coding turns write often, but
        // cloud-model waits leave multi-tens-of-seconds gaps; 45s stays under
        // the rule grace while bridging those pauses.
        "bionic": 45,
        // OpenCode / OpenCode 2 / Kilo / Hermes write SQLite in bursts
        // (WAL moves between the db and its sidecars), same shape as
        // Antigravity's conversation store.
        "opencode": 20,
        "opencode2": 20,
        "kilo": 20,
        "hermes": 20,
    ]

    /// The freshness window for `agent`'s on-disk evidence.
    static func evidenceWindow(for agent: String) -> TimeInterval {
        evidenceWindowOverrides[agent] ?? evidenceFreshWindow
    }

    /// The marker in the command line of the process that hosts Antigravity's
    /// in-editor agent (`Antigravity.app/Contents/Resources/bin/language_server
    /// --override_ide_name antigravity …`).
    ///
    /// The bare binary name is useless here: a language server is a generic
    /// thing many editors ship, and matching it would root a session at any of
    /// them. The IDE-name flag is what makes the process Antigravity's, and it
    /// is the app's own argument, not something derived from a path that
    /// changes when the app moves.
    static let antigravityHostMarker = "--override_ide_name antigravity"

    /// Argv flag on Bionic's workspace Electron renderer
    /// (`Bionic Helper (Renderer) … --lmstudio-project-identifier=<uuid> …`).
    ///
    /// Not listed in ``agentCommands``: GPU helpers burn CPU for the UI
    /// whether the agent is working or not, and a basename match on every
    /// Helper would spam sessions. Host selection is ``isBionicAgentHost(_:)``.
    static let bionicHostMarker = "--lmstudio-project-identifier="
    /// Path fragments that identify Bionic (app bundle or its user-data dir).
    static let bionicHostPathHints = ["Bionic.app/", "/Application Support/Bionic"]
    /// npm / npx package marker for DeepSeek Harness. The interactive CLI is
    /// often `dsh`; the web UI is `npx @deepseek-ai/dsh web`, whose script
    /// basename is a generic `cli.js` that names no tool.
    static let dshHostMarker = "@deepseek-ai/dsh"

    private let ttl: TimeInterval
    private let now: () -> Date
    /// Produces the raw `ps` output (`nil` on failure). Injectable so the
    /// cache/refresh logic can be unit-tested without spawning processes.
    private let fetch: @Sendable () -> String?
    /// Latest transcript write for (agent, cwd, pid), or `nil` when the agent
    /// has no known transcript. Injectable so evidence logic is unit-testable.
    /// Grok joins by pid: never fall back to the project folder.
    private let evidence: @Sendable (_ agent: String, _ cwd: String?, _ pid: Int32) -> Date?
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
    /// When false, a refresh only parses `ps` into sessions and skips
    /// transcript walks, hook-record reads, cwd lookups, and origin
    /// classification. The trigger factory turns this off when no agent rule
    /// is live; tests leave it on.
    public var evidenceEnabled: Bool = true

    /// Default hook scan: drop a Codex Desktop working record after ten
    /// minutes unless that chat's rollout file is still inside the evidence
    /// window.
    public static func defaultHookRecords(now: Date) -> [AgentHooks.HookRecord] {
        AgentHooks.readHookRecords(
            now: now,
            hasFreshSharedHostEvidence: { sessionId in
                guard let written = codexRolloutWrite(forSessionId: sessionId, now: now) else {
                    return false
                }
                return written >= now.addingTimeInterval(-evidenceWindow(for: "codex"))
            }
        )
    }

    public init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping @Sendable () -> String? = SharedPSSnapshot.runPS,
        evidence: @escaping @Sendable (_ agent: String, _ cwd: String?, _ pid: Int32) -> Date? = PSAgentActivityMonitor.transcriptActivity,
        hookRecords: @escaping @Sendable (_ now: Date) -> [AgentHooks.HookRecord] = { defaultHookRecords(now: $0) },
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
                let collectEvidence = self.withLock { self.evidenceEnabled }
                if collectEvidence {
                    sessions = self.decorateWithEvidence(sessions)
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

    /// Transcript / hook / cwd / origin decoration that runs only while an
    /// agent rule is live. Kept as one method so the gated path stays a
    /// single boolean branch above.
    private func decorateWithEvidence(_ sessions: [AgentSession]) -> [AgentSession] {
        var sessions = sessions
        let scanTime = now()
        var cwds: [Int32: String] = [:]
        var evidenceDates: [Int32: Date] = [:]
        for index in sessions.indices {
            let session = sessions[index]
            let cwd = Self.processCwd(session.pid)
            if let cwd { cwds[session.pid] = cwd }
            if let written = evidence(session.agent, cwd, session.pid) {
                evidenceDates[session.pid] = written
                // Per agent: one that writes its store in bursts needs
                // a wider window than one that streams (see
                // ``evidenceWindowOverrides``).
                let cutoff = scanTime.addingTimeInterval(
                    -Self.evidenceWindow(for: session.agent))
                sessions[index].hasFreshEvidence = written >= cutoff
            }
            // Name sessions by their host (Claude app, IDE) up front;
            // a joined hook record can still refine it. Every session
            // is classified, not just terminal-less ones: an app can
            // hold a pty for its embedded CLI, and the label promises
            // to name such sessions by their host.
            // Only when the walk actually classifies something: an
            // editor host already knows it is one, and a nil verdict
            // must not erase that (for every other session the field
            // starts nil, so this is the same assignment as before).
            if let classified = classifyOrigin(session.pid) {
                sessions[index].origin = classified
            }
        }
        // Stamp hook evidence: exact state edges beat both heuristics.
        let hookRecords = hookRecords(scanTime)
        let join = Self.applyHookRecords(
            hookRecords, to: sessions, cwdOf: { cwds[$0] })
        sessions = join.sessions
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
        // When IDE hooks cover a host (Cursor / Antigravity ownerPid
        // rows), drop the parallel evidence-only process session for
        // that host. Otherwise a Stop that idles the hook-only chat
        // would still leave the language_server / editor host
        // "working" off conversation-DB freshness alone.
        sessions = Self.suppressingHookCoveredEvidenceHosts(
            sessions, hookRecords: hookRecords)
        // Sessions that exist only as hook records (an IDE's built-in
        // agent) are appended last: they have no process, so none of
        // the cwd, evidence, or origin decoration above applies.
        sessions.append(contentsOf: join.unclaimed.compactMap { record in
            guard var session = Self.hookOnlySession(from: record) else { return nil }
            if record.agent == "codex",
               let written = Self.codexRolloutWrite(forSessionId: record.sessionId) {
                let cutoff = scanTime.addingTimeInterval(-Self.evidenceWindow(for: "codex"))
                session.hasFreshEvidence = written >= cutoff
            }
            return session
        })
        return sessions
    }

    /// Joins hook records onto detected sessions: by the record's agent pid
    /// first (exact, survives two sessions sharing a directory), by working
    /// directory as the fallback, and only when that fallback is unambiguous
    /// (exactly one unclaimed session in that directory). Newest records win
    /// contested sessions. Pure, so tests script both sides.
    ///
    /// Records that already name an owning app (`ownerPid`, Cursor /
    /// Antigravity IDE chats) never cwd-join onto a process session: they are
    /// conversation-scoped rows that must become hook-only sessions, and
    /// stamping them onto a CLI host would let an idle IDE chat idle a live
    /// terminal agent that happens to share a cwd.
    static func applyHookRecords(
        _ records: [AgentHooks.HookRecord],
        to sessions: [AgentSession],
        cwdOf: (Int32) -> String?
    ) -> HookJoin {
        guard !records.isEmpty else { return HookJoin(sessions: sessions, unclaimed: []) }
        guard !sessions.isEmpty else { return HookJoin(sessions: sessions, unclaimed: records) }
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
        var unclaimed: [AgentHooks.HookRecord] = []
        for record in unmatchedByPid {
            // IDE / host-anchored records are conversation rows, not process
            // joins: keep them unclaimed so ``hookOnlySession(from:)`` builds
            // the session. Never cwd-join them onto a CLI or evidence host.
            if record.ownerPid != nil {
                unclaimed.append(record)
                continue
            }
            guard let cwd = record.cwd else {
                unclaimed.append(record)
                continue
            }
            let candidates = result.indices.filter {
                !claimed.contains($0) && cwdOf(result[$0].pid) == cwd
            }
            guard candidates.count == 1, let index = candidates.first else {
                unclaimed.append(record)
                continue
            }
            claimed.insert(index)
            stamp(&result[index], with: record)
        }
        return HookJoin(sessions: result, unclaimed: unclaimed)
    }

    /// Drop evidence-only host process sessions whose pid is named as
    /// `ownerPid` by a live IDE hook record. Hooks then own the working
    /// signal for that editor; conversation-DB freshness on the host cannot
    /// keep the trigger on after Stop.
    static func suppressingHookCoveredEvidenceHosts(
        _ sessions: [AgentSession],
        hookRecords: [AgentHooks.HookRecord]
    ) -> [AgentSession] {
        let hosts = Set(hookRecords.compactMap(\.ownerPid))
        guard !hosts.isEmpty else { return sessions }
        return sessions.filter { !($0.evidenceOnly && hosts.contains($0.pid)) }
    }

    /// The result of joining hook records onto `ps`-detected sessions.
    struct HookJoin: Equatable {
        var sessions: [AgentSession]
        /// Records that matched no detected process. Most are transient (a
        /// session caught between the scan and the record), but a record
        /// carrying an owning app is a session that has no process to find:
        /// see ``hookOnlySession(from:)``.
        var unclaimed: [AgentHooks.HookRecord]
    }

    /// A session reconstructed from a hook record alone, for agents that run
    /// inside their editor rather than as a command. Cursor's IDE agent and
    /// Antigravity's in-editor agent are the cases that force this: both live
    /// inside a process shared across conversations, so there is no per-chat
    /// process to find and no subtree whose CPU means anything. The hook
    /// record is the entire signal, keyed by conversation so two chats never
    /// collapse onto one row.
    ///
    /// Only a record naming a live owning app qualifies (``AgentHooks/readHookRecords(now:in:isAlive:isHostAlive:)``
    /// has already verified that pid), so a record left unclaimed for the
    /// ordinary reason, a CLI session racing the scan, never invents a row.
    static func hookOnlySession(from record: AgentHooks.HookRecord) -> AgentSession? {
        guard record.ownerPid != nil else { return nil }
        var session = AgentSession(
            pid: syntheticPid(forSessionId: record.sessionId),
            agent: record.agent ?? "agent",
            tty: nil,
            // No process, so no CPU: the hook state decides this session
            // outright, and the heuristics it would otherwise fall back to
            // read as idle, which is the right answer once hooks go quiet.
            cpuPercent: 0,
            hookState: record.state,
            hookDetail: record.detail,
            origin: record.origin
        )
        session.hookUpdatedAt = record.updatedAt
        return session
    }

    /// A stable, always-negative stand-in pid for a session that has no
    /// process, so it can key the trigger's per-session smoothing without ever
    /// colliding with a real pid. FNV-1a rather than `hashValue`, which is
    /// seeded per process and would re-key every session on relaunch.
    static func syntheticPid(forSessionId id: String) -> Int32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return -Int32(hash % 2_000_000_000) - 1
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
    /// files continuously while working. `pid` is ignored except for Grok,
    /// which joins by conversation.
    @Sendable public static func transcriptActivity(agent: String, cwd: String?, pid: Int32) -> Date? {
        let home = NSHomeDirectory()
        switch agent {
        case "claude":
            // ~/.claude/projects/<cwd with every non-alphanumeric as "-">/*.jsonl
            guard let cwd else { return nil }
            return claudeTranscriptWrite(inProjectDir: "\(home)/.claude/projects/\(claudeProjectDirName(forCwd: cwd))")
        case "grok":
            return grokTranscriptWrite(pid: pid, cwd: cwd, home: home)
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
        case "antigravity", "agy":
            // Antigravity keeps one SQLite database per conversation, the app
            // under `antigravity/` and its CLI under `antigravity-cli/`. Not
            // cwd-keyed, so the directory stands in for every session, like the
            // codex case above.
            //
            // The whole directory, never a named file: SQLite checkpoints the
            // `-wal` and deletes it, so the freshest write moves between
            // `<id>.db`, `<id>.db-wal` and `<id>.db-shm` over a session, and a
            // watcher pinned to one of them goes blind at the checkpoint.
            let root = agent == "agy" ? "antigravity-cli" : "antigravity"
            return newestModification(in: "\(home)/.gemini/\(root)/conversations")
        case "bionic":
            // LM Studio Bionic keeps one `ng-sessions.sqlite` per project under
            // `~/.lmstudio/apps/bionic/projects/<uuid>/.internal/`. Not
            // cwd-keyed. Scan every project: the workspace renderer's
            // `--lmstudio-project-identifier=` can stay stale after a project
            // switch, so pinning to argv would miss real work. Only the
            // session store files count (not other churn in `.internal`).
            return bionicSessionWrite(home: home)
        case "opencode", "opencode2":
            return opencodeStoreWrite(home: home)
        case "kilo":
            return kiloStoreWrite(home: home)
        case "hermes":
            return hermesStoreWrite(home: home)
        case "dsh":
            return dshSessionWrite(home: home)
        case "muse":
            return museSessionWrite(home: home)
        default:
            return nil
        }
    }

    /// Newest write across every Bionic project's `ng-sessions.sqlite` store
    /// (including `-wal` / `-shm` sidecars). Ignores other files in `.internal`
    /// so UI or cache mtimes cannot keep the evidence-only session "working".
    static func bionicSessionWrite(home: String = NSHomeDirectory()) -> Date? {
        let projects = "\(home)/.lmstudio/apps/bionic/projects"
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: projects) else { return nil }
        var newest: Date?
        for name in names {
            let internalDir = "\(projects)/\(name)/.internal"
            guard let written = newestSessionStoreWrite(in: internalDir) else {
                continue
            }
            if newest.map({ written > $0 }) ?? true { newest = written }
        }
        return newest
    }

    /// Whether a matched agent process is a shared host whose CPU is a lie.
    /// Codex Desktop's `app-server`, Kilo's `kilo serve`, and DeepSeek's
    /// `dsh web` stay up whether or not a conversation is running.
    static func isEvidenceOnlyHost(agent: String, command: String) -> Bool {
        switch agent {
        case "codex": return isCodexAppServerCommand(command)
        case "kilo": return commandHasToken(command, "serve")
        case "dsh": return commandHasToken(command, "web")
        default: return false
        }
    }

    /// Exact token match on a `ps` command line (`app-server`, `serve`, `web`).
    static func commandHasToken(_ command: String, _ token: String) -> Bool {
        command.split(whereSeparator: \.isWhitespace).contains { $0 == token }
    }

    /// `codex` whose argv includes the `app-server` subcommand: Codex Desktop's
    /// shared host, not a dedicated CLI session.
    static func isCodexAppServerCommand(_ command: String) -> Bool {
        agentName(for: command, agents: ["codex"]) == "codex"
            && commandHasToken(command, "app-server")
    }

    /// Newest mtime of `basename` and its SQLite sidecars (`-wal`, `-shm`)
    /// inside `directory`. Does not list the directory, so sibling logs cannot
    /// count as evidence.
    static func newestSqliteStoreWrite(in directory: String, basename: String) -> Date? {
        let manager = FileManager.default
        var newest: Date?
        for name in [basename, "\(basename)-wal", "\(basename)-shm"] {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

    /// OpenCode / OpenCode 2 share one store. `OPENCODE_DATA_DIR` relocates it.
    static func opencodeStoreWrite(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        if let override = environment["OPENCODE_DATA_DIR"], !override.isEmpty {
            return newestSqliteStoreWrite(in: override, basename: "opencode.db")
        }
        let candidates = [
            "\(home)/.local/share/opencode",
            "\(home)/Library/Application Support/opencode",
        ]
        return candidates.compactMap { newestSqliteStoreWrite(in: $0, basename: "opencode.db") }.max()
    }

    /// Kilo Code's OpenCode-fork store. `KILO_DATA_DIR` relocates it.
    static func kiloStoreWrite(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        if let override = environment["KILO_DATA_DIR"], !override.isEmpty {
            return newestSqliteStoreWrite(in: override, basename: "kilo.db")
        }
        let candidates = [
            "\(home)/.local/share/kilo",
            "\(home)/Library/Application Support/kilo",
        ]
        return candidates.compactMap { newestSqliteStoreWrite(in: $0, basename: "kilo.db") }.max()
    }

    /// Hermes Agent state db, plus per-profile copies. `HERMES_HOME` relocates
    /// the tree (default `~/.hermes`).
    static func hermesStoreWrite(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        let root = environment["HERMES_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.hermes"
        var newest = newestSqliteStoreWrite(in: root, basename: "state.db")
        let profiles = "\(root)/profiles"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: profiles) else {
            return newest
        }
        for name in names {
            guard let written = newestSqliteStoreWrite(in: "\(profiles)/\(name)", basename: "state.db")
            else { continue }
            if newest.map({ written > $0 }) ?? true { newest = written }
        }
        return newest
    }

    /// Muse Code event logs:
    /// `$XDG_DATA_HOME/muse/sessions/YYYY/MM/DD/<uuid>/session.jsonl`, plus
    /// `subagent/<id>/session.jsonl` one level down. `XDG_DATA_HOME`
    /// relocates the tree (default `~/.local/share`). Today and yesterday,
    /// like Codex: a session spanning midnight keeps appending to the
    /// previous day's directory. Only `session.jsonl` counts. Sibling
    /// `cron.db`, tool-output spools, and `session-index.db` churn without
    /// the model working.
    static func museSessionWrite(
        home: String = NSHomeDirectory(),
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        let root: String
        if let override = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            root = "\(override)/muse/sessions"
        } else {
            root = "\(home)/.local/share/muse/sessions"
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.dateFormat = "yyyy/MM/dd"
        day.timeZone = .current
        return [now, now.addingTimeInterval(-86_400)]
            .compactMap { museSessionWrite(inDayDir: "\(root)/\(day.string(from: $0))") }
            .max()
    }

    /// Newest `session.jsonl` (main or subagent) under one `YYYY/MM/DD` dir.
    static func museSessionWrite(inDayDir path: String) -> Date? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return nil }
        var newest: Date?
        func consider(_ file: String) {
            guard let date = (try? manager.attributesOfItem(atPath: file))?[.modificationDate] as? Date
            else { return }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        for name in names {
            let sessionDir = (path as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: sessionDir, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            consider((sessionDir as NSString).appendingPathComponent("session.jsonl"))
            if let sub = newestNestedFileWrite(
                in: (sessionDir as NSString).appendingPathComponent("subagent"),
                named: "session.jsonl",
                directoryLevels: 1
            ) {
                if newest.map({ sub > $0 }) ?? true { newest = sub }
            }
        }
        return newest
    }

    /// DeepSeek Harness transcripts two directories down:
    /// `~/.dsh/sessions/<encoded-cwd>/session-<uuid>/session.jsonl.zstd`.
    /// `DSH_HOME` relocates the tree.
    static func dshSessionWrite(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        let root = environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { "\($0)/sessions" } ?? "\(home)/.dsh/sessions"
        return newestNestedFileWrite(in: root, named: "session.jsonl.zstd", directoryLevels: 2)
    }

    /// Walk `directoryLevels` of subdirectories under `root` and take the
    /// newest mtime of files named `named`. Does not recurse further, so
    /// caches sitting deeper cannot keep a session "working".
    static func newestNestedFileWrite(in root: String, named filename: String, directoryLevels: Int) -> Date? {
        let manager = FileManager.default
        var newest: Date?
        func walk(_ path: String, levelsLeft: Int) {
            guard let names = try? manager.contentsOfDirectory(atPath: path) else { return }
            if levelsLeft == 0 {
                let file = (path as NSString).appendingPathComponent(filename)
                guard let date = (try? manager.attributesOfItem(atPath: file))?[.modificationDate] as? Date
                else { return }
                if newest.map({ date > $0 }) ?? true { newest = date }
                return
            }
            for name in names {
                let child = (path as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: child, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                walk(child, levelsLeft: levelsLeft - 1)
            }
        }
        walk(root, levelsLeft: directoryLevels)
        return newest
    }

    /// Newest write to the Codex rollout file whose name carries `sessionId`
    /// (`rollout-<timestamp>-<sessionId>.jsonl` under `~/.codex/sessions/YYYY/MM/DD/`).
    /// Filename match only: we do not parse the JSONL. Today and yesterday are
    /// checked so a session spanning midnight still maps.
    static func codexRolloutWrite(
        forSessionId sessionId: String,
        home: String = NSHomeDirectory(),
        now: Date = Date()
    ) -> Date? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.dateFormat = "yyyy/MM/dd"
        day.timeZone = .current
        let manager = FileManager.default
        var newest: Date?
        for date in [now, now.addingTimeInterval(-86_400)] {
            let dir = "\(home)/.codex/sessions/\(day.string(from: date))"
            guard let names = try? manager.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.contains(trimmed) {
                guard let written = (try? manager.attributesOfItem(atPath: "\(dir)/\(name)"))?[.modificationDate] as? Date
                else { continue }
                if newest.map({ written > $0 }) ?? true { newest = written }
            }
        }
        return newest
    }

    /// Newest mtime among Bionic session-store files in `path`
    /// (`ng-sessions.sqlite`, `ng-sessions.sqlite-wal`, `ng-sessions.sqlite-shm`).
    static func newestSessionStoreWrite(in path: String) -> Date? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return nil }
        var newest: Date?
        for name in names {
            // Prefix match covers the main db and SQLite sidecars.
            guard name.hasPrefix("ng-sessions.sqlite") else { continue }
            guard let date = (try? manager.attributesOfItem(atPath: "\(path)/\(name)"))?[.modificationDate] as? Date
            else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

    /// Whether a `ps` command line is a Bionic agent host we should track.
    ///
    /// Matches:
    /// - the main `…/Contents/MacOS/Bionic` binary (stable; argv does not
    ///   carry a project id, and the renderer can keep a stale one after a
    ///   project switch)
    /// - a workspace Electron renderer that names a project
    ///   (`--lmstudio-project-identifier=`), under the Bionic app or its
    ///   user-data directory
    ///
    /// Rejects GPU/network helpers and other Electron children. When both
    /// main and a renderer match, ancestor folding keeps a single root.
    static func isBionicAgentHost(_ command: String) -> Bool {
        let inBionic = bionicHostPathHints.contains { command.contains($0) }
        guard inBionic else { return false }

        // Main app is `…/Contents/MacOS/Bionic` (no further name). Helpers are
        // `…/Contents/MacOS/Bionic Helper` and `…/Bionic Helper (Renderer)`, so
        // a naive "starts with Bionic" match would take them too.
        if let marker = command.range(of: "/Contents/MacOS/Bionic") {
            let after = command[marker.upperBound...]
            if after.isEmpty { return true }
            if after.first == " ", !after.dropFirst().hasPrefix("Helper") {
                return true
            }
        }

        // Workspace renderer with a project attachment.
        if command.contains("--type=renderer"),
           command.contains(bionicHostMarker) {
            return true
        }
        return false
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

    /// `$GROK_HOME`, or `~/.grok` when that is unset.
    static func grokHome(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let override = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return "\(home)/.grok"
    }

    /// Conversation jsonl files that stream during a turn. Parent-level
    /// `prompt_history.jsonl`, lock files, and `resources_state.json` are
    /// deliberately not in this list: the first is shared by every session
    /// in the project, and the others can move without the model working.
    static let grokEvidenceFiles = ["updates.jsonl", "chat_history.jsonl", "events.jsonl"]

    /// Newest write to the Grok conversation owned by `pid`, or `nil` when
    /// that pid is not in `active_sessions.json`. Never falls back to the
    /// project folder.
    static func grokTranscriptWrite(
        pid: Int32,
        cwd: String?,
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        let root = grokHome(home: home, environment: environment)
        let entries = grokActiveSessions(in: root).filter { $0.pid == pid }
        guard !entries.isEmpty else { return nil }
        let sessionsRoot = "\(root)/sessions"
        var newest: Date?
        for entry in entries {
            let groupCwd = entry.cwd ?? cwd
            guard let groupCwd else { continue }
            let group = grokSessionGroupDir(forCwd: groupCwd, under: sessionsRoot)
            let sessionDir = "\(group)/\(entry.sessionId)"
            for name in grokEvidenceFiles {
                let path = "\(sessionDir)/\(name)"
                guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                else { continue }
                if newest.map({ date > $0 }) ?? true { newest = date }
            }
        }
        return newest
    }

    /// One row of Grok's `active_sessions.json`. The live file uses
    /// snake_case. Both spellings are accepted.
    struct GrokActiveSession: Decodable, Equatable {
        var sessionId: String
        var pid: Int32
        var cwd: String?

        enum CodingKeys: String, CodingKey {
            case session_id, sessionId, pid, cwd
        }

        init(sessionId: String, pid: Int32, cwd: String?) {
            self.sessionId = sessionId
            self.pid = pid
            self.cwd = cwd
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decodeIfPresent(String.self, forKey: .session_id)
                ?? c.decodeIfPresent(String.self, forKey: .sessionId)
                ?? ""
            pid = try c.decode(Int32.self, forKey: .pid)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        }
    }

    /// Live Grok TUI index: `{session_id, pid, cwd}` at `$GROK_HOME/active_sessions.json`.
    /// Best-effort. A torn write is treated as no mapping. One unreadable
    /// row is skipped so a heartbeat-style extra object cannot drop every
    /// other session.
    static func grokActiveSessions(in grokHome: String) -> [GrokActiveSession] {
        let url = URL(fileURLWithPath: grokHome).appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { element in
            guard let piece = try? JSONSerialization.data(withJSONObject: element),
                  let entry = try? decoder.decode(GrokActiveSession.self, from: piece),
                  !entry.sessionId.isEmpty
            else { return nil }
            return entry
        }
    }

    /// Group directory for `cwd`. The encoded name is the common case. When
    /// that is missing, Grok may have used a slug-plus-hash name (encoded
    /// paths over 255 bytes) and left the original path in a `.cwd` file.
    static func grokSessionGroupDir(forCwd cwd: String, under sessionsRoot: String) -> String {
        let encoded = grokSessionDirName(forCwd: cwd)
        let direct = "\(sessionsRoot)/\(encoded)"
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: direct, isDirectory: &isDirectory), isDirectory.boolValue {
            return direct
        }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: sessionsRoot) else { return direct }
        for name in names {
            let group = "\(sessionsRoot)/\(name)"
            guard manager.fileExists(atPath: group, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let marker = "\(group)/.cwd"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: marker)),
                  let recorded = String(data: data, encoding: .utf8)
            else { continue }
            if recorded.trimmingCharacters(in: .whitespacesAndNewlines) == cwd {
                return group
            }
        }
        return direct
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
    static func sessions(
        from samples: [ProcessSample],
        agents: [String] = agentCommands,
        pathOf: (Int32) -> String? = AgentHooks.defaultPathOf
    ) -> [AgentSession] {
        var byPid: [Int32: ProcessSample] = [:]
        var children: [Int32: [Int32]] = [:]
        for sample in samples {
            byPid[sample.pid] = sample
            children[sample.ppid, default: []].append(sample.pid)
        }

        var matched: [Int32: String] = [:]
        // Hosts of an editor-embedded agent: matched like any other root, but
        // remembered so the CPU heuristic is skipped for them below.
        var evidenceOnly: Set<Int32> = []
        for sample in samples {
            if let agent = agentName(for: sample.command, agents: agents)
                ?? resolvedAgentName(for: sample, agents: agents, pathOf: pathOf) {
                // Muse's session-message daemon is a long-lived bus
                // (`muse-bin-* session-message serve`), not a coding
                // session. Evidence is date-keyed and shared, so leaving
                // it as a row would mark the helper working whenever any
                // Muse TUI is.
                if agent == "muse", isMuseSessionMessageCommand(sample.command) {
                    continue
                }
                matched[sample.pid] = agent
                if isEvidenceOnlyHost(agent: agent, command: sample.command) {
                    evidenceOnly.insert(sample.pid)
                }
            } else if sample.command.contains(antigravityHostMarker) {
                matched[sample.pid] = "antigravity"
                evidenceOnly.insert(sample.pid)
            } else if isBionicAgentHost(sample.command) {
                matched[sample.pid] = "bionic"
                evidenceOnly.insert(sample.pid)
            } else if sample.command.contains(dshHostMarker) {
                matched[sample.pid] = "dsh"
                if commandHasToken(sample.command, "web") {
                    evidenceOnly.insert(sample.pid)
                }
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
                return AgentSession(
                    pid: pid, agent: agent, tty: sample.tty,
                    // An editor host's subtree CPU is doubly meaningless: it
                    // sweeps in whatever the agent left running (a dev server
                    // started for a preview outlives the turn by hours).
                    cpuPercent: evidenceOnly.contains(pid) ? 0 : subtreeCPU(of: pid),
                    origin: evidenceOnly.contains(pid) ? .ide : nil,
                    evidenceOnly: evidenceOnly.contains(pid))
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
        if agents.contains("muse"), isMuseAgentBasename(candidate) { return "muse" }
        // An app-bundle binary's path can hold spaces anywhere before the
        // bundle ("~/Library/Application Support/Claude/claude-code/…"), which
        // the token split above mangles. The name after the last bundle marker
        // is unambiguous; agent names hold no spaces, so its first word is the
        // binary ("claude" for the Claude Code copy embedded in the desktop
        // app, "Claude" for the app itself, which case-sensitivity rejects).
        if let marker = command.range(of: "/Contents/MacOS/", options: .backwards) {
            let name = String(command[marker.upperBound...].prefix(while: { $0 != " " }))
            if let agent = agents.first(where: { $0 == name }) { return agent }
            if agents.contains("muse"), isMuseAgentBasename(name) { return "muse" }
            return nil
        }
        return nil
    }

    /// Muse Code's launcher is `muse`. The process that actually stays
    /// running is a versioned `muse-bin-<release>` (observed:
    /// `muse-bin-1.0.1-R2006.1`). Some detectors also name `muse-code` /
    /// `muse-cli`. Prefix-only on `muse-bin-` so `museum` and `muse-helper`
    /// never match.
    static func isMuseAgentBasename(_ name: String) -> Bool {
        switch name {
        case "muse", "muse-bin", "muse-code", "muse-cli": return true
        default: return name.hasPrefix("muse-bin-")
        }
    }

    /// Muse's cross-session message bus (`session-message serve`), not a
    /// coding session. The send/list CLI uses the same token and is equally
    /// not "the agent is working".
    static func isMuseSessionMessageCommand(_ command: String) -> Bool {
        commandHasToken(command, "session-message")
    }

    /// Second-chance match for a launcher whose command line names nothing.
    /// Cursor's CLI installs two symlinks, `cursor-agent` and a bare `agent`,
    /// and a session started through the short one runs as
    /// `~/.local/bin/agent --use-system-ca .../index.js`: the basename is the
    /// generic "agent", which is far too common a word to list as an agent
    /// command. The kernel's executable path resolves the symlink
    /// (`.../cursor-agent/versions/<v>/node`), so its path *components* name
    /// the tool, exactly as ``AgentHooks/agentMatch(comm:path:agents:)``
    /// already matches versioned binaries on the hook side.
    ///
    /// The `ps` line is a prefilter, never the verdict. Without it every scan
    /// would spend a `proc_pidpath` syscall on each of a few hundred
    /// processes; with it, a `grep cursor-agent …` still fails the
    /// authoritative path check, because its executable is `/usr/bin/grep`.
    static func resolvedAgentName(
        for sample: ProcessSample, agents: [String], pathOf: (Int32) -> String?
    ) -> String? {
        guard agents.contains(where: { sample.command.contains($0) }) else { return nil }
        return AgentHooks.agentMatch(comm: nil, path: pathOf(sample.pid), agents: agents)
    }

    private static func basename(_ token: Substring) -> String {
        String(token.split(separator: "/").last ?? token)
    }

    /// The real fetch: spawn `ps` and return its raw output. Prefer
    /// ``SharedPSSnapshot/runPS`` when sharing with process matching; this
    /// alias keeps existing call sites and tests compiling.
    @Sendable public static func runPS() -> String? {
        SharedPSSnapshot.runPS()
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

    /// True when this tick flipped from any-working to none-working. Cleared
    /// on the next tick that does not make the same edge, and consumed by
    /// ``consumeJustWentIdle()``.
    public private(set) var justWentIdle = false

    /// One-shot read of the working-to-idle edge: returns the latched flag
    /// and clears it. The host reads through this (not the raw property) so
    /// an edge observed while ticking stops (triggers paused right after the
    /// flip) can't re-fire the agent-idle hook every read until resume.
    public func consumeJustWentIdle() -> Bool {
        defer { justWentIdle = false }
        return justWentIdle
    }

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
                countWaitingAsWorking: countWaitingAsWorking,
                evidenceOnly: session.evidenceOnly
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
        countWaitingAsWorking: Bool = false,
        evidenceOnly: Bool = false
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
        } else if evidenceOnly {
            // No CPU branch at all: for an editor host it would fire on the
            // editor rather than on its agent (see ``AgentSession/evidenceOnly``).
            next.isWorking = freshEvidence
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
    /// Working sessions first so a truncated menu still shows the ones that
    /// matter; within each group the monitor's order is kept (stable sort).
    public var detailRows: [RuleDetail] {
        sessionStates
            .sorted { $0.isWorking && !$1.isWorking }
            .map {
                RuleDetail(
                    label: Self.rowLabel(for: $0), active: $0.isWorking,
                    animated: $0.isWorking, agent: $0.session.agent)
            }
    }

    /// "claude (s003) - run": the session label plus, when hooks report one,
    /// a short activity token that fits the brewing menu without truncating.
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

    /// Localizes a semantic detail token written by the hook CLI. On-disk
    /// tokens stay stable; menu copy is intentionally short so rows fit.
    static func detailText(forToken token: String) -> String? {
        switch token {
        case "running-command": return L("run")
        case "editing": return L("write")
        case "reading": return L("read")
        case "searching": return L("search")
        case "subagent": return L("subagent")
        case "browsing": return L("browse")
        case "waiting-approval": return L("permission")
        case "waiting": return L("wait")
        default:
            guard token.hasPrefix("tool:") else { return nil }
            return L("tool")
        }
    }
}
