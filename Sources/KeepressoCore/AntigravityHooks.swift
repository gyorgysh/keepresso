import Foundation

/// Exact session-state tracking for Antigravity, Google's agent IDE.
///
/// Antigravity is the third agent with a lifecycle hook system, and the one
/// that needs it most. Its in-editor agent has no command of its own: it runs
/// inside the editor's `language_server`, whose CPU says nothing useful (0%
/// through a working stretch that was waiting on a command, blips while idle),
/// and whose child processes outlive the turn whenever the agent starts a dev
/// server for a preview. Without hooks the only signal is how recently the
/// conversation store was written, which detects the start of work well but
/// only guesses at the end of it.
///
/// Records land in the same folder as ``AgentHooks``' and are read back by the
/// same monitor, so the join, staleness and trigger logic are all shared. Only
/// the payload shape, the event names and the config file differ.
public enum AntigravityHooks {


    /// The events Keepresso installs, exactly the ones ``reduce(event:toolName:fullyIdle:)``
    /// maps. Every one is an observation step whose output cannot allow, deny
    /// or block anything.
    public static let installedEvents = [
        "PreInvocation", "PostToolUse", "PostInvocation", "Stop",
    ]

    static let blockingEvents: Set<String> = ["PreToolUse"]


    /// The hook payload Antigravity delivers on stdin. Tolerant like the other
    /// two: every field optional, unknown fields ignored.
    ///
    /// Antigravity uses camelCase throughout, and identifies a session by
    /// `conversationId`. There is no `cwd`: `workspacePaths` carries the open
    /// roots, whose first entry stands in for it on the cwd join fallback.
    public struct HookPayload: Decodable, Equatable, Sendable {
        public var conversationId: String?
        public var workspacePaths: [String]?
        public var toolCall: ToolCall?
        /// `Stop` only: false while more execution follows, so a Stop that is
        /// merely the end of one execution isn't read as the end of the turn.
        public var fullyIdle: Bool?
        public var terminationReason: String?

        /// `PreToolUse`/`PostToolUse` name the tool inside an object rather
        /// than as a flat field.
        public struct ToolCall: Decodable, Equatable, Sendable {
            public var name: String?

            public init(name: String? = nil) { self.name = name }
        }

        public init(
            conversationId: String? = nil,
            workspacePaths: [String]? = nil,
            toolCall: ToolCall? = nil,
            fullyIdle: Bool? = nil,
            terminationReason: String? = nil
        ) {
            self.conversationId = conversationId
            self.workspacePaths = workspacePaths
            self.toolCall = toolCall
            self.fullyIdle = fullyIdle
            self.terminationReason = terminationReason
        }

        /// The session identity.
        public var identity: String? {
            (conversationId?.isEmpty ?? true) ? nil : conversationId
        }

        /// The session's working directory, for the cwd join fallback.
        public var directory: String? { workspacePaths?.first }
    }


    /// Maps an Antigravity hook event to its effect on the session record.
    /// Unknown events return `nil` (write nothing), so a new event name can
    /// never break anything.
    public static func reduce(
        event: String, toolName: String?, fullyIdle: Bool?
    ) -> AgentHooks.HookEventEffect? {
        switch event {
        case "PreInvocation":
            return .set(.working, detail: nil)
        case "PostToolUse":
            return .set(.working, detail: toolName.flatMap(detailToken(forTool:)))
        case "PostInvocation":
            return .set(.working, detail: nil)
        case "Stop":
            return .set(fullyIdle == false ? .working : .idle, detail: nil)
        default:
            return nil
        }
    }

    static func detailToken(forTool tool: String) -> String? {
        switch tool {
        case "run_command", "run_terminal_command", "terminal": return "running-command"
        case "write_file", "edit_file", "replace_file_content", "create_file": return "editing"
        case "read_file", "view_file", "read_url_content": return "reading"
        case "grep_search", "codebase_search", "find_by_name", "list_dir": return "searching"
        case "browser_navigate", "browser_screenshot", "search_web": return "browsing"
        default: return AgentHooks.detailToken(forTool: tool)
        }
    }


