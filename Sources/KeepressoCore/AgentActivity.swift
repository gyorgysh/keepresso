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
    var current: AgentSnapshot { get }
}

/// Same stale-while-revalidate shape as ``PSProcessLister``, and for the same
/// reason: ``current`` is read from the menu's `body` on the main thread and
/// must never block on `Process.waitUntilExit()`, so a stale snapshot is
/// returned immediately and a refresh runs on a detached task when it goes
/// stale.
public final class PSAgentActivityMonitor: AgentActivityMonitoring, @unchecked Sendable {
    /// The agent CLIs detected out of the box, matched against the root
    /// command's basename (never as a substring, so `grep claude` or a file
    /// name mentioning an agent can't count as a session), with the resolved
    /// executable path as a second chance (see ``resolvedAgentName(for:agents:pathOf:)``).
    /// CLI binaries only: a bare "cursor" or "antigravity" would match the
    /// whole IDE app, whose process tree burns CPU constantly, so their
    /// terminal agents are listed by their actual command names instead
    /// (cursor-agent, agy).
    public static let agentCommands = [
        "claude", "codex", "gemini", "grok", "agy", "aider", "goose", "omp",
        "cline",
        "cursor-agent", "opencode", "opencode2", "amp", "copilot", "droid",
        "auggie", "qwen", "kimi", "pi", "hermes", "kilo", "dsh", "muse", "devin",
    ]

    static let pathMatchMinimumLength = 4
    static let pathMatchExcludedAgents: Set<String> = ["kilo", "muse", "devin"]
    public static let pathMatchableAgents = agentCommands.filter {
        $0.count >= pathMatchMinimumLength && !pathMatchExcludedAgents.contains($0)
    }

    static let runtimeWrappers: Set<String> = ["node", "bun", "deno", "python", "python3"]

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

    static let evidenceWindowOverrides: [String: TimeInterval] = [
        "antigravity": 20,
        "agy": 20,
        "bionic": 45,
        "opencode": 20,
        "opencode2": 20,
        "kilo": 20,
        "hermes": 20,
        "devin": 20,
        "kimi": 45,
    ]

    static func evidenceWindow(for agent: String) -> TimeInterval {
        evidenceWindowOverrides[agent] ?? evidenceFreshWindow
    }

    static let antigravityHostMarker = "--override_ide_name antigravity"

    static let bionicHostMarker = "--lmstudio-project-identifier="
    static let bionicHostPathHints = ["Bionic.app/", "/Application Support/Bionic"]
    static let dshHostMarker = "@deepseek-ai/dsh"

