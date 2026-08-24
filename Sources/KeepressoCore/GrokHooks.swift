import Foundation

/// Exact session-state tracking for Grok Build.
///
/// Grok always trusts `~/.grok/hooks/*.json` (fail-open). Keepresso owns
/// `keepresso.json`: no matcher, timeout 5. Child-session events
/// (`subagentType`) are ignored so a subagent Stop cannot idle the parent.
/// Turn-end events whose promptId does not match the record's current one
/// are ignored.
public enum GrokHooks {

    /// Events Keepresso installs, spelled as Grok matches them. Unrecognized
    /// names are skipped, so a typo here is silent and total.
    public static let installedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "Stop", "StopFailure", "StopCancelled",
        "Notification", "SessionEnd",
    ]

    /// Ownership marker inside every installed hook command. Distinct from
    /// the other tools' markers so removing one integration can never strip
    /// another's entries.
    public static let hookMarker = "__keepresso_grok_hook"

    /// `$GROK_HOME/hooks/keepresso.json`, or `~/.grok/hooks/keepresso.json`.
    /// Grok merges every `*.json` in that directory and treats them as
    /// always-trusted. Keepresso owns this one file and never edits
    /// `config.toml` or a project's `.grok/hooks/` (those need folder trust).
    public static func hooksURL(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        URL(fileURLWithPath: PSAgentActivityMonitor.grokHome(home: home, environment: environment))
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("keepresso.json")
    }

    /// The shell command an installed hook runs.
    ///
    /// Grok fails open: empty stdout and a non-zero exit let the action
    /// proceed. Only an explicit `deny` / Stop `block` changes control flow.
    /// Stop defaults to a 600s timeout because it is a gate. We set 5 so a
    /// wedged Keepresso cannot stall a turn for ten minutes.
    static func hookCommand(event: String, cliPath: String) -> String {
        "c=\(AgentHooks.shellSingleQuoted(cliPath)); [ -x \"$c\" ] || "
            + "c=/Applications/Keepresso.app/Contents/Helpers/keepresso; "
            + "\"$c\" grok-hook \(event); : # \(hookMarker)"
    }

    public static func ownsRecord(_ record: AgentHooks.HookRecord) -> Bool {
        record.agent == "grok"
    }

    // MARK: - Payload

    /// Grok's file-hook envelope. CamelCase on the wire, snake_case when
    /// the grok-agent-sdk rewrites keys. Every field optional.
    public struct HookPayload: Decodable, Equatable, Sendable {
        public var sessionId: String?
        public var cwd: String?
        public var toolName: String?
        public var notificationType: String?
        public var subagentType: String?
        public var promptId: String?
        public var reason: String?
        public var message: String?

        enum CodingKeys: String, CodingKey {
            case sessionId, session_id
            case cwd
            case toolName, tool_name
            case notificationType, notification_type
            case subagentType, subagent_type
            case promptId, prompt_id
            case reason
            case message
        }

        public init(
            sessionId: String? = nil,
            cwd: String? = nil,
            toolName: String? = nil,
            notificationType: String? = nil,
            subagentType: String? = nil,
            promptId: String? = nil,
            reason: String? = nil,
            message: String? = nil
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.toolName = toolName
            self.notificationType = notificationType
            self.subagentType = subagentType
            self.promptId = promptId
            self.reason = reason
            self.message = message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
                ?? c.decodeIfPresent(String.self, forKey: .session_id)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
                ?? c.decodeIfPresent(String.self, forKey: .tool_name)
            notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
                ?? c.decodeIfPresent(String.self, forKey: .notification_type)
            subagentType = try c.decodeIfPresent(String.self, forKey: .subagentType)
                ?? c.decodeIfPresent(String.self, forKey: .subagent_type)
            promptId = try c.decodeIfPresent(String.self, forKey: .promptId)
                ?? c.decodeIfPresent(String.self, forKey: .prompt_id)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            message = try c.decodeIfPresent(String.self, forKey: .message)
        }
    }

    // MARK: - Reduction

    static let turnEndEvents: Set<String> = ["Stop", "StopFailure", "StopCancelled"]

    /// Maps a Grok hook event to its effect. Unknown events write nothing.
    static func reduce(
        event: String,
        toolName: String?,
        notificationType: String?
    ) -> AgentHooks.HookEventEffect? {
        switch event {
        case "SessionStart":
            return .set(.idle, detail: nil)
        case "UserPromptSubmit":
            return .set(.working, detail: nil)
        case "PreToolUse":
            return .set(.working, detail: toolName.flatMap(AgentHooks.detailToken(forTool:)))
        case "PostToolUse", "PostToolUseFailure":
            return .set(.working, detail: nil)
        case "Stop", "StopFailure", "StopCancelled":
            return .set(.idle, detail: nil)
        case "Notification":
            let approval = notificationType == "permission_prompt"
            return .set(.waiting, detail: approval ? "waiting-approval" : nil)
        case "SessionEnd":
            return .end
        default:
            return nil
        }
    }

    // MARK: - Handling one invocation

    /// Applies one hook invocation. Child-session events (`subagentType`
    /// set) are ignored so a subagent Stop cannot idle the parent pid.
    /// Turn-end events whose `promptId` does not match the record's current
    /// one are ignored: Grok can deliver a cancelled turn after the next
    /// prompt has already started.
    public static func handle(
        event: String,
        payloadData: Data,
        parentPid: Int32,
        now: Date = Date(),
        in directory: URL = AgentHooks.directoryURL(),
        parentOf: (Int32) -> Int32? = AgentHooks.defaultParentOf,
        commandOf: (Int32) -> String? = AgentHooks.defaultCommandOf,
        pathOf: (Int32) -> String? = AgentHooks.defaultPathOf,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let payload = (try? decoder.decode(HookPayload.self, from: payloadData)) ?? HookPayload()
        if AgentHooks.nonEmpty(payload.subagentType) != nil { return }
        let sessionId = AgentHooks.nonEmpty(payload.sessionId)
            ?? AgentHooks.nonEmpty(environment["GROK_SESSION_ID"])
        guard let sessionId else { return }
        switch reduce(
            event: event,
            toolName: payload.toolName,
            notificationType: payload.notificationType
        ) {
        case .end:
            AgentHooks.delete(sessionId: sessionId, in: directory)
        case .set(let state, let detail):
            let existing = AgentHooks.readRecord(sessionId: sessionId, in: directory)
            if turnEndEvents.contains(event),
               let incoming = AgentHooks.nonEmpty(payload.promptId),
               let current = AgentHooks.nonEmpty(existing?.promptId),
               incoming != current {
                return
            }
            let promptId: String?
            if event == "UserPromptSubmit" {
                promptId = AgentHooks.nonEmpty(payload.promptId)
            } else {
                promptId = AgentHooks.nonEmpty(payload.promptId)
                    ?? AgentHooks.nonEmpty(existing?.promptId)
            }
            let match = AgentHooks.findAgentAncestor(
                startingAt: parentPid, parentOf: parentOf, commandOf: commandOf, pathOf: pathOf)
            AgentHooks.write(
                AgentHooks.HookRecord(
                    sessionId: sessionId,
                    state: state,
                    detail: detail,
                    cwd: payload.cwd,
                    origin: match?.origin,
                    agentPid: match?.agentPid,
                    agent: match?.agentCommand ?? "grok",
                    promptId: promptId,
                    updatedAt: now
                ),
                in: directory
            )
        case nil:
            break
        }
    }

    // MARK: - keepresso.json

    /// Writes Keepresso's hook object. This file is ours: a re-install
    /// replaces it wholesale so a stale baked path heals, and we never
    /// merge user entries into it (those live in sibling json files).
    public static func installHooks(into data: Data?, cliPath: String) throws -> Data {
        if let data, !data.isEmpty {
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw AgentHooks.SettingsUnreadableError()
            }
        }
        var hooks: [String: Any] = [:]
        for event in installedEvents {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": hookCommand(event: event, cliPath: cliPath),
                    "timeout": 5,
                ] as [String: Any]],
            ] as [String: Any]]
        }
        return try JSONSerialization.data(
            withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
    }

    public static func inspect(_ data: Data?, cliPath: String) -> AgentHooks.HookInstallReport {
        var report = AgentHooks.HookInstallReport()
        guard let data, !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            report.missing = Set(installedEvents)
            return report
        }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let ours = groups.flatMap { keepressoCommands(in: $0) }
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

    static func keepressoCommands(in element: Any) -> [String] {
        guard let group = element as? [String: Any],
              let inner = group["hooks"] as? [Any] else { return [] }
        return inner.compactMap { entry in
            guard let entry = entry as? [String: Any] else { return nil }
            return (entry["command"] as? String).flatMap { $0.contains(hookMarker) ? $0 : nil }
        }
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }
}
