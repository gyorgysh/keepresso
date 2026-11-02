import Foundation

/// Exact session-state tracking for the agent CLIs whose hooks are modeled on
/// Claude Code's: Qwen Code, Devin, and Kimi Code.
///
/// All three pipe a snake_case JSON payload (`session_id`, `tool_name`, ...)
/// into a shell command for the same lifecycle events Claude Code has, so one
/// reducer serves them. Where they keep their hooks differs:
///
/// - Qwen Code: the `hooks` key of `$QWEN_HOME/settings.json` (default
///   `~/.qwen`), Claude's exact shape, timeouts in milliseconds.
/// - Devin: the `hooks` key of `~/.config/devin/config.json`, Claude's exact
///   shape. Devin also ships an importer for Claude's own settings, but it
///   does not run them, so Claude Code's connection does not cover it.
/// - Kimi Code: `[[hooks]]` tables in `$KIMI_CODE_HOME/config.toml` (default
///   `~/.kimi-code`), see ``KimiHooksFile``.
public enum CompatHooks {

    public enum Tool: String, CaseIterable, Sendable {
        case qwen
        case devin
        case kimi

        /// The agent name records carry, matching
        /// ``PSAgentActivityMonitor/agentCommands``.
        public var agent: String { rawValue }

        /// The hidden CLI subcommand its hooks call.
        public var subcommand: String { "\(rawValue)-hook" }

        /// Ownership marker in every installed command. Distinct per tool and
        /// never a substring of Claude's ``AgentHooks/hookMarker``, so removing
        /// one integration can never strip another's entries.
        public var marker: String { "__keepresso_\(rawValue)_hook" }

        /// Exactly the events ``CompatHooks/reduce(event:toolName:notificationType:message:isSubagent:)``
        /// maps, spelled as each tool emits them.
        public var events: [String] {
            switch self {
            case .qwen:
                return [
                    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                    "PostToolUseFailure", "PermissionRequest", "Notification", "Stop",
                    "StopFailure", "SessionEnd",
                ]
            case .devin:
                return [
                    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                    "PermissionRequest", "Notification", "Stop", "SessionEnd",
                ]
            case .kimi:
                return [
                    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                    "PostToolUseFailure", "PermissionRequest", "PermissionResult",
                    "Notification", "Stop", "StopFailure", "Interrupt", "SessionEnd",
                ]
            }
        }

        /// The settings-file format for the two JSON tools. Qwen's matcher is
        /// a regex, where `*` is invalid, so it gets none (no matcher matches
        /// every tool). Devin accepts Claude's `*`.
        public var settingsFormat: AgentHooks.SettingsFormat {
            AgentHooks.SettingsFormat(
                subcommand: subcommand,
                marker: marker,
                events: events,
                matcherEvents: self == .devin ? ["PreToolUse", "PostToolUse"] : [],
                // Qwen counts milliseconds, Devin and Kimi seconds.
                timeout: self == .qwen ? 5000 : 5)
        }

        /// The file Keepresso edits.
        public func configURL(
            home: String = NSHomeDirectory(),
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> URL {
            func nonEmpty(_ key: String) -> String? {
                environment[key].flatMap {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }
            switch self {
            case .qwen:
                let root = nonEmpty("QWEN_HOME").map { ($0 as NSString).expandingTildeInPath }
                    ?? "\(home)/.qwen"
                return URL(fileURLWithPath: root).appendingPathComponent("settings.json")
            case .devin:
                let root = nonEmpty("XDG_CONFIG_HOME") ?? "\(home)/.config"
                return URL(fileURLWithPath: root)
                    .appendingPathComponent("devin", isDirectory: true)
                    .appendingPathComponent("config.json")
            case .kimi:
                return URL(fileURLWithPath: PSAgentActivityMonitor.kimiCodeHome(
                    home: home, environment: environment))
                    .appendingPathComponent("config.toml")
            }
        }

        public func ownsRecord(_ record: AgentHooks.HookRecord) -> Bool {
            record.agent == agent
        }

        /// The Connect row this tool belongs to.
        public var agentTool: AgentTool {
            switch self {
            case .qwen: return .qwen
            case .devin: return .devin
            case .kimi: return .kimi
            }
        }
    }

    public static func ownsRecord(_ record: AgentHooks.HookRecord) -> Bool {
        Tool.allCases.contains { $0.ownsRecord(record) }
    }

    // MARK: - Payload

    public struct HookPayload: Decodable, Equatable, Sendable {
        public var sessionId: String?
        public var cwd: String?
        public var toolName: String?
        public var notificationType: String?
        public var message: String?
        /// Set on events from inside a subagent (Qwen's `agent_id`).
        public var agentId: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd
            case toolName = "tool_name"
            case notificationType = "notification_type"
            case message
            case agentId = "agent_id"
        }

        public init(
            sessionId: String? = nil, cwd: String? = nil, toolName: String? = nil,
            notificationType: String? = nil, message: String? = nil, agentId: String? = nil
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.toolName = toolName
            self.notificationType = notificationType
            self.message = message
            self.agentId = agentId
        }
    }

