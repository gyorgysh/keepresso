import Foundation

/// Exact session-state tracking for Cursor, the second agent with a lifecycle
/// hook system. Cursor covers two very different sessions with one mechanism:
/// the `cursor-agent` CLI, which the `ps` scan already finds, and the agent
/// built into the Cursor IDE, which runs inside Electron and has no process of
/// its own at all. For the IDE, hooks are the only signal there can ever be.
///
/// Records land in the same folder as ``AgentHooks``' and are read back by the
/// same monitor, so everything downstream (join, staleness, the trigger) is
/// shared. Only the payload shape, the event names, and the config file differ.
public enum CursorHooks {

    // MARK: - Events
    //
    // Cursor splits its hook steps in two, and the split is a safety boundary
    // rather than a matter of taste.
    //
    // On a *permission* step (`preToolUse`, `beforeShellExecution`,
    // `beforeMCPExecution`, `beforeReadFile`, `subagentStart`) the hook's
    // stdout is a verdict on whether the action may run, and Cursor blocks the
    // action when a hook returns empty or unparseable output. That is not the
    // documented fail-open behavior, it is a deliberate "blocked for safety"
    // path that ignores `failClosed`. Keepresso's hook command is built to be
    // a silent no-op when the CLI is missing (a deleted app, a stale entry),
    // and a silent no-op on a permission step denies every tool call in the
    // session. So Keepresso installs on **observation steps only**, and the
    // list below must never grow a permission step.
    //
    // The same rule cuts the other way: a hook must never answer
    // `{"permission": "allow"}` either, because that would wave through
    // commands the user's own approval settings meant to stop. Keepresso has
    // no business voting on permissions in either direction.

    /// The events Keepresso installs, exactly the ones ``reduce(event:toolName:)``
    /// maps. Every one is an observation step: its output cannot allow, deny,
    /// or block anything.
    public static let installedEvents = [
        "sessionStart", "beforeSubmitPrompt", "postToolUse", "afterShellExecution",
        "afterFileEdit", "afterAgentThought", "afterAgentResponse", "subagentStop",
        "preCompact", "stop", "sessionEnd",
    ]

    /// The steps whose stdout Cursor reads as a permission verdict. Kept here
    /// as an explicit tripwire for ``installedEvents``, never installed on.
    static let permissionEvents: Set<String> = [
        "preToolUse", "beforeShellExecution", "beforeMCPExecution",
        "beforeReadFile", "beforeTabFileRead", "subagentStart",
    ]

    // MARK: - Payload

    /// The hook payload Cursor delivers on stdin. Tolerant like
    /// ``AgentHooks/HookPayload``: every field optional, unknown fields
    /// ignored. `conversation_id` is the session identity, present on every
    /// agent hook; `workspace_roots` stands in for `cwd` on the events that
    /// carry no tool.
    public struct HookPayload: Decodable, Equatable, Sendable {
        public var conversationId: String?
        public var sessionId: String?
        public var hookEventName: String?
        public var cwd: String?
        public var workspaceRoots: [String]?
        public var toolName: String?

        enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id"
            case sessionId = "session_id"
            case hookEventName = "hook_event_name"
            case cwd
            case workspaceRoots = "workspace_roots"
            case toolName = "tool_name"
        }

        public init(
            conversationId: String? = nil,
            sessionId: String? = nil,
            hookEventName: String? = nil,
            cwd: String? = nil,
            workspaceRoots: [String]? = nil,
            toolName: String? = nil
        ) {
            self.conversationId = conversationId
            self.sessionId = sessionId
            self.hookEventName = hookEventName
            self.cwd = cwd
            self.workspaceRoots = workspaceRoots
            self.toolName = toolName
        }

        /// The session identity: `conversation_id` on agent hooks, with
        /// `session_id` (which `sessionStart` and `sessionEnd` also carry) as
        /// the fallback.
        public var identity: String? {
            let id = conversationId ?? sessionId
            return (id?.isEmpty ?? true) ? nil : id
        }

