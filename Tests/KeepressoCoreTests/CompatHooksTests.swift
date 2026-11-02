import Testing
import Foundation
@testable import KeepressoCore

private let cli = "/Applications/Keepresso.app/Contents/Helpers/keepresso"

private func tempHooksDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("compat-hooks-\(UUID().uuidString)", isDirectory: true)
}

private struct Tree {
    var rows: [Int32: (ppid: Int32, comm: String, path: String?, args: String?)]
    var parentOf: (Int32) -> Int32? { { rows[$0]?.ppid } }
    var commandOf: (Int32) -> String? { { rows[$0]?.comm } }
    var pathOf: (Int32) -> String? { { rows[$0]?.path } }
    var argumentsOf: (Int32) -> String? { { rows[$0]?.args } }
}

/// keepresso (90) <- sh (80) <- devin (70) <- devin (60) <- zsh (50), as
/// observed: Devin re-execs itself, and the `ps` scan keeps the outer one.
private let devinTree = Tree(rows: [
    90: (80, "keepresso", nil, nil),
    80: (70, "sh", nil, nil),
    70: (60, "devin", "/Users/me/.local/bin/devin", nil),
    60: (50, "devin", "/Users/me/.local/share/devin/cli/_versions/3000.6.14/bin/devin", nil),
    50: (1, "zsh", nil, nil),
])

/// Qwen runs as `node`, inside a Claude Code terminal.
private let qwenTree = Tree(rows: [
    90: (80, "keepresso", nil, nil),
    80: (70, "sh", nil, nil),
    70: (60, "node", "/Users/me/.local/lib/qwen-code/node/bin/node",
         "/Users/me/.local/lib/qwen-code/node/bin/node /Users/me/.local/lib/qwen-code/lib/cli.js"),
    60: (40, "zsh", nil, nil),
    40: (30, "claude", "/Users/me/.local/bin/claude", nil),
    30: (1, "zsh", nil, nil),
])

private let kimiTree = Tree(rows: [
    90: (80, "keepresso", nil, nil),
    80: (70, "sh", nil, nil),
    70: (60, "kimi-code", "/Users/me/.kimi-code/bin/kimi", nil),
    60: (1, "zsh", nil, nil),
])

private func handle(
    _ tool: CompatHooks.Tool, _ event: String, _ payload: String, tree: Tree, in dir: URL
) {
    CompatHooks.handle(
        tool: tool, event: event, payloadData: Data(payload.utf8), parentPid: 90, in: dir,
        parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf,
        argumentsOf: tree.argumentsOf)
}

@Suite struct CompatHooksTests {

    // MARK: - Reduction

    @Test func lifecycleMapsLikeClaude() {
        func r(_ event: String, tool: String? = nil, type: String? = nil, sub: Bool = false)
            -> AgentHooks.HookEventEffect? {
            CompatHooks.reduce(event: event, toolName: tool, notificationType: type, message: nil, isSubagent: sub)
        }
        #expect(r("SessionStart") == .set(.idle, detail: nil))
        #expect(r("UserPromptSubmit") == .set(.working, detail: nil))
        #expect(r("PreToolUse", tool: "run_shell_command") == .set(.working, detail: "running-command"))
        #expect(r("PreToolUse", tool: "exec") == .set(.working, detail: "running-command"))
        #expect(r("PermissionRequest") == .set(.waiting, detail: "waiting-approval"))
        #expect(r("PermissionResult") == .set(.working, detail: nil))
        #expect(r("Stop") == .set(.idle, detail: nil))
        #expect(r("StopFailure") == .set(.idle, detail: nil))
        #expect(r("Interrupt") == .set(.idle, detail: nil))
        #expect(r("SessionEnd") == .end)
        #expect(r("TodoCreated") == nil)
    }