    // MARK: - Reduction

    static let turnEndEvents: Set<String> = ["Stop", "StopFailure", "Interrupt"]

    /// Maps one event to its effect. Unknown events write nothing. A
    /// turn-ending event from inside a subagent is ignored so it can't idle
    /// the parent session, which is still working.
    static func reduce(
        event: String,
        toolName: String?,
        notificationType: String?,
        message: String?,
        isSubagent: Bool
    ) -> AgentHooks.HookEventEffect? {
        switch event {
        case "SessionStart":
            return .set(.idle, detail: nil)
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PermissionResult":
            return .set(.working, detail: nil)
        case "PreToolUse":
            return .set(.working, detail: toolName.flatMap(AgentHooks.detailToken(forTool:)))
        case "PermissionRequest":
            return .set(.waiting, detail: "waiting-approval")
        case "Notification":
            // Only notifications about the user count. Qwen also sends
            // `auth_success` at startup, and a plain `waiting` record from it
            // would read as working under "count waiting as working".
            switch notificationType {
            case "permission_prompt": return .set(.waiting, detail: "waiting-approval")
            case "idle_prompt": return .set(.waiting, detail: nil)
            case nil:
                let approval = message?.range(of: "permission", options: .caseInsensitive) != nil
                return .set(.waiting, detail: approval ? "waiting-approval" : nil)
            default: return nil
            }
        case _ where turnEndEvents.contains(event):
            return isSubagent ? nil : .set(.idle, detail: nil)
        case "SessionEnd":
            return .end
        default:
            return nil
        }
    }

    // MARK: - Ancestor walk

    /// The tool's own process above the hook. Only that tool's name counts:
    /// a Qwen session started from a Claude Code terminal must not be pinned
    /// to the Claude process. Qwen runs as a generic `node`, so its process
    /// is recognized from argv the way the `ps` scan recognizes it.
    static func findAgent(
        _ tool: Tool,
        startingAt pid: Int32,
        parentOf: (Int32) -> Int32?,
        commandOf: (Int32) -> String?,
        pathOf: (Int32) -> String?,
        argumentsOf: (Int32) -> String?
    ) -> AgentHooks.AncestorMatch? {
        AgentHooks.findAgentAncestor(
            startingAt: pid,
            agents: [tool.agent],
            parentOf: parentOf,
            commandOf: commandOf,
            pathOf: pathOf,
            foldsWrapper: true,
            alsoMatches: { pid in
                switch tool {
                case .devin:
                    return commandOf(pid).map(PSAgentActivityMonitor.isDevinAgentBasename) ?? false
                case .qwen:
                    return argumentsOf(pid).map(PSAgentActivityMonitor.isQwenCodeCommand) ?? false
                case .kimi:
                    return false
                }
            }
        )
    }

    // MARK: - Handling one invocation

