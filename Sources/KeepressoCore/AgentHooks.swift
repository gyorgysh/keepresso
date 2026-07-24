import Foundation

/// Exact session-state tracking for agent CLIs that support lifecycle hooks
/// (Claude Code today). The installed hook command pipes each event's JSON
/// payload into `keepresso agent-hook <event>`, which reduces it to a small
/// per-session state file under
/// `~/Library/Application Support/Keepresso/agent-hooks/`; the agent-activity
/// monitor reads those files as evidence that beats the CPU heuristic.
///
/// Everything here is pure logic over injected closures so it tests without
/// syscalls; the file IO mirrors ``StatusFile`` (atomic, best-effort, errors
/// swallowed: a broken hook must never disturb an agent session).
public enum AgentHooks {

    // MARK: - Payload

    /// The hook payload Claude Code delivers on stdin. Tolerant by design:
    /// every field optional, unknown fields ignored, because the payload
    /// grows fields over time.
    public struct HookPayload: Decodable, Equatable, Sendable {
        public var sessionId: String?
        public var cwd: String?
        public var hookEventName: String?
        public var toolName: String?
        public var message: String?
        public var transcriptPath: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd
            case hookEventName = "hook_event_name"
            case toolName = "tool_name"
            case message
            case transcriptPath = "transcript_path"
        }