    private let ttl: TimeInterval
    private let now: () -> Date
    private let fetch: @Sendable () -> String?
    private let evidence: @Sendable (_ agent: String, _ cwd: String?, _ pid: Int32) -> Date?
    private let hookRecords: @Sendable (_ now: Date) -> [AgentHooks.HookRecord]
    private let classifyOrigin: @Sendable (_ pid: Int32) -> AgentHooks.HookSessionOrigin?
    private let lock = NSLock()
    private var cached: AgentSnapshot = .empty
    private var lastFetch: Date?
    private var isRefreshing = false
    /// When false, a refresh only parses `ps` into sessions and skips
    /// transcript walks, hook-record reads, cwd lookups, and origin
    /// classification. The trigger factory turns this off when no agent rule
    /// is live; tests leave it on. Lock-backed: a refresh reads it from a
    /// detached task while the trigger factory writes it.
    public var evidenceEnabled: Bool {
        get { withLock { evidenceEnabledStorage } }
        set { withLock { evidenceEnabledStorage = newValue } }
    }
    private var evidenceEnabledStorage = true

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
        evidence: @escaping @Sendable (_ agent: String, _ cwd: String?, _ pid: Int32) -> Date? = {
            PSAgentActivityMonitor.transcriptActivity(agent: $0, cwd: $1, pid: $2)
        },
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
                guard let raw = self.fetch() else {
                    self.withLock {
                        self.lastFetch = self.now()
                        self.isRefreshing = false
                    }
                    return
                }
                var sessions = Self.sessions(from: Self.parse(raw))
                let collectEvidence = self.withLock { self.evidenceEnabledStorage }
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
                let cutoff = scanTime.addingTimeInterval(
                    -Self.evidenceWindow(for: session.agent))
                sessions[index].hasFreshEvidence = written >= cutoff
            }
            if let classified = classifyOrigin(session.pid) {
                sessions[index].origin = classified
            }
        }
        let hookRecords = hookRecords(scanTime)
        let join = Self.applyHookRecords(
            hookRecords, to: sessions, cwdOf: { cwds[$0] })
        sessions = join.sessions
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
        sessions = Self.suppressingHookCoveredEvidenceHosts(
            sessions, hookRecords: hookRecords)
        sessions.append(contentsOf: HermesHooks.withoutCoveredPresence(join.unclaimed).compactMap { record in
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

    static func suppressingHookCoveredEvidenceHosts(
        _ sessions: [AgentSession],
        hookRecords: [AgentHooks.HookRecord]
    ) -> [AgentSession] {
        let hosts = Set(hookRecords.compactMap(\.ownerPid))
        guard !hosts.isEmpty else { return sessions }
        let hermesHosts = Set(hookRecords.filter(HermesHooks.ownsRecord).compactMap(\.ownerPid))
        return sessions.filter {
            !($0.evidenceOnly && hosts.contains($0.pid))
                && !($0.agent == "hermes" && hermesHosts.contains($0.pid))
        }
    }

    struct HookJoin: Equatable {
        var sessions: [AgentSession]
        var unclaimed: [AgentHooks.HookRecord]
    }

    static func hookOnlySession(from record: AgentHooks.HookRecord) -> AgentSession? {
        guard record.ownerPid != nil else { return nil }
        var session = AgentSession(
            pid: syntheticPid(forSessionId: record.sessionId),
            agent: record.agent ?? "agent",
            tty: nil,
            cpuPercent: 0,
            hookState: record.state,
            hookDetail: record.detail,
            origin: record.origin
        )
        session.hookUpdatedAt = record.updatedAt
        return session
    }

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
        if let origin = record.origin { session.origin = origin }
    }

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
    @Sendable public static func transcriptActivity(
        agent: String,
        cwd: String?,
        pid: Int32,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        let home = NSHomeDirectory()
        switch agent {
        case "claude":
            guard let cwd else { return nil }
            return claudeTranscriptWrite(inProjectDir: "\(home)/.claude/projects/\(claudeProjectDirName(forCwd: cwd))")
        case "grok":
            return grokTranscriptWrite(pid: pid, cwd: cwd, home: home)
        case "codex":
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.calendar = Calendar(identifier: .gregorian)
            day.dateFormat = "yyyy/MM/dd"
            day.timeZone = .current
            let today = Date()
            let sessions = CodexHooks.dataRootURL(home: home, environment: environment)
                .appendingPathComponent("sessions", isDirectory: true).path
            return [today, today.addingTimeInterval(-86_400)]
                .compactMap { newestModification(in: "\(sessions)/\(day.string(from: $0))") }
                .max()
        case "qwen":
            guard let cwd else { return nil }
            let project = claudeProjectDirName(forCwd: cwd)
            return qwenTranscriptWrite(
                inChatsDir: "\(home)/.qwen/projects/\(project)/chats")
        case "kimi":
            guard let cwd else { return nil }
            let installedHome = AgentHooks.defaultPathOf(pid)
                .flatMap(kimiCodeHome(forExecutablePath:))
            return kimiSessionWrite(cwd: cwd, home: home, root: installedHome)
        case "antigravity", "agy":
            let root = agent == "agy" ? "antigravity-cli" : "antigravity"
            return newestModification(in: "\(home)/.gemini/\(root)/conversations")
        case "bionic":
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
        case "devin":
            return devinStoreWrite(home: home)
        default:
            return nil
        }
    }

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

    static func isEvidenceOnlyHost(agent: String, command: String) -> Bool {
        switch agent {
        case "codex": return isCodexAppServerCommand(command)
        case "kilo": return commandHasToken(command, "serve")
        case "dsh": return commandHasToken(command, "web")
        case "devin": return commandHasToken(command, "acp")
        default: return false
        }
    }

    static func commandHasToken(_ command: String, _ token: String) -> Bool {
        command.split(whereSeparator: \.isWhitespace).contains { $0 == token }
    }

    static func isCodexAppServerCommand(_ command: String) -> Bool {
        agentName(for: command, agents: ["codex"]) == "codex"
            && commandHasToken(command, "app-server")
    }

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

    static func hermesStoreWrite(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        let root = HermesHooks.hermesHome(home: home, environment: environment)
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

    static func devinStoreWrite(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        let root: String
        if let override = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            root = "\(override)/devin/cli"
        } else {
            root = "\(home)/.local/share/devin/cli"
        }
        let sqlite = newestSqliteStoreWrite(in: root, basename: "sessions.db")
        let transcripts = newestJSONWrite(in: "\(root)/transcripts")
        return [sqlite, transcripts].compactMap { $0 }.max()
    }

    static func newestJSONWrite(in directory: String) -> Date? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return nil }
        var newest: Date?
        for name in names where name.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

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

    static func dshSessionWrite(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        let root = environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { "\($0)/sessions" } ?? "\(home)/.dsh/sessions"
        return newestNestedFileWrite(in: root, named: "session.jsonl.zstd", directoryLevels: 2)
    }

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

    static func codexRolloutWrite(
        forSessionId sessionId: String,
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
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
        let sessions = CodexHooks.dataRootURL(home: home, environment: environment)
            .appendingPathComponent("sessions", isDirectory: true).path
        var newest: Date?
        for date in [now, now.addingTimeInterval(-86_400)] {
            let dir = "\(sessions)/\(day.string(from: date))"
            guard let names = try? manager.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.contains(trimmed) {
                guard let written = (try? manager.attributesOfItem(atPath: "\(dir)/\(name)"))?[.modificationDate] as? Date
                else { continue }
                if newest.map({ written > $0 }) ?? true { newest = written }
            }
        }
        return newest
    }

    static func newestSessionStoreWrite(in path: String) -> Date? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return nil }
        var newest: Date?
        for name in names {
            guard name.hasPrefix("ng-sessions.sqlite") else { continue }
            guard let date = (try? manager.attributesOfItem(atPath: "\(path)/\(name)"))?[.modificationDate] as? Date
            else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

    static func isBionicAgentHost(_ command: String) -> Bool {
        let inBionic = bionicHostPathHints.contains { command.contains($0) }
        guard inBionic else { return false }

        if let marker = command.range(of: "/Contents/MacOS/Bionic") {
            let after = command[marker.upperBound...]
            if after.isEmpty { return true }
            if after.first == " ", !after.dropFirst().hasPrefix("Helper") {
                return true
            }
        }

        if command.contains("--type=renderer"),
           command.contains(bionicHostMarker) {
            return true
        }
        return false
    }

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

    static func claudeProjectDirName(forCwd cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func qwenTranscriptWrite(inChatsDir path: String) -> Date? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return nil }
        var newest: Date?
        for name in names where name.hasSuffix(".jsonl") {
            let file = (path as NSString).appendingPathComponent(name)
            guard let date = (try? manager.attributesOfItem(atPath: file))?[.modificationDate] as? Date
            else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

    static func kimiCodeHome(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let override = environment["KIMI_CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return "\(home)/.kimi-code"
    }

    static func kimiCodeHome(forExecutablePath path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == "kimi",
              url.deletingLastPathComponent().lastPathComponent == "bin"
        else { return nil }
        let root = url.deletingLastPathComponent().deletingLastPathComponent().path
        guard root != "/usr", root != "/usr/local", root != "/opt/homebrew" else {
            return nil
        }
        return root
    }

    static func kimiSessionWrite(
        cwd: String,
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        root: String? = nil
    ) -> Date? {
        let dataRoot = root ?? kimiCodeHome(home: home, environment: environment)
        let sessions = "\(dataRoot)/sessions"
        let manager = FileManager.default
        guard let workspaces = try? manager.contentsOfDirectory(atPath: sessions) else { return nil }
        var newest: Date?
        for workspace in workspaces {
            let workspacePath = "\(sessions)/\(workspace)"
            guard let sessionNames = try? manager.contentsOfDirectory(atPath: workspacePath) else {
                continue
            }
            for session in sessionNames where session.hasPrefix("session_") {
                let sessionPath = "\(workspacePath)/\(session)"
                let statePath = "\(sessionPath)/state.json"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["cwd"] as? String == cwd
                else { continue }
                for path in [statePath, "\(sessionPath)/logs/kimi-code.log"] {
                    guard let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate]
                            as? Date
                    else { continue }
                    if newest.map({ date > $0 }) ?? true { newest = date }
                }
            }
        }
        return newest
    }

    /// Grok's per-project session folder name: the working directory
    /// percent-encoded with only RFC 3986 unreserved characters kept
    /// (`/Users/x/git/demo` becomes `%2FUsers%2Fx%2Fgit%2Fdemo`).
    static func grokSessionDirName(forCwd cwd: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: unreserved) ?? cwd
    }

    static func grokHome(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let override = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return "\(home)/.grok"
    }

    static let grokEvidenceFiles = ["updates.jsonl", "chat_history.jsonl", "events.jsonl"]

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
        var evidenceOnly: Set<Int32> = []
        for sample in samples {
            if let agent = agentName(for: sample.command, agents: agents)
                ?? resolvedAgentName(for: sample, agents: agents, pathOf: pathOf) {
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
                    cpuPercent: evidenceOnly.contains(pid) ? 0 : subtreeCPU(of: pid),
                    origin: evidenceOnly.contains(pid) ? .ide : nil,
                    evidenceOnly: evidenceOnly.contains(pid))
            }
    }

    static func agentName(for command: String, agents: [String]) -> String? {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first else { return nil }
        var candidate = basename(first)
        if runtimeWrappers.contains(candidate.lowercased()) {
            guard let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
            candidate = basename(script)
        }
        if let agent = agents.first(where: { $0 == candidate }) { return agent }
        if agents.contains("qwen"), isQwenCodeCommand(command) { return "qwen" }
        if agents.contains("muse"), isMuseAgentBasename(candidate) { return "muse" }
        if agents.contains("devin"), isDevinAgentBasename(candidate) { return "devin" }
        if let marker = command.range(of: "/Contents/MacOS/", options: .backwards) {
            let name = String(command[marker.upperBound...].prefix(while: { $0 != " " }))
            if let agent = agents.first(where: { $0 == name }) { return agent }
            if agents.contains("muse"), isMuseAgentBasename(name) { return "muse" }
            if agents.contains("devin"), isDevinAgentBasename(name) { return "devin" }
            return nil
        }
        return nil
    }

    static func isQwenCodeCommand(_ command: String) -> Bool {
        let tokens = command.split(whereSeparator: \.isWhitespace)
        guard let executable = tokens.first,
              basename(executable).lowercased() == "node",
              executable.split(separator: "/").contains("qwen-code"),
              let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }),
              script.split(separator: "/").contains("qwen-code")
        else { return false }
        return basename(script) == "cli.js" || basename(script) == "cli-entry.js"
    }

    static func isMuseAgentBasename(_ name: String) -> Bool {
        switch name {
        case "muse", "muse-bin", "muse-code", "muse-cli": return true
        default: return name.hasPrefix("muse-bin-")
        }
    }

    static func isMuseSessionMessageCommand(_ command: String) -> Bool {
        commandHasToken(command, "session-message")
    }

    static func isDevinAgentBasename(_ name: String) -> Bool {
        name == "devin" || name == "devin-cli"
    }

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
    static let baselineCreepPerTick = 0.05
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