    public static func handle(
        tool: Tool,
        event: String,
        payloadData: Data,
        parentPid: Int32,
        now: Date = Date(),
        in directory: URL = AgentHooks.directoryURL(),
        parentOf: (Int32) -> Int32? = AgentHooks.defaultParentOf,
        commandOf: (Int32) -> String? = AgentHooks.defaultCommandOf,
        pathOf: (Int32) -> String? = AgentHooks.defaultPathOf,
        argumentsOf: (Int32) -> String? = AgentHooks.defaultArgumentsOf
    ) {
        let payload = (try? JSONDecoder().decode(HookPayload.self, from: payloadData)) ?? HookPayload()
        guard let sessionId = AgentHooks.nonEmpty(payload.sessionId) else { return }
        // Records share one folder with every other tool's. A session id is
        // the tool's own, so prefix it: Devin's are short words
        // ("sparkly-fluorine") that could otherwise collide.
        let id = "\(tool.rawValue)-\(sessionId)"
        switch reduce(
            event: event,
            toolName: payload.toolName,
            notificationType: payload.notificationType,
            message: payload.message,
            isSubagent: AgentHooks.nonEmpty(payload.agentId) != nil
        ) {
        case .end:
            AgentHooks.delete(sessionId: id, in: directory)
        case .set(let state, let detail):
            let match = findAgent(
                tool, startingAt: parentPid, parentOf: parentOf, commandOf: commandOf,
                pathOf: pathOf, argumentsOf: argumentsOf)
            // Devin's payload carries no cwd; the agent's own working
            // directory is the fallback join key.
            let cwd = AgentHooks.nonEmpty(payload.cwd)
                ?? match.flatMap { PSAgentActivityMonitor.processCwd($0.agentPid) }
            AgentHooks.write(
                AgentHooks.HookRecord(
                    sessionId: id,
                    state: state,
                    detail: detail,
                    cwd: cwd,
                    origin: match?.origin,
                    agentPid: match?.agentPid,
                    agent: tool.agent,
                    updatedAt: now
                ),
                in: directory
            )
        case nil:
            break
        }
    }
}

/// Keepresso's entries in Kimi Code's `config.toml`.
///
/// Kimi reads hooks as an array of tables, each exactly `event`, `matcher`,
/// `command`, and `timeout` (its schema is strict, so the ownership marker
/// has to live inside the command). This is a line-level editor, not a TOML
/// parser: it only ever removes `[[hooks]]` tables whose command carries
/// Keepresso's marker and appends its own at the end, leaving every other
/// byte of the file as it was. A file it cannot safely edit (an inline
/// `hooks = [...]` array, which can't be mixed with tables) is reported
/// unreadable and left alone.
public enum KimiHooksFile {

    static let tool = CompatHooks.Tool.kimi

    /// One `[[hooks]]` table: its line range and the values Keepresso reads.
    struct Block: Equatable {
        var lines: Range<Int>
        var event: String?
        var command: String?
    }

