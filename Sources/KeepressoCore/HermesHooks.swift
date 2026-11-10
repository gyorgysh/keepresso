import Foundation

/// Exact turn-state tracking for Hermes Agent, in the CLI and in its
/// long-running messaging gateway.
///
/// Hermes has no hook file Keepresso can drop beside the user's config:
/// shell hooks live in the YAML `hooks:` block and need a consent allowlist
/// entry before a non-interactive gateway runs them. Its Python plugins have
/// neither problem, so Connect writes a small plugin to
/// `$HERMES_HOME/plugins/keepresso/` and enables it through Hermes' own CLI
/// (`hermes plugins enable`), which owns the YAML edit.
///
/// The plugin runs inside the Hermes process and forwards lifecycle events to
/// `keepresso hermes-hook <event>` from one background thread, so events land
/// in order and never on the agent's own path. It sends only ids, the tool
/// name, and the platform: never prompts, arguments, or replies.
///
/// Records are keyed by turn, not by session: the gateway runs several chats
/// at once, and context compression can rotate a session id mid-turn, while
/// `turn_id` survives both. Every record is anchored to the Hermes process
/// (`ownerPid`), so they become hook-only rows like an IDE's chats. Such rows
/// are trusted for ``AgentHooks/staleAfter`` only; the plugin's heartbeat
/// keeps a live turn fresh through long model waits, and a turn that loses
/// its end event (Hermes skips `on_session_end` on some early returns) goes
/// stale once the heartbeat drops it or the process exits.
public enum HermesHooks {

    /// Ownership marker in every file Keepresso writes into the plugin folder.
    public static let hookMarker = "__keepresso_hermes_hook"

    /// The plugin's registry name, which is also its folder name.
    public static let pluginName = "keepresso"

    public static func ownsRecord(_ record: AgentHooks.HookRecord) -> Bool {
        record.agent == "hermes"
    }

    // MARK: - Locations