    /// Applies one hook invocation end to end: decode the payload, reduce the
    /// event, resolve the owning process, write or delete the record. Never
    /// throws and never prints; the caller emits `{}` and exits 0 regardless.
    ///
    /// Resolution has the same two shapes as ``CursorHooks/handle``: a CLI
    /// session joins on `agentPid`, and an IDE session anchors to the editor's
    /// `language_server` as `ownerPid` so each conversation is its own
    /// hook-only row. Writing the host into `agentPid` instead would collapse
    /// every open conversation onto the one process the `ps` scan already
    /// sees, and `applyHookRecords`' newest-wins rule would let a Stop in
    /// chat B idle the Mac while chat A was still working.
    public static func handle(
        event: String,
        payloadData: Data,
        parentPid: Int32,
        now: Date = Date(),
        in directory: URL = AgentHooks.directoryURL(),
        parentOf: (Int32) -> Int32? = AgentHooks.defaultParentOf,
        commandOf: (Int32) -> String? = AgentHooks.defaultCommandOf,
        pathOf: (Int32) -> String? = AgentHooks.defaultPathOf
    ) {
        let payload = (try? decoder.decode(HookPayload.self, from: payloadData)) ?? HookPayload()
        guard let sessionId = payload.identity else { return }
        switch reduce(
            event: event, toolName: payload.toolCall?.name, fullyIdle: payload.fullyIdle
        ) {
        case .end:
            AgentHooks.delete(sessionId: sessionId, in: directory)
        case .set(let state, let detail):
            let cli = AgentHooks.findAgentAncestor(
                startingAt: parentPid, parentOf: parentOf, commandOf: commandOf, pathOf: pathOf)
            let host = cli == nil
                ? findEditorHost(startingAt: parentPid, parentOf: parentOf, pathOf: pathOf)
                : nil
            AgentHooks.write(
                AgentHooks.HookRecord(
                    sessionId: sessionId,
                    state: state,
                    detail: detail,
                    cwd: payload.directory,
                    origin: cli?.origin ?? (host == nil ? nil : .ide),
                    agentPid: cli?.agentPid,
                    ownerPid: host,
                    agent: cli?.agentCommand ?? "antigravity",
                    updatedAt: now
                ),
                in: directory
            )
        case nil:
            break
        }
    }

    static func findEditorHost(
        startingAt pid: Int32,
        depthLimit: Int = 20,
        parentOf: (Int32) -> Int32? = AgentHooks.defaultParentOf,
        pathOf: (Int32) -> String? = AgentHooks.defaultPathOf
    ) -> Int32? {
        var visited: Set<Int32> = []
        var current = pid
        var depth = 0
        while current > 1, depth < depthLimit, visited.insert(current).inserted {
            if let path = pathOf(current), isEditorHostPath(path) { return current }
            guard let parent = parentOf(current) else { return nil }
            current = parent
            depth += 1
        }
        return nil
    }

    static func isEditorHostPath(_ path: String) -> Bool {
        path.contains("Antigravity.app/") && path.hasSuffix("/language_server")
    }

    /// Whether a record in the shared hooks folder came from Antigravity, so
    /// uninstalling one tool's hooks leaves another's live sessions alone.
    public static func ownsRecord(_ record: AgentHooks.HookRecord) -> Bool {
        record.agent == "antigravity" || record.agent == "agy"
    }


    /// Ownership marker inside every installed hook command, what
    /// ``removeHooks(from:)`` keys on. Never change it: released versions must
    /// keep recognizing each other's entries.
    public static let hookMarker = "__keepresso_antigravity_hook"

    /// The top-level key Keepresso owns in `hooks.json`. Antigravity groups
    /// hooks under a name of the author's choosing, so unlike Cursor's flat
    /// file there is a whole object that is unambiguously ours.
    public static let hookName = "keepresso"

    /// `~/.gemini/config/hooks.json`, Antigravity's global hook config. The
    /// per-workspace `.agents/hooks.json` is deliberately left alone: a
    /// keep-awake that only works in the folders someone remembered to set up
    /// is worse than useless, and writing into a repo would commit Keepresso's
    /// absolute paths into somebody's version control.
    public static func hooksURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    static func hookCommand(event: String, cliPath: String) -> String {
        "printf '{}'; c=\(AgentHooks.shellSingleQuoted(cliPath)); [ -x \"$c\" ] || "
            + "c=/Applications/Keepresso.app/Contents/Helpers/keepresso; "
            + "\"$c\" antigravity-hook \(event) >/dev/null 2>&1; : # \(hookMarker)"
    }

    static func entry(event: String, cliPath: String) -> [String: Any] {
        [
            "hooks": [
                [
                    "type": "command",
                    "command": hookCommand(event: event, cliPath: cliPath),
                    "timeout": 5,
                ] as [String: Any]
            ]
        ]
    }