    static func isTableHeader(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    static func isHooksTableHeader(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[[") else { return false }
        let name = trimmed.dropFirst(2).prefix(while: { $0 != "]" })
        return name.trimmingCharacters(in: .whitespaces) == "hooks"
    }

    /// Splits the file into `[[hooks]]` tables. Throws when the file holds a
    /// top-level `hooks = ...` key, which would conflict with any table.
    static func blocks(in lines: [Substring]) throws -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        var topLevel = true
        for (index, line) in lines.enumerated() {
            if isTableHeader(line) {
                if var open = current {
                    open.lines = open.lines.lowerBound..<index
                    blocks.append(open)
                    current = nil
                }
                topLevel = false
                if isHooksTableHeader(line) {
                    current = Block(lines: index..<(index + 1))
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if topLevel, trimmed.hasPrefix("hooks"),
               trimmed.dropFirst("hooks".count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                throw AgentHooks.SettingsUnreadableError()
            }
            guard current != nil else { continue }
            if let value = value(of: "event", in: trimmed) { current?.event = value }
            if let value = value(of: "command", in: trimmed) { current?.command = value }
        }
        if var open = current {
            open.lines = open.lines.lowerBound..<lines.count
            blocks.append(open)
        }
        return blocks
    }

    /// The string value of `key = "..."` or `key = '...'` on one line.
    static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        let raw = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("'") {
            return String(raw.dropFirst().prefix(while: { $0 != "'" }))
        }
        guard raw.hasPrefix("\"") else { return nil }
        var result = ""
        var escaped = false
        for character in raw.dropFirst() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }

    /// A TOML basic string.
    static func quoted(_ value: String) -> String {
        var result = "\""
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result + "\""
    }

    static func ours(_ block: Block) -> Bool {
        block.command?.contains(tool.marker) ?? false
    }

    static func command(event: String, cliPath: String) -> String {
        AgentHooks.hookCommand(event: event, cliPath: cliPath, format: tool.settingsFormat)
    }

    /// The file with Keepresso's tables removed, plus one blank line of
    /// separation each of them had, so install then remove round-trips.
    static func stripped(_ text: String) throws -> [Substring] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let owned = try blocks(in: lines).filter(ours)
        var drop = IndexSet()
        for block in owned {
            // Only the lines Keepresso writes: the header, its keys, and
            // blanks. A table runs to the next header, so a comment the user
            // put after ours (above their own next table) is theirs to keep.
            // Blank lines go only when the whole table goes, so a comment
            // kept after it stays separated from what precedes it.
            let keepsUserLines = block.lines.contains { !ownedLine(lines[$0]) }
            for index in block.lines where ownedLine(lines[index]) {
                if keepsUserLines, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { continue }
                drop.insert(index)
            }
            // Take one blank separator line before the table with it.
            if block.lines.lowerBound > 0,
               lines[block.lines.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                drop.insert(block.lines.lowerBound - 1)
            }
        }
        return lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    static func ownedLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || isHooksTableHeader(line) { return true }
        return ["event", "matcher", "command", "timeout"].contains { key in
            trimmed.hasPrefix(key)
                && trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
    }

    public static func installHooks(into data: Data?, cliPath: String) throws -> Data {
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        var lines = try stripped(text)
        // Trim trailing blank lines, then append our tables after one.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        var output = lines.joined(separator: "\n")
        for event in tool.events {
            if !output.isEmpty { output += "\n\n" }
            output += """
                [[hooks]]
                event = \(quoted(event))
                command = \(quoted(command(event: event, cliPath: cliPath)))
                timeout = \(tool.settingsFormat.timeout)
                """
        }
        return Data((output + "\n").utf8)
    }

    public static func removeHooks(from data: Data?) throws -> Data {
        guard let data else { return Data() }
        let text = String(decoding: data, as: UTF8.self)
        // Nothing of ours: leave the user's file byte for byte.
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard try blocks(in: all).contains(where: ours) else { return data }
        var lines = try stripped(text)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let output = lines.joined(separator: "\n")
        return Data((output.isEmpty ? "" : output + "\n").utf8)
    }

    public static func inspect(_ data: Data?, cliPath: String) -> AgentHooks.HookInstallReport {
        var report = AgentHooks.HookInstallReport()
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let owned = ((try? blocks(in: lines)) ?? []).filter(ours)
        var byEvent: [String: [String]] = [:]
        for block in owned {
            byEvent[block.event ?? "", default: []].append(block.command ?? "")
        }
        for (event, commands) in byEvent {
            guard tool.events.contains(event) else {
                report.orphaned.insert(event)
                continue
            }
            if commands.count > 1 {
                report.duplicated.insert(event)
            } else if commands[0] != command(event: event, cliPath: cliPath) {
                report.stale.insert(event)
            } else {
                report.healthy.insert(event)
            }
        }
        report.missing = Set(tool.events)
            .subtracting(report.healthy)
            .subtracting(report.duplicated)
            .subtracting(report.stale)
        return report
    }

    public static func hookInstallState(of data: Data?, cliPath: String) -> AgentHooks.HookInstallState {
        guard let data, !data.isEmpty else { return .notInstalled }
        let text = String(decoding: data, as: UTF8.self)
        guard (try? blocks(in: text.split(separator: "\n", omittingEmptySubsequences: false))) != nil else {
            return .unreadable
        }
        let report = inspect(data, cliPath: cliPath)
        if report.isAbsent { return .notInstalled }
        return report.isHealthy ? .installed : .needsRepair(report)
    }
}