        /// The session's working directory, for the cwd join fallback.
        public var directory: String? { cwd ?? workspaceRoots?.first }
    }

    // MARK: - Event reduction

    /// Maps a Cursor hook event to its effect on the session record. Unknown
    /// events return `nil` (write nothing), so a new Cursor event name can
    /// never break anything.
    ///
    /// Cursor has no pre-tool observation step, only the permission-gated
    /// `preToolUse` that Keepresso must not touch, so the detail token comes
    /// from `postToolUse` and therefore names the tool that has *just*
    /// finished rather than one now running. The gap is one tool call wide,
    /// and the events that mean "the agent has moved on" clear it again.
    public static func reduce(event: String, toolName: String?) -> AgentHooks.HookEventEffect? {
        switch event {
        case "sessionStart":
            // Like Claude's SessionStart: a session that just opened is
            // waiting for its first prompt, not working. Writing the record
            // anyway is what lands the pid join and the origin immediately.
            return .set(.idle, detail: nil)
        case "beforeSubmitPrompt":
            return .set(.working, detail: nil)
        case "postToolUse":
            return .set(.working, detail: toolName.flatMap(detailToken(forTool:)))
        case "afterShellExecution":
            return .set(.working, detail: "running-command")
        case "afterFileEdit":
            return .set(.working, detail: "editing")
        case "subagentStop":
            return .set(.working, detail: "subagent")
        case "afterAgentThought", "afterAgentResponse", "preCompact":
            // The agent is between steps: still working, but no longer on
            // whatever tool the last postToolUse named.
            return .set(.working, detail: nil)
        case "stop":
            return .set(.idle, detail: nil)
        case "sessionEnd":
            return .end
        default:
            return nil
        }
    }

    /// The semantic token for one of Cursor's tool names. Cursor names its
    /// built-ins differently from Claude Code (`Shell`, not `Bash`) and
    /// prefixes MCP tools with `MCP:`; everything else falls through to the
    /// shared `tool:<name>` catch-all the app renders as "using <name>".
    static func detailToken(forTool tool: String) -> String? {
        switch tool {
        case "Shell": return "running-command"
        case "Write", "Edit", "MultiEdit", "Update", "Delete": return "editing"
        case "Read": return "reading"
        case "Grep", "Glob", "Codebase", "Search": return "searching"
        case "Task": return "subagent"
        case "WebSearch", "Fetch": return "browsing"
        default:
            let mcp = tool.hasPrefix("MCP:") ? String(tool.dropFirst("MCP:".count)) : tool
            return AgentHooks.detailToken(forTool: mcp)
        }
    }

    // MARK: - Handling one invocation

    /// Applies one hook invocation end to end: decode the payload, reduce the
    /// event, resolve the owning process, write or delete the record. Never
    /// throws and never prints; the caller emits `{}` and exits 0 regardless.
    ///
    /// Resolution has two shapes, because Cursor does. A `cursor-agent` CLI
    /// session has a real agent process above the hook, so it joins on
    /// `agentPid` exactly like Claude Code. An IDE session does not, and
    /// falls back to the hosting app, which makes it a hook-only session the
    /// monitor surfaces on its own.
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
        switch reduce(event: event, toolName: payload.toolName) {
        case .end:
            AgentHooks.delete(sessionId: sessionId, in: directory)
        case .set(let state, let detail):
            let agent = AgentHooks.findAgentAncestor(
                startingAt: parentPid, parentOf: parentOf, commandOf: commandOf, pathOf: pathOf)
            let host = agent == nil
                ? AgentHooks.findAppHost(
                    startingAt: parentPid, parentOf: parentOf, commandOf: commandOf)
                : nil
            AgentHooks.write(
                AgentHooks.HookRecord(
                    sessionId: sessionId,
                    state: state,
                    detail: detail,
                    cwd: payload.directory,
                    origin: agent?.origin ?? host?.origin,
                    agentPid: agent?.agentPid,
                    ownerPid: host?.hostPid,
                    agent: agent?.agentCommand ?? "cursor",
                    updatedAt: now
                ),
                in: directory
            )
        case nil:
            break
        }
    }

    /// Whether a record in the shared hooks folder came from Cursor, so
    /// uninstalling one tool's hooks leaves the other's live sessions alone.
    /// Records predate the `agent` field, and only Claude Code wrote them
    /// then, so a missing name is not ours.
    public static func ownsRecord(_ record: AgentHooks.HookRecord) -> Bool {
        record.agent == "cursor" || record.agent == "cursor-agent"
    }

    // MARK: - hooks.json install/remove

    /// Ownership marker inside every installed hook command, what
    /// ``removeHooks(from:)`` keys on. Never change it: released versions must
    /// keep recognizing each other's entries.
    public static let hookMarker = "__keepresso_cursor_hook"

    /// `~/.cursor/hooks.json`, Cursor's user-level hook config. Unlike Claude
    /// Code's settings.json this file holds nothing but hooks, but it is still
    /// merged rather than replaced: a user's own hooks live here too.
    public static func hooksURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    /// The shell command an installed hook runs. Same shape as
    /// ``AgentHooks/hookCommand(event:cliPath:)``, with one addition: it
    /// prints `{}` first, unconditionally.
    ///
    /// The empty object is a valid response for every installed event and
    /// carries no opinion (no `permission`, no `continue`), so it can neither
    /// allow nor block anything. Printing it before running the CLI means the
    /// response is already on stdout even if the binary is missing or wedged,
    /// which keeps a stale hook from a deleted app completely inert.
    static func hookCommand(event: String, cliPath: String) -> String {
        "printf '{}'; c=\(AgentHooks.shellSingleQuoted(cliPath)); [ -x \"$c\" ] || "
            + "c=/Applications/Keepresso.app/Contents/Helpers/keepresso; "
            + "\"$c\" cursor-hook \(event) >/dev/null 2>&1; : # \(hookMarker)"
    }

    /// Merges one Keepresso entry per mapped event into the `hooks` object,
    /// preserving every foreign key and other tools' entries verbatim.
    /// Existing Keepresso entries are replaced, so a re-install is idempotent
    /// and self-healing for a stale baked path. `nil` input (no hooks.json
    /// yet) starts from an empty object.
    public static func installHooks(into data: Data?, cliPath: String) throws -> Data {
        var root = try parseRoot(data)
        // Cursor rejects a config without its schema version.
        if root["version"] == nil { root["version"] = 1 }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Sweep our entries out of every event first, not only the ones about
        // to be rewritten. An entry left under an event an older version
        // installed is still ours and still fires, and Repair is just a
        // re-install, so a re-install has to be able to clear it.
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            // Only events that actually hold one of ours are touched.
            guard groups.contains(where: { isKeepresso($0) }) else { continue }
            let kept = stripKeepressoEntries(groups)
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        for event in installedEvents {
            assert(!permissionEvents.contains(event), "must never install on a permission step")
            var entries = (hooks[event] as? [Any]) ?? []
            entries.append([
                "command": hookCommand(event: event, cliPath: cliPath),
                // Our CLI answers in milliseconds; a tight timeout means even
                // a wedged disk can't stall a session.
                "timeout": 5,
            ] as [String: Any])
            hooks[event] = entries
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
                guard let entries = value as? [Any] else { continue }
                let kept = stripKeepressoEntries(entries)
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

    /// Same event-by-event report as ``AgentHooks/inspect(_:cliPath:)``, over
    /// Cursor's flatter shape (an event maps straight to entries, with no
    /// matcher groups in between).
    public static func inspect(_ data: Data?, cliPath: String) -> AgentHooks.HookInstallReport {
        var report = AgentHooks.HookInstallReport()
        guard let data, !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            report.missing = Set(installedEvents)
            return report
        }
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            let ours = entries.filter { isKeepresso($0) }
                .compactMap { ($0 as? [String: Any])?["command"] as? String }
            guard !ours.isEmpty else { continue }
            guard installedEvents.contains(event) else {
                report.orphaned.insert(event)
                continue
            }
            if ours.count > 1 {
                report.duplicated.insert(event)
            } else if ours[0] != hookCommand(event: event, cliPath: cliPath) {
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

    /// Drops our own entries, carrying anything unrecognised through
    /// untouched. Walked as `[Any]` for the reason spelled out on
    /// ``AgentHooks/stripKeepressoEntries(_:)``: a single element we cannot
    /// read must never cost the user the rest of their hooks for that event.
    static func stripKeepressoEntries(_ entries: [Any]) -> [Any] {
        entries.filter { !isKeepresso($0) }
    }

    static func isKeepresso(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any] else { return false }
        return (entry["command"] as? String)?.contains(hookMarker) ?? false
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