    /// `$HERMES_HOME`, or `~/.hermes`. The same root the activity heuristic
    /// reads Hermes' state database from.
    public static func hermesHome(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        // Trimmed like CODEX_HOME and QWEN_HOME, so a blank value falls back.
        environment["HERMES_HOME"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.hermes"
    }

    public static func pluginDirectoryURL(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        URL(fileURLWithPath: hermesHome(home: home, environment: environment))
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
    }

    public static func configURL(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        URL(fileURLWithPath: hermesHome(home: home, environment: environment))
            .appendingPathComponent("config.yaml")
    }

    /// How to run Hermes' own CLI, as argv. A GUI app gets a launchd-minimal
    /// PATH, so the installer's usual launcher spots are probed, then the
    /// checkout's venv interpreter running its entry script directly (what the
    /// launcher itself execs).
    public static func hermesCommand(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String]? {
        for launcher in ["\(home)/.local/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
        where isExecutable(launcher) {
            return [launcher]
        }
        let checkout = "\(hermesHome(home: home, environment: environment))/hermes-agent"
        let python = "\(checkout)/venv/bin/python"
        if isExecutable(python) { return [python, "\(checkout)/hermes"] }
        return nil
    }

    // MARK: - Plugin files

    /// The plugin's files, keyed by name. Pure: the baked CLI path is the only
    /// input, so an install is current exactly when these bytes are on disk.
    public static func pluginFiles(cliPath: String) -> [String: String] {
        [
            "plugin.yaml": manifest,
            "__init__.py": pluginSource(cliPath: cliPath),
        ]
    }

    static let manifest = """
        # \(hookMarker): written by Keepresso. Remove it from Keepresso's
        # Preferences, not by hand, so its state files are cleaned up too.
        name: \(pluginName)
        version: 1.0.0
        description: "Tells Keepresso when Hermes is working, waiting for approval, or idle, so the Mac stays awake only while it should."
        author: Keepresso
        hooks:
          - pre_llm_call
          - pre_api_request
          - pre_tool_call
          - post_tool_call
          - pre_approval_request
          - post_approval_response
          - on_session_end
          - on_session_finalize
          - on_session_reset

        """

    /// The plugin. Python-quoted CLI path, `/Applications` fallback, exactly
    /// like the shell hook commands the other tools get.
    static func pluginSource(cliPath: String) -> String {
        let quoted = pythonQuoted(cliPath)
        return """
        # \(hookMarker): written by Keepresso. Do not edit; Keepresso rewrites it.
        \"\"\"Report Hermes turn state to Keepresso.

        Only ids, the tool name, and the platform leave this process. Prompts,
        tool arguments, and replies are never read or sent.
        \"\"\"

        import json
        import os
        import queue
        import subprocess
        import threading
        import time

        _CLI = \(quoted)
        _FALLBACK = "/Applications/Keepresso.app/Contents/Helpers/keepresso"
        _HEARTBEAT = 30
        # A turn with no hook activity at all for this long lost its end event.
        _ABANDONED = 900

        _lock = threading.Lock()
        _turns = {}  # turn key -> {"session": str, "task": str, "seen": float}
        _local = threading.local()
        _events = queue.Queue()
        _started = False


        def _cli():
            return _CLI if os.access(_CLI, os.X_OK) else _FALLBACK


        def _worker():
            while True:
                event, payload = _events.get()
                try:
                    subprocess.run(
                        [_cli(), "hermes-hook", event],
                        input=json.dumps(payload).encode(),
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=5,
                    )
                except Exception:
                    pass


        def _heartbeat():
            tick = 0
            while True:
                time.sleep(_HEARTBEAT)
                tick += 1
                now = time.time()
                with _lock:
                    stale = [k for k, t in _turns.items() if now - t["seen"] > _ABANDONED]
                    for key in stale:
                        _turns.pop(key, None)
                    live = list(_turns)
                for key in stale:
                    _send("TurnEnd", key)
                for key in live:
                    _send("Heartbeat", key)
                # The idle row only has to beat Keepresso's two-minute
                # staleness window, so it refreshes at half the turn rate.
                if tick % 2 == 0:
                    _send("Presence", "")


        def _start():
            global _started
            with _lock:
                if _started:
                    return
                _started = True
            threading.Thread(target=_worker, name="keepresso-hermes", daemon=True).start()
            threading.Thread(target=_heartbeat, name="keepresso-hermes-heartbeat", daemon=True).start()
            _send("Presence", "")


        def _send(event, turn, tool=None, platform=None):
            payload = {"turn": turn}
            if tool:
                payload["tool_name"] = str(tool)
            if platform:
                payload["platform"] = str(platform)
            _events.put((event, payload))


        def _key(kwargs):
            turn = kwargs.get("turn_id") or ""
            return str(turn) if turn else ""


        def _touch(key, kwargs):
            with _lock:
                entry = _turns.get(key)
                if entry is None:
                    return False
                entry["seen"] = time.time()
                if kwargs.get("session_id"):
                    entry["session"] = str(kwargs["session_id"])
                return True


        def _on_turn_start(**kwargs):
            key = _key(kwargs)
            if not key:
                return None
            session = str(kwargs.get("session_id") or "")
            ended = []
            with _lock:
                # A session runs one turn at a time: anything still open for it
                # missed its end event.
                if session:
                    ended = [k for k, t in _turns.items() if t["session"] == session and k != key]
                    for k in ended:
                        _turns.pop(k, None)
                _turns[key] = {"session": session, "task": str(kwargs.get("task_id") or ""), "seen": time.time()}
            for k in ended:
                _send("TurnEnd", k)
            _send("TurnStart", key, platform=kwargs.get("platform"))
            return None


        def _on_activity(**kwargs):
            _touch(_key(kwargs), kwargs)
            return None


        def _on_pre_tool(**kwargs):
            key = _key(kwargs)
            if _touch(key, kwargs):
                _local.turn = key
                _send("PreToolUse", key, tool=kwargs.get("tool_name"))
            return None


        def _on_post_tool(**kwargs):
            key = _key(kwargs)
            if _touch(key, kwargs):
                _send("PostToolUse", key)
            return None


        def _approval_turn():
            key = getattr(_local, "turn", "")
            with _lock:
                if key in _turns:
                    return key
                return next(iter(_turns)) if len(_turns) == 1 else ""


        def _on_approval(**kwargs):
            # The automatic "smart" reviewer is another model call, not a person.
            if kwargs.get("surface") == "smart":
                return None
            key = _approval_turn()
            if key:
                _send("ApprovalRequest", key)
            return None


        def _on_approval_done(**kwargs):
            if kwargs.get("surface") == "smart":
                return None
            key = _approval_turn()
            if key:
                _send("ApprovalResponse", key)
            return None


        def _on_turn_end(**kwargs):
            key = _key(kwargs)
            with _lock:
                _turns.pop(key, None)
            if key:
                _send("TurnEnd", key)
            return None


        def _on_session_gone(**kwargs):
            session = str(kwargs.get("session_id") or "")
            if not session:
                return None
            with _lock:
                ended = [k for k, t in _turns.items() if t["session"] == session]
                for k in ended:
                    _turns.pop(k, None)
            for k in ended:
                _send("TurnEnd", k)
            return None


        def register(ctx):
            _start()
            ctx.register_hook("pre_llm_call", _on_turn_start)
            ctx.register_hook("pre_api_request", _on_activity)
            ctx.register_hook("pre_tool_call", _on_pre_tool)
            ctx.register_hook("post_tool_call", _on_post_tool)
            ctx.register_hook("pre_approval_request", _on_approval)
            ctx.register_hook("post_approval_response", _on_approval_done)
            ctx.register_hook("on_session_end", _on_turn_end)
            ctx.register_hook("on_session_finalize", _on_session_gone)
            ctx.register_hook("on_session_reset", _on_session_gone)

        """
    }

    /// A Python string literal. JSON's string escaping is a valid subset.
    static func pythonQuoted(_ value: String) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Install state

    /// Whether `config.yaml` lists the plugin under `plugins.enabled`.
    ///
    /// A deliberately narrow reader rather than a YAML parser: Hermes writes
    /// this block itself (`hermes plugins enable`), as a block list or a flow
    /// list under a top-level `plugins:` key, and that is all this needs to
    /// recognize. Anything it can't follow reads as not enabled, which shows
    /// Repair, and Repair re-runs Hermes' own command.
    public static func isEnabled(inConfig yaml: String?) -> Bool {
        guard let yaml else { return false }
        var inPlugins = false
        var inEnabled = false
        var enabledIndent = 0
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                inPlugins = trimmed.hasPrefix("plugins:")
                inEnabled = false
                // Flow style: `plugins: {enabled: [keepresso], ...}`.
                if inPlugins, let open = trimmed.range(of: "enabled:") {
                    let rest = trimmed[open.upperBound...].trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                        let items = rest[rest.index(after: rest.startIndex)..<close]
                            .split(separator: ",").map(unquoted)
                        if items.contains(pluginName) { return true }
                    }
                }
                continue
            }
            guard inPlugins else { continue }
            if trimmed.hasPrefix("enabled:") {
                let rest = trimmed.dropFirst("enabled:".count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("[") {
                    let items = rest.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map(unquoted)
                    if items.contains(pluginName) { return true }
                    inEnabled = false
                } else {
                    inEnabled = true
                    enabledIndent = indent
                }
                continue
            }
            if inEnabled {
                if trimmed.hasPrefix("- ") || trimmed == "-" {
                    if unquoted(trimmed.dropFirst(1)) == pluginName { return true }
                } else if indent <= enabledIndent {
                    inEnabled = false
                }
            }
        }
        return false
    }