    @Test func aSubagentStopDoesNotIdleTheParent() {
        #expect(CompatHooks.reduce(
            event: "Stop", toolName: nil, notificationType: nil, message: nil, isSubagent: true) == nil)
        #expect(CompatHooks.reduce(
            event: "PreToolUse", toolName: "read_file", notificationType: nil, message: nil,
            isSubagent: true) == .set(.working, detail: "reading"))
    }

    /// Qwen sends `auth_success` at startup. Recorded as plain waiting, it
    /// would hold the Mac under "count waiting as working".
    @Test func onlyUserFacingNotificationsCount() {
        func n(_ type: String?) -> AgentHooks.HookEventEffect? {
            CompatHooks.reduce(event: "Notification", toolName: nil, notificationType: type, message: nil, isSubagent: false)
        }
        #expect(n("auth_success") == nil)
        #expect(n("permission_prompt") == .set(.waiting, detail: "waiting-approval"))
        #expect(n("idle_prompt") == .set(.waiting, detail: nil))
        #expect(n(nil) == .set(.waiting, detail: nil))
    }

    // MARK: - Handling

    @Test func devinJoinsTheOuterProcessAndFallsBackToItsCwd() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle(.devin, "UserPromptSubmit", #"{"session_id":"tidy-ghost","prompt":"secret"}"#,
               tree: devinTree, in: dir)
        let record = AgentHooks.readRecord(sessionId: "devin-tidy-ghost", in: dir)
        #expect(record?.state == .working)
        #expect(record?.agent == "devin")
        #expect(record?.agentPid == 60)
        #expect(record?.origin == .terminal)
        handle(.devin, "SessionEnd", #"{"session_id":"tidy-ghost"}"#, tree: devinTree, in: dir)
        #expect(AgentHooks.readRecord(sessionId: "devin-tidy-ghost", in: dir) == nil)
    }

    @Test func qwenIsFoundByItsArgvNotTheClaudeAboveIt() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle(.qwen, "PreToolUse", #"{"session_id":"q1","cwd":"/repo","tool_name":"read_file"}"#,
               tree: qwenTree, in: dir)
        let record = AgentHooks.readRecord(sessionId: "qwen-q1", in: dir)
        #expect(record?.agentPid == 70)
        #expect(record?.agent == "qwen")
        #expect(record?.cwd == "/repo")
        #expect(record?.detail == "reading")
    }

    @Test func kimiIsFoundByItsBinaryPath() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle(.kimi, "Stop", #"{"session_id":"session_1","cwd":"/repo"}"#, tree: kimiTree, in: dir)
        let record = AgentHooks.readRecord(sessionId: "kimi-session_1", in: dir)
        #expect(record?.agentPid == 70)
        #expect(record?.state == .idle)
    }

    @Test func aPayloadWithoutASessionWritesNothing() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle(.kimi, "UserPromptSubmit", "{}", tree: kimiTree, in: dir)
        handle(.qwen, "UserPromptSubmit", "garbage", tree: qwenTree, in: dir)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
    }

    @Test func toolsOwnOnlyTheirRecords() {
        let qwen = AgentHooks.HookRecord(sessionId: "qwen-1", state: .working, agent: "qwen", updatedAt: Date())
        let claude = AgentHooks.HookRecord(sessionId: "c", state: .working, agent: "claude", updatedAt: Date())
        #expect(CompatHooks.Tool.qwen.ownsRecord(qwen))
        #expect(!CompatHooks.Tool.devin.ownsRecord(qwen))
        #expect(!AgentHooks.shouldPurgeOnClaudeUninstall(qwen))
        #expect(AgentHooks.shouldPurgeOnClaudeUninstall(claude))
    }

    // MARK: - Ancestor walk

    @Test func onlyADirectSameAgentParentFolds() {
        // claude -> zsh -> claude: a subagent in a shell, not a wrapper.
        let tree = Tree(rows: [
            90: (80, "keepresso", nil, nil),
            80: (70, "claude", nil, nil),
            70: (60, "zsh", nil, nil),
            60: (1, "claude", nil, nil),
        ])
        let match = AgentHooks.findAgentAncestor(
            startingAt: 90, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf)
        #expect(match?.agentPid == 80)
    }

    // MARK: - JSON settings (Qwen, Devin)

    @Test func qwenInstallUsesMillisecondsAndNoMatcher() throws {
        let format = CompatHooks.Tool.qwen.settingsFormat
        let data = try AgentHooks.installHooks(
            into: Data(#"{"model":{"name":"x"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#.utf8),
            cliPath: cli, format: format)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((root["model"] as? [String: Any])?["name"] as? String == "x")
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(format.events))
        let pre = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        #expect(pre["matcher"] == nil)
        let entry = try #require((pre["hooks"] as? [[String: Any]])?.first)
        #expect(entry["timeout"] as? Int == 5000)
        #expect((entry["command"] as? String)?.contains("qwen-hook PreToolUse") == true)
        // The user's own Stop hook survives next to ours.
        #expect((hooks["Stop"] as? [Any])?.count == 2)
        #expect(AgentHooks.hookInstallState(of: data, cliPath: cli, format: format) == .installed)
    }

    @Test func removingQwenLeavesClaudeEntriesAndViceVersa() throws {
        let qwen = CompatHooks.Tool.qwen.settingsFormat
        var data = try AgentHooks.installHooks(into: nil, cliPath: cli)
        data = try AgentHooks.installHooks(into: data, cliPath: cli, format: qwen)
        let withoutQwen = try AgentHooks.removeHooks(from: data, format: qwen)
        #expect(AgentHooks.hookInstallState(of: withoutQwen, cliPath: cli) == .installed)
        #expect(AgentHooks.hookInstallState(of: withoutQwen, cliPath: cli, format: qwen) == .notInstalled)
        let withoutClaude = try AgentHooks.removeHooks(from: data)
        #expect(AgentHooks.hookInstallState(of: withoutClaude, cliPath: cli, format: qwen) == .installed)
    }

    @Test func claudeCommandIsUnchanged() {
        #expect(AgentHooks.hookCommand(event: "Stop", cliPath: "/A")
            == #"c='/A'; [ -x "$c" ] || c=/Applications/Keepresso.app/Contents/Helpers/keepresso; "$c" agent-hook Stop; : # __keepresso_hook"#)
    }

    @Test func devinGetsAStarMatcher() throws {
        let data = try AgentHooks.installHooks(into: nil, cliPath: cli, format: CompatHooks.Tool.devin.settingsFormat)
        let hooks = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: Any])
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.first?["matcher"] as? String == "*")
        #expect(hooks["PostToolUseFailure"] == nil)
    }

    // MARK: - Kimi config.toml

    private let userToml = """
        default_model = "moonshot-ai/kimi-k3"

        [providers.moonshot-ai]
        type = "kimi"

        [[hooks]]
        event = "Stop"
        command = "say done"

        [thinking]
        enabled = true

        """

    @Test func kimiInstallAppendsTablesAndKeepsTheRest() throws {
        let data = try KimiHooksFile.installHooks(into: Data(userToml.utf8), cliPath: cli)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix(userToml.trimmingCharacters(in: .newlines)))
        #expect(text.contains("command = \"say done\""))
        #expect(KimiHooksFile.hookInstallState(of: data, cliPath: cli) == .installed)
        // Round trip: removing ours brings back the user's file.
        let removed = try KimiHooksFile.removeHooks(from: data)
        #expect(String(decoding: removed, as: UTF8.self) == userToml)
    }

    @Test func kimiCommandRoundTripsThroughTomlQuoting() throws {
        let hostile = "/Users/o'brien/\"K\"\\app/keepresso"
        let data = try KimiHooksFile.installHooks(into: nil, cliPath: hostile)
        #expect(KimiHooksFile.hookInstallState(of: data, cliPath: hostile) == .installed)
        guard case .needsRepair(let report) = KimiHooksFile.hookInstallState(of: data, cliPath: cli) else {
            Issue.record("a moved app should read as repairable")
            return
        }
        #expect(report.stale == Set(CompatHooks.Tool.kimi.events))
    }

    @Test func kimiReinstallDoesNotDuplicate() throws {
        let once = try KimiHooksFile.installHooks(into: Data(userToml.utf8), cliPath: cli)
        let twice = try KimiHooksFile.installHooks(into: once, cliPath: cli)
        #expect(once == twice)
    }

    @Test func kimiRemoveWithNothingOursIsByteForByte() throws {
        let original = Data((userToml + "\n\n").utf8)
        #expect(try KimiHooksFile.removeHooks(from: original) == original)
    }

    @Test func kimiInlineHooksArrayIsLeftAlone() {
        let inline = Data("hooks = []\n[thinking]\nenabled = true\n".utf8)
        #expect(KimiHooksFile.hookInstallState(of: inline, cliPath: cli) == .unreadable)
        #expect(throws: AgentHooks.SettingsUnreadableError.self) {
            try KimiHooksFile.installHooks(into: inline, cliPath: cli)
        }
        // A `hooks` key inside some other table is not the top-level array.
        let nested = Data("[thinking]\nhooks = 1\n".utf8)
        #expect(KimiHooksFile.hookInstallState(of: nested, cliPath: cli) == .notInstalled)
    }

    // MARK: - Locations

    @Test func configLocationsHonorOverrides() {
        let home = "/Users/me"
        #expect(CompatHooks.Tool.qwen.configURL(home: home, environment: [:]).path == "/Users/me/.qwen/settings.json")
        #expect(CompatHooks.Tool.qwen.configURL(home: home, environment: ["QWEN_HOME": "/q"]).path == "/q/settings.json")
        #expect(CompatHooks.Tool.devin.configURL(home: home, environment: [:]).path == "/Users/me/.config/devin/config.json")
        #expect(CompatHooks.Tool.devin.configURL(home: home, environment: ["XDG_CONFIG_HOME": "/x"]).path == "/x/devin/config.json")
        #expect(CompatHooks.Tool.kimi.configURL(home: home, environment: [:]).path == "/Users/me/.kimi-code/config.toml")
    }

    @Test func cliParsesTheNewSubcommands() throws {
        #expect(try CLIRequest.parse(["qwen-hook", "Stop"]) == .compatHook(tool: .qwen, event: "Stop"))
        #expect(try CLIRequest.parse(["kimi-hook", "Interrupt"]) == .compatHook(tool: .kimi, event: "Interrupt"))
        #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["devin-hook"]) }
    }
}