    /// Writes Keepresso's hook object, preserving every other author's hooks
    /// verbatim. Ours is replaced wholesale, so a re-install is idempotent and
    /// self-healing for a stale baked path.
    public static func installHooks(into data: Data?, cliPath: String) throws -> Data {
        var root = try parseRoot(data)
        var ours: [String: Any] = ["enabled": true]
        for event in installedEvents {
            assert(!blockingEvents.contains(event), "must never install on a blocking event")
            ours[event] = [entry(event: event, cliPath: cliPath)]
        }
        root[hookName] = ours
        for (name, value) in root where name != hookName {
            guard let object = value as? [String: Any],
                  let swept = strippingOurEntries(from: object) else { continue }
            root[name] = swept
        }
        return try serialize(root)
    }

    /// Removes Keepresso's hook object and any stray entries of ours inside
    /// other objects; everything else is left untouched.
    public static func removeHooks(from data: Data?) throws -> Data {
        var root = try parseRoot(data)
        root.removeValue(forKey: hookName)
        for (name, value) in root {
            guard let object = value as? [String: Any],
                  let swept = strippingOurEntries(from: object) else { continue }
            if swept.filter({ $0.key != "enabled" }).isEmpty {
                root.removeValue(forKey: name)
            } else {
                root[name] = swept
            }
        }
        return try serialize(root)
    }

    static func strippingOurEntries(from object: [String: Any]) -> [String: Any]? {
        var result = object
        var changed = false
        for (event, value) in object {
            guard let groups = value as? [Any],
                  !keepressoCommands(in: groups).isEmpty else { continue }
            changed = true
            let kept = stripKeepressoGroups(groups)
            if kept.isEmpty {
                result.removeValue(forKey: event)
            } else {
                result[event] = kept
            }
        }
        return changed ? result : nil
    }

    /// Same event-by-event report as the other two, over Antigravity's nested
    /// shape (a named object, then an event, then groups, then hooks).
    public static func inspect(_ data: Data?, cliPath: String) -> AgentHooks.HookInstallReport {
        var report = AgentHooks.HookInstallReport()
        guard let data, !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            report.missing = Set(installedEvents)
            return report
        }
        let enabled = ((root[hookName] as? [String: Any])?["enabled"] as? Bool) ?? true
        var commands: [String: [String]] = [:]
        for (_, value) in root {
            guard let object = value as? [String: Any] else { continue }
            for (event, groups) in object {
                guard let groups = groups as? [Any] else { continue }
                let ours = keepressoCommands(in: groups)
                guard !ours.isEmpty else { continue }
                commands[event, default: []].append(contentsOf: ours)
            }
        }
        for (event, ours) in commands {
            guard installedEvents.contains(event) else {
                report.orphaned.insert(event)
                continue
            }
            if ours.count > 1 {
                report.duplicated.insert(event)
            } else if ours[0] != hookCommand(event: event, cliPath: cliPath) || !enabled {
                report.stale.insert(event)
            } else {
                report.healthy.insert(event)
            }
        }
        report.missing = Set(installedEvents)
            .subtracting(report.healthy)
            .subtracting(report.duplicated)
            .subtracting(report.stale)
        return report
    }

    public static func hookInstallState(of data: Data?, cliPath: String) -> AgentHooks.HookInstallState {
        guard let data, !data.isEmpty else { return .notInstalled }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else { return .unreadable }
        let report = inspect(data, cliPath: cliPath)
        if report.isAbsent { return .notInstalled }
        return report.isHealthy ? .installed : .needsRepair(report)
    }

    static func keepressoCommands(in groups: [Any]) -> [String] {
        groups.flatMap { group -> [String] in
            guard let group = group as? [String: Any],
                  let hooks = group["hooks"] as? [Any] else { return [] }
            return hooks.compactMap { hook in
                guard let hook = hook as? [String: Any],
                      let command = hook["command"] as? String,
                      command.contains(hookMarker) else { return nil }
                return command
            }
        }
    }

    static func stripKeepressoGroups(_ groups: [Any]) -> [Any] {
        groups.compactMap { element -> Any? in
            guard var group = element as? [String: Any],
                  let hooks = group["hooks"] as? [Any] else { return element }
            let kept = hooks.filter { hook in
                guard let hook = hook as? [String: Any],
                      let command = hook["command"] as? String else { return true }
                return !command.contains(hookMarker)
            }
            if kept.isEmpty { return nil }
            group["hooks"] = kept
            return group
        }
    }

    private static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw AgentHooks.SettingsUnreadableError()
        }
        return root
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