        public init(
            sessionId: String? = nil,
            cwd: String? = nil,
            hookEventName: String? = nil,
            toolName: String? = nil,
            message: String? = nil,
            transcriptPath: String? = nil
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.hookEventName = hookEventName
            self.toolName = toolName
            self.message = message
            self.transcriptPath = transcriptPath
        }
    }

    // MARK: - Event reduction

    /// What a hook event says the session is doing right now.
    public enum HookSessionState: String, Codable, Sendable {
        case working
        case waiting
        case idle
    }

    /// Where a session runs, classified from the process ancestry above the
    /// agent (the payload carries no such field).
    public enum HookSessionOrigin: String, Codable, Sendable {
        case terminal
        case claudeApp = "claude-app"
        case ide
    }

    /// The effect of one hook event on the session's state file.
    public enum HookEventEffect: Equatable, Sendable {
        /// Write the state, with an optional semantic detail token.
        case set(HookSessionState, detail: String?)
        /// The session is over: delete the state file.
        case end
    }

    /// Maps a hook event (and the tool it concerns, for PreToolUse) to its
    /// effect. Unknown events return `nil`: write nothing, exit 0, so a new
    /// Claude Code event name can never break anything. Details are semantic
    /// tokens, not English text; the app localizes them at render time.
    public static func reduce(event: String, toolName: String?, message: String? = nil) -> HookEventEffect? {
        switch event {
        case "SessionStart":
            // A session that just started (or resumed) is waiting for its
            // first prompt, not working. A never-prompted REPL emits no
            // further events (no Stop, and the idle nudge only fires after
            // message activity), so a `working` record here would hold the
            // trigger for as long as the process lives. `idle` still writes
            // the record, so the pid join and origin land immediately.
            return .set(.idle, detail: nil)
        case "UserPromptSubmit", "PostToolUse":
            return .set(.working, detail: nil)
        case "PreToolUse":
            return .set(.working, detail: toolName.flatMap(detailToken(forTool:)))
        case "PermissionRequest":
            return .set(.waiting, detail: "waiting-approval")
        case "Notification":
            // A permission prompt fires PermissionRequest and a Notification
            // in no guaranteed order, and the record keeps only the last
            // event, so classify by the message to avoid overwriting the
            // approval marker. Any other notification is the idle nudge
            // ("waiting for your input"): a session at rest.
            let approval = message?.range(of: "permission", options: .caseInsensitive) != nil
            return .set(.waiting, detail: approval ? "waiting-approval" : nil)
        case "Stop":
            return .set(.idle, detail: nil)
        case "SessionEnd":
            return .end
        default:
            return nil
        }
    }

    /// The semantic token shown while a tool runs. `tool:<name>` is the
    /// catch-all the app renders as "using <name>".
    static func detailToken(forTool tool: String) -> String? {
        switch tool {
        case "Bash": return "running-command"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "editing"
        case "Read": return "reading"
        case "Grep", "Glob": return "searching"
        case "Task", "Agent": return "subagent"
        case "WebFetch", "WebSearch": return "browsing"
        default:
            let trimmed = tool.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : "tool:\(trimmed)"
        }
    }

    // MARK: - State record

    /// One session's on-disk state, `<sessionId>.json` in the hooks folder.
    public struct HookRecord: Codable, Equatable, Sendable {
        public var sessionId: String
        public var state: HookSessionState
        /// Semantic detail token (`running-command`, `waiting-approval`, ...).
        public var detail: String?
        public var cwd: String?
        public var origin: HookSessionOrigin?
        /// The agent root process (found by the ancestor walk), the exact
        /// join key to the monitor's sessions; `cwd` is the fallback.
        public var agentPid: Int32?
        public var updatedAt: Date

        public init(
            sessionId: String,
            state: HookSessionState,
            detail: String? = nil,
            cwd: String? = nil,
            origin: HookSessionOrigin? = nil,
            agentPid: Int32? = nil,
            updatedAt: Date
        ) {
            self.sessionId = sessionId
            self.state = state
            self.detail = detail
            self.cwd = cwd
            self.origin = origin
            self.agentPid = agentPid
            self.updatedAt = updatedAt
        }
    }

    // MARK: - Ancestor walk

    /// The agent process found above the hook process, with the origin
    /// classified from the ancestry above the agent itself.
    public struct AncestorMatch: Equatable, Sendable {
        public var agentPid: Int32
        public var agentCommand: String
        public var origin: HookSessionOrigin?

        public init(agentPid: Int32, agentCommand: String, origin: HookSessionOrigin? = nil) {
            self.agentPid = agentPid
            self.agentCommand = agentCommand
            self.origin = origin
        }
    }

    /// Walks up the process tree from `pid` until a process matches an agent
    /// name, then keeps walking to classify where that agent runs. Joining on
    /// the agent pid (instead of cwd) keeps two sessions in one directory
    /// apart. `commandOf` yields the short BSD comm (truncated to 16 chars;
    /// every ``PSAgentActivityMonitor/agentCommands`` name fits); `pathOf`
    /// yields the executable path, matched by its components, because some
    /// installers run a versioned binary whose comm says nothing (Claude
    /// Code's native install executes `~/.local/share/claude/versions/N.N.N`,
    /// so its comm is the bare version number). Pure over the injected
    /// closures; the depth cap and visited set bound races on reused pids.
    public static func findAgentAncestor(
        startingAt pid: Int32,
        agents: [String] = PSAgentActivityMonitor.agentCommands,
        depthLimit: Int = 20,
        parentOf: (Int32) -> Int32? = defaultParentOf,
        commandOf: (Int32) -> String? = defaultCommandOf,
        pathOf: (Int32) -> String? = defaultPathOf
    ) -> AncestorMatch? {
        var visited: Set<Int32> = []
        var current = pid
        var depth = 0
        while current > 1, depth < depthLimit, visited.insert(current).inserted {
            if let agent = agentMatch(
                comm: commandOf(current), path: pathOf(current), agents: agents) {
                return AncestorMatch(
                    agentPid: current,
                    agentCommand: agent,
                    origin: classifyOrigin(
                        above: current,
                        depthLimit: depthLimit - depth,
                        visited: &visited,
                        parentOf: parentOf,
                        commandOf: commandOf
                    )
                )
            }
            guard let parent = parentOf(current) else { return nil }
            current = parent
            depth += 1
        }
        return nil
    }

    /// Classifies where the process `pid` runs from its ancestry alone, for
    /// sessions detected by the `ps` scan before any hook record exists.
    public static func classifyOrigin(
        abovePid pid: Int32,
        depthLimit: Int = 20,
        parentOf: (Int32) -> Int32? = defaultParentOf,
        commandOf: (Int32) -> String? = defaultCommandOf
    ) -> HookSessionOrigin? {
        var visited: Set<Int32> = [pid]
        return classifyOrigin(
            above: pid, depthLimit: depthLimit, visited: &visited,
            parentOf: parentOf, commandOf: commandOf)
    }

    /// The first recognizable host above the agent process: a shell or
    /// terminal means a plain CLI session; a Claude-branded ancestor means
    /// the Claude desktop app; an editor helper means an IDE. Unrecognized
    /// ancestors are skipped, an exhausted walk returns `nil`.
    private static func classifyOrigin(
        above agentPid: Int32,
        depthLimit: Int,
        visited: inout Set<Int32>,
        parentOf: (Int32) -> Int32?,
        commandOf: (Int32) -> String?
    ) -> HookSessionOrigin? {
        var current = agentPid
        var depth = 0
        while depth < depthLimit, let parent = parentOf(current), parent > 1,
              visited.insert(parent).inserted {
            if let comm = commandOf(parent), let origin = origin(forComm: comm) {
                return origin
            }
            current = parent
            depth += 1
        }
        return nil
    }

    /// Matches one process against the agent names: by its short comm, or by
    /// any component of its executable path (exact and case-sensitive, like
    /// ``PSAgentActivityMonitor/agentName(for:agents:)``: the Claude desktop
    /// app's Electron binary is `Claude`, the CLI is `claude`; a versioned
    /// binary under `.../claude/versions/` matches through the directory name).
    static func agentMatch(comm: String?, path: String?, agents: [String]) -> String? {
        if let comm, let agent = agents.first(where: { $0 == comm }) {
            return agent
        }
        guard let path else { return nil }
        for component in path.split(separator: "/") {
            if let agent = agents.first(where: { $0 == component }) {
                return agent
            }
        }
        return nil
    }

    /// Classification of one short BSD command name. Terminal apps are listed
    /// alongside shells because a shell-less spawn (tmux server, `exec`) can
    /// put the emulator itself next in the chain.
    static func origin(forComm comm: String) -> HookSessionOrigin? {
        let lower = comm.lowercased()
        let shells: Set<String> = [
            "zsh", "bash", "fish", "sh", "dash", "nu", "tcsh", "csh", "ksh",
            "login", "tmux", "screen",
        ]
        if shells.contains(lower) { return .terminal }
        let terminalApps = ["terminal", "iterm", "kitty", "alacritty", "wezterm", "ghostty", "warp", "hyper"]
        if terminalApps.contains(where: { lower.hasPrefix($0) }) { return .terminal }
        // Electron comms truncate to 16 chars: "Claude Helper (R", etc.
        if comm.hasPrefix("Claude") { return .claudeApp }
        if comm.hasPrefix("Code Helper") || comm.hasPrefix("Code - ")
            || comm.hasPrefix("Cursor Helper") || comm.hasPrefix("Electron") { return .ide }
        return nil
    }

    /// Real parent lookup via `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)`.
    public static func defaultParentOf(_ pid: Int32) -> Int32? {
        shortBSDInfo(pid).map { Int32(bitPattern: $0.pbsi_ppid) }
    }

    /// Real short-command lookup (`pbsi_comm`, truncated to 16 chars).
    public static func defaultCommandOf(_ pid: Int32) -> String? {
        shortBSDInfo(pid).map { info in
            withUnsafeBytes(of: info.pbsi_comm) { raw in
                raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? ""
            }
        }
    }

    private static func shortBSDInfo(_ pid: Int32) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Real executable-path lookup via `proc_pidpath`.
    public static func defaultPathOf(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro itself doesn't
        // import into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - State files

    /// `~/Library/Application Support/Keepresso/agent-hooks/`, next to
    /// ``StatusFile/defaultURL(fileManager:)``.
    public static func directoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keepresso", isDirectory: true)
            .appendingPathComponent("agent-hooks", isDirectory: true)
    }

    /// The record's file name. Session ids are UUIDs in practice, but the id
    /// comes from an outside payload, so anything path-hostile is flattened.
    static func fileName(forSessionId sessionId: String) -> String {
        let safe = String(sessionId.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return "\(safe.isEmpty ? "session" : safe).json"
    }

    /// Atomic best-effort write, creating the folder on first use; errors
    /// swallowed like ``StatusFile/write(_:to:)``.
    public static func write(_ record: HookRecord, in directory: URL = directoryURL()) {
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(fileName(forSessionId: record.sessionId)), options: .atomic)
    }

    public static func delete(sessionId: String, in directory: URL = directoryURL()) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(fileName(forSessionId: sessionId)))
    }

    /// Removes every session record, for when the user uninstalls the hooks:
    /// with nothing left to emit Stop or SessionEnd, a retained working
    /// record would otherwise hold the trigger for as long as its agent
    /// runs. ``write(_:in:)`` recreates the folder on the next install.
    public static func purgeRecords(in directory: URL = directoryURL()) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Applies one hook invocation end to end: decode the stdin payload,
    /// reduce the event, resolve the agent ancestor, write or delete the
    /// state file. Never throws, never prints; the caller exits 0 regardless.
    public static func handle(
        event: String,
        payloadData: Data,
        parentPid: Int32,
        now: Date = Date(),
        in directory: URL = directoryURL(),
        parentOf: (Int32) -> Int32? = defaultParentOf,
        commandOf: (Int32) -> String? = defaultCommandOf,
        pathOf: (Int32) -> String? = defaultPathOf
    ) {
        let payload = (try? decoder.decode(HookPayload.self, from: payloadData)) ?? HookPayload()
        guard let sessionId = payload.sessionId, !sessionId.isEmpty else { return }
        switch reduce(event: event, toolName: payload.toolName, message: payload.message) {
        case .end:
            delete(sessionId: sessionId, in: directory)
        case .set(let state, let detail):
            let match = findAgentAncestor(
                startingAt: parentPid, parentOf: parentOf, commandOf: commandOf, pathOf: pathOf)
            write(
                HookRecord(
                    sessionId: sessionId,
                    state: state,
                    detail: detail,
                    cwd: payload.cwd,
                    origin: match?.origin,
                    agentPid: match?.agentPid,
                    updatedAt: now
                ),
                in: directory
            )
        case nil:
            break
        }
    }

    // MARK: - Reading (monitor side)

    /// A record older than this is no longer trusted as live state: the
    /// session silently falls back to transcript + CPU evidence. Age only
    /// governs records whose silence means nothing (`idle`, a plain
    /// `waiting` nudge) and records whose agent can't be liveness-checked;
    /// `working` and `waiting-approval` records with a live agent never
    /// expire by age (see ``readHookRecords(now:in:isAlive:)``).
    public static let staleAfter: TimeInterval = 120

    /// All usable records in the hooks folder. Hook state is edge-triggered,
    /// so a stale `working` or `waiting-approval` record with a live agent
    /// stays authoritative: a long model turn emits no events for minutes
    /// (zero CPU, no transcript writes) and an approval prompt emits none
    /// however long it sits. Stale `idle`/`waiting` records with a live
    /// agent are skipped but kept, letting the transcript + CPU fallbacks
    /// decide. Stale records whose agent is gone, including a pid reused by
    /// some non-agent process, are deleted during the scan (SessionEnd never
    /// fired, e.g. a killed terminal).
    public static func readHookRecords(
        now: Date,
        in directory: URL = directoryURL(),
        isAlive: (Int32) -> Bool = defaultIsAgentAlive
    ) -> [HookRecord] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var records: [HookRecord] = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(HookRecord.self, from: data) else { continue }
            if now.timeIntervalSince(record.updatedAt) < staleAfter {
                // Fresh, but a record carrying a pid must still have a live one:
                // a SIGKILL'd agent leaves a sub-staleAfter "working" record, and
                // a pid reused by another detected session would otherwise be
                // stamped working from it. A record with no pid (nothing to
                // verify) is trusted as before.
                if record.agentPid.map(isAlive) ?? true {
                    records.append(record)
                }
            } else if record.agentPid.map(isAlive) == true,
                      record.state == .working
                          || (record.state == .waiting && record.detail == "waiting-approval") {
                // Trust the edge for as long as the agent process is alive:
                // Stop, Notification, SessionEnd, or the pid dying is what
                // ends a working turn or a sitting approval prompt, never
                // the record's age.
                records.append(record)
            } else if record.agentPid.map({ !isAlive($0) }) ?? true {
                try? manager.removeItem(at: url)
            }
        }
        return records
    }

    /// Liveness probe: EPERM still means "exists".
    public static func defaultIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The record-trust probe: the pid must exist *and* still be an agent
    /// process. Bare existence isn't enough, because an orphaned
    /// `working` record (its terminal killed, SessionEnd never fired) whose
    /// pid gets reused by any long-lived process would otherwise be trusted
    /// forever, and could even stamp a different agent session as working.
    public static func defaultIsAgentAlive(_ pid: Int32) -> Bool {
        guard defaultIsAlive(pid) else { return false }
        return agentMatch(
            comm: defaultCommandOf(pid), path: defaultPathOf(pid),
            agents: PSAgentActivityMonitor.agentCommands) != nil
    }

    // MARK: - settings.json install/remove

    /// Ownership marker inside every installed hook command, what
    /// ``removeHooks(from:)`` keys on. Never change it: released versions
    /// must keep recognizing each other's entries.
    public static let hookMarker = "__keepresso_hook"

    /// The events we install hooks for: exactly the set ``reduce(event:toolName:)``
    /// maps, nothing speculative.
    public static let installedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Notification", "Stop", "SessionEnd",
    ]

    /// Events whose settings entries take a tool `matcher`; the others reject
    /// or ignore one.
    static let matcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// `~/.claude/settings.json`, Claude Code's user-level settings.
    public static func claudeSettingsURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// The shell command an installed hook runs. Hooks execute under a
    /// non-interactive `sh -c` whose PATH can be launchd-minimal, so the
    /// app's real CLI path is baked in first and the canonical /Applications
    /// path is the fallback. Both are absolute: a bare `command -v keepresso`
    /// PATH lookup is deliberately avoided so a stale hook left behind after
    /// the app is deleted can't be hijacked by an unrelated `keepresso` on
    /// PATH. The trailing `:` pins exit 0: a missing CLI must never disturb
    /// the session.
    static func hookCommand(event: String, cliPath: String) -> String {
        "c=\(shellSingleQuoted(cliPath)); [ -x \"$c\" ] || "
            + "c=/Applications/Keepresso.app/Contents/Helpers/keepresso; "
            + "\"$c\" agent-hook \(event); : # \(hookMarker)"
    }

    /// POSIX single-quoting: everything inside is literal, an embedded single
    /// quote becomes `'\''`. The baked path is user-controlled (the app can be
    /// installed anywhere), and a quote or backtick in it would be an `sh -c`
    /// syntax error, which exits 2 before the trailing `:` can pin exit 0 and
    /// which Claude Code treats as a blocking hook failure on every tool call.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Where a `keepresso agent-hook` install stands in a settings file.
    public enum HookInstallState: Equatable, Sendable {
        case installed
        case notInstalled
        /// The file exists but isn't JSON we can safely edit.
        case unreadable
    }

    /// Thrown when settings.json can't be edited without risking damage.
    public struct SettingsUnreadableError: Error, Equatable, Sendable {
        public init() {}
    }

    /// Reads a settings file, distinguishing "no file yet" (`nil`, safe to
    /// start from an empty object) from "exists but can't be read" (thrown).
    /// Conflating the two would let a permission or IO error make an install
    /// treat a full settings.json as absent and atomically replace it with a
    /// hooks-only object, destroying the user's Claude Code configuration.
    public static func readSettings(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw SettingsUnreadableError()
        }
    }

    /// Merges one Keepresso entry per mapped event into the `hooks` key,
    /// preserving every foreign key and other tools' hook entries verbatim
    /// (`JSONSerialization`, not Codable, exactly so nothing unknown is
    /// dropped). Existing Keepresso entries are replaced, making a
    /// re-install idempotent and self-healing for a stale baked path.
    /// `nil` input (no settings.json yet) starts from an empty object.
    public static func installHooks(into data: Data?, cliPath: String) throws -> Data {
        var root = try parseRoot(data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in installedEvents {
            var groups = (hooks[event] as? [[String: Any]]).map(stripKeepressoEntries) ?? []
            var entry: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": hookCommand(event: event, cliPath: cliPath),
                        // Our CLI answers in milliseconds; a tight timeout
                        // means even a wedged disk can't stall a session.
                        "timeout": 5,
                    ] as [String: Any],
                ],
            ]
            if matcherEvents.contains(event) { entry["matcher"] = "*" }
            groups.append(entry)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Removes exactly the entries carrying ``hookMarker``, pruning emptied
    /// arrays and objects; everything else is left untouched.
    public static func removeHooks(from data: Data?) throws -> Data {
        var root = try parseRoot(data)
        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let kept = stripKeepressoEntries(groups)
                if kept.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = kept
                }
            }
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
        }
        return try serialize(root)
    }

    public static func hookInstallState(of data: Data?) -> HookInstallState {
        guard let data, !data.isEmpty else { return .notInstalled }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return .unreadable }
        guard let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            if groups.contains(where: { !keepressoCommands(in: $0).isEmpty }) {
                return .installed
            }
        }
        return .notInstalled
    }

    /// Drops our own commands from each matcher group (and groups that end
    /// up empty), leaving foreign hooks in shared groups alone.
    private static func stripKeepressoEntries(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return group }
            let foreign = inner.filter { entry in
                !((entry["command"] as? String)?.contains(hookMarker) ?? false)
            }
            guard !foreign.isEmpty else { return nil }
            var kept = group
            kept["hooks"] = foreign
            return kept
        }
    }

    private static func keepressoCommands(in group: [String: Any]) -> [String] {
        ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { entry in
            (entry["command"] as? String).flatMap { $0.contains(hookMarker) ? $0 : nil }
        }
    }

    private static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw SettingsUnreadableError()
        }
        return root
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Coding

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