    private static func unquoted<S: StringProtocol>(_ value: S) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// The install's state from what is on disk: the plugin files (by name,
    /// `nil` when absent) and whether Hermes has it enabled.
    public static func installState(
        files: [String: Data?],
        enabled: Bool,
        cliPath: String
    ) -> AgentHooks.HookInstallState {
        let expected = pluginFiles(cliPath: cliPath)
        let present = expected.keys.filter { (files[$0] ?? nil) != nil }
        // No files is not installed, whatever the config says: a Remove whose
        // `hermes plugins disable` couldn't run leaves the enabled entry
        // behind, and treating that as repairable drift would reinstall the
        // plugin the user just removed.
        if present.isEmpty { return .notInstalled }
        var stale: Set<String> = []
        var missing: Set<String> = []
        for (name, contents) in expected {
            guard let data = files[name] ?? nil else {
                missing.insert(name)
                continue
            }
            if String(decoding: data, as: UTF8.self) != contents { stale.insert(name) }
        }
        if !enabled { missing.insert("plugins.enabled") }
        if stale.isEmpty && missing.isEmpty { return .installed }
        return .needsRepair(report(stale: stale, missing: missing))
    }

    private static func report(stale: Set<String>, missing: Set<String>) -> AgentHooks.HookInstallReport {
        var report = AgentHooks.HookInstallReport()
        report.stale = stale
        report.missing = missing
        return report
    }

    // MARK: - Payload