@Suite struct ReviewFixTests {
    @Test func wrapperFoldIsOptIn() {
        // codex under `codex app-server`: two processes, not one session.
        let parents: [Int32: Int32] = [90: 80, 80: 70, 70: 60, 60: 1]
        let comms: [Int32: String] = [90: "keepresso", 80: "sh", 70: "codex", 60: "codex"]
        let plain = AgentHooks.findAgentAncestor(
            startingAt: 90, parentOf: { parents[$0] }, commandOf: { comms[$0] }, pathOf: { _ in nil })
        #expect(plain?.agentPid == 70)
        let folded = AgentHooks.findAgentAncestor(
            startingAt: 90, parentOf: { parents[$0] }, commandOf: { comms[$0] }, pathOf: { _ in nil },
            foldsWrapper: true)
        #expect(folded?.agentPid == 60)
    }

    @Test func kimiKeepsUserCommentsAfterOurTables() throws {
        let cli = "/Applications/Keepresso.app/Contents/Helpers/keepresso"
        let installed = String(decoding: try KimiHooksFile.installHooks(into: nil, cliPath: cli), as: UTF8.self)
        let edited = installed + "# my thinking settings\n[thinking]\nenabled = true\n"
        let removed = String(decoding: try KimiHooksFile.removeHooks(from: Data(edited.utf8)), as: UTF8.self)
        #expect(removed.contains("# my thinking settings"))
        #expect(removed.contains("[thinking]"))
        #expect(!removed.contains(CompatHooks.Tool.kimi.marker))
    }