    /// What the plugin sends. Every field optional.
    public struct HookPayload: Decodable, Equatable, Sendable {
        public var turn: String?
        public var toolName: String?
        public var platform: String?

        enum CodingKeys: String, CodingKey {
            case turn
            case toolName = "tool_name"
            case platform
        }

        public init(turn: String? = nil, toolName: String? = nil, platform: String? = nil) {
            self.turn = turn
            self.toolName = toolName
            self.platform = platform
        }
    }

    // MARK: - Reduction

    /// What one plugin event does to a record.
    enum Effect: Equatable {
        case set(AgentHooks.HookSessionState, detail: String?)
        /// Refresh the record's timestamp, keeping its state.
        case touch
        case end
    }

    static func reduce(event: String, toolName: String?) -> Effect? {
        switch event {
        case "TurnStart", "PostToolUse", "ApprovalResponse":
            return .set(.working, detail: nil)
        case "PreToolUse":
            return .set(.working, detail: toolName.flatMap(detailToken(forTool:)))
        case "ApprovalRequest":
            return .set(.waiting, detail: "waiting-approval")
        case "Heartbeat":
            return .touch
        case "TurnEnd":
            return .end
        case "Presence":
            return .set(.idle, detail: nil)
        default:
            return nil
        }
    }

    /// Hermes' own tool names, then the shared table.
    static func detailToken(forTool tool: String) -> String? {
        switch tool {
        case "terminal", "process": return "running-command"
        case "write_file", "patch": return "editing"
        case "read_file": return "reading"
        case "search_files": return "searching"
        case "delegate_task": return "subagent"
        case "web_search", "web_extract": return "browsing"
        default:
            if tool.hasPrefix("browser_") { return "browsing" }
            return AgentHooks.detailToken(forTool: tool)
        }
    }

    /// The record id for a turn, or for the Hermes process itself.
    static func recordId(turn: String?, hostPid: Int32) -> String {
        if let turn = AgentHooks.nonEmpty(turn) { return "hermes-turn-\(turn)" }
        return "hermes-host-\(hostPid)"
    }

    /// Whether this is the plugin's per-process presence record rather than
    /// a turn.
    static func isPresence(_ record: AgentHooks.HookRecord) -> Bool {
        record.sessionId.hasPrefix("hermes-host-")
    }

    /// Drops a presence row whose process also has a turn row, so one Hermes
    /// never lists as both idle and working. Alone, the presence row stays:
    /// it is the idle gateway (or CLI) the user would expect to see.
    public static func withoutCoveredPresence(_ records: [AgentHooks.HookRecord]) -> [AgentHooks.HookRecord] {
        let busyHosts = Set(records.filter { ownsRecord($0) && !isPresence($0) }.compactMap(\.ownerPid))
        return records.filter { !(isPresence($0) && $0.ownerPid.map(busyHosts.contains) == true) }
    }

    // MARK: - Handling one invocation

    /// Applies one plugin event. `parentPid` is the Hermes process itself:
    /// the plugin runs in-process and spawns the CLI directly.
    public static func handle(
        event: String,
        payloadData: Data,
        parentPid: Int32,
        now: Date = Date(),
        in directory: URL = AgentHooks.directoryURL()
    ) {
        let payload = (try? JSONDecoder().decode(HookPayload.self, from: payloadData)) ?? HookPayload()
        guard parentPid > 1, let effect = reduce(event: event, toolName: payload.toolName) else { return }
        // Presence is the only event without a turn. Anything else without
        // one is malformed and writes nothing.
        let turn = event == "Presence" ? nil : AgentHooks.nonEmpty(payload.turn)
        guard event == "Presence" || turn != nil else { return }
        let id = recordId(turn: turn, hostPid: parentPid)
        let existing = AgentHooks.readRecord(sessionId: id, in: directory)
        switch effect {
        case .end:
            AgentHooks.delete(sessionId: id, in: directory)
        case .touch:
            guard var record = existing else { return }
            record.updatedAt = now
            AgentHooks.write(record, in: directory)
        case .set(let state, let detail):
            let origin: AgentHooks.HookSessionOrigin? = payload.platform == "cli"
                ? .terminal : existing?.origin
            AgentHooks.write(
                AgentHooks.HookRecord(
                    sessionId: id,
                    state: state,
                    detail: detail,
                    origin: origin,
                    ownerPid: parentPid,
                    agent: "hermes",
                    updatedAt: now
                ),
                in: directory
            )
        }
    }
}