    @Test func hermesPresenceHidesOnlyWhileItsProcessHasATurn() {
        let presence = AgentHooks.HookRecord(
            sessionId: "hermes-host-7", state: .idle, ownerPid: 7, agent: "hermes", updatedAt: Date())
        let turn = AgentHooks.HookRecord(
            sessionId: "hermes-turn-t", state: .working, ownerPid: 7, agent: "hermes", updatedAt: Date())
        let otherHost = AgentHooks.HookRecord(
            sessionId: "hermes-host-8", state: .idle, ownerPid: 8, agent: "hermes", updatedAt: Date())
        #expect(HermesHooks.withoutCoveredPresence([presence]).map(\.sessionId) == ["hermes-host-7"])
        #expect(HermesHooks.withoutCoveredPresence([presence, turn, otherHost]).map(\.sessionId)
            == ["hermes-turn-t", "hermes-host-8"])
    }

    @Test func hermesFilesGoneReadsNotInstalledEvenIfStillEnabled() {
        #expect(HermesHooks.installState(
            files: [:], enabled: true, cliPath: "/x") == .notInstalled)
    }
}

@Suite struct SecondReviewFixTests {
    @Test func hermesFlowStyleConfigCounts() {
        #expect(HermesHooks.isEnabled(inConfig: "plugins: {enabled: [spotify, keepresso], disabled: []}\n"))
        #expect(!HermesHooks.isEnabled(inConfig: "plugins: {disabled: [keepresso], enabled: []}\n"))
    }

    @Test func compatToolsMapBackToTheirRows() {
        for tool in CompatHooks.Tool.allCases {
            #expect(tool.agentTool.compatTool == tool)
        }
    }

    @Test func kimiKeptCommentStaysSeparated() throws {
        let cli = "/Applications/Keepresso.app/Contents/Helpers/keepresso"
        let base = "default_model = \"k\"\n"
        let installed = String(decoding: try KimiHooksFile.installHooks(into: Data(base.utf8), cliPath: cli), as: UTF8.self)
        let edited = installed + "\n# mine\n[thinking]\nenabled = true\n"
        let removed = String(decoding: try KimiHooksFile.removeHooks(from: Data(edited.utf8)), as: UTF8.self)
        #expect(removed.contains("default_model = \"k\"\n\n# mine\n[thinking]"))
    }
}
