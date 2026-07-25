import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Event safety

@Test func installedEventsAreAllObservationSteps() {
    // The load-bearing invariant of the whole integration. Cursor blocks an
    // action when a hook on a permission step returns empty or unparseable
    // output, and Keepresso's hook command is deliberately inert when the CLI
    // is missing, so installing on one of those steps would deny every tool
    // call in the session.
    for event in CursorHooks.installedEvents {
        #expect(!CursorHooks.permissionEvents.contains(event))
    }
    #expect(!CursorHooks.installedEvents.isEmpty)
}

@Test func hookCommandAnswersBeforeItRisksAnything() {
    let command = CursorHooks.hookCommand(event: "stop", cliPath: "/Apps/K.app/Contents/Helpers/keepresso")
    // The response is printed first, so it is on stdout even if the CLI is
    // gone, wedged, or writes something unexpected.
    #expect(command.hasPrefix("printf '{}'"))
    // Nothing the CLI emits can reach Cursor's parser.
    #expect(command.contains("cursor-hook stop >/dev/null 2>&1"))
    #expect(command.contains(CursorHooks.hookMarker))
    // It must never vote on a permission, in either direction.
    #expect(!command.contains("permission"))
}

// MARK: - Event reduction

@Test func reduceMapsCursorLifecycleEventsToStates() {
    #expect(CursorHooks.reduce(event: "sessionStart", toolName: nil) == .set(.idle, detail: nil))
    #expect(CursorHooks.reduce(event: "beforeSubmitPrompt", toolName: nil) == .set(.working, detail: nil))
    #expect(CursorHooks.reduce(event: "stop", toolName: nil) == .set(.idle, detail: nil))
    #expect(CursorHooks.reduce(event: "sessionEnd", toolName: nil) == .end)
    #expect(CursorHooks.reduce(event: "afterShellExecution", toolName: nil) == .set(.working, detail: "running-command"))
    #expect(CursorHooks.reduce(event: "afterFileEdit", toolName: nil) == .set(.working, detail: "editing"))
    #expect(CursorHooks.reduce(event: "subagentStop", toolName: nil) == .set(.working, detail: "subagent"))
    // Between steps: still working, but no longer on the last tool.
    #expect(CursorHooks.reduce(event: "afterAgentThought", toolName: nil) == .set(.working, detail: nil))
    #expect(CursorHooks.reduce(event: "afterAgentResponse", toolName: nil) == .set(.working, detail: nil))
    // Unmapped events, including every permission step, write nothing.
    #expect(CursorHooks.reduce(event: "preToolUse", toolName: "Shell") == nil)
    #expect(CursorHooks.reduce(event: "beforeShellExecution", toolName: nil) == nil)
    #expect(CursorHooks.reduce(event: "somethingNew", toolName: nil) == nil)
}

@Test func reduceLabelsPostToolUseWithCursorsOwnToolNames() {
    func token(_ tool: String?) -> String? {
        guard case .set(.working, let detail)? = CursorHooks.reduce(event: "postToolUse", toolName: tool) else {
            Issue.record("postToolUse must map to working")
            return nil
        }
        return detail
    }
    // Cursor names its shell tool "Shell", not "Bash".
    #expect(token("Shell") == "running-command")
    #expect(token("Write") == "editing")
    #expect(token("Read") == "reading")
    #expect(token("Grep") == "searching")
    #expect(token("Task") == "subagent")
    // MCP tools arrive prefixed and render under their own name.
    #expect(token("MCP:linear") == "tool:linear")
    #expect(token(nil) == nil)
}

// MARK: - Payload decoding

@Test func cursorPayloadPrefersConversationIdAndFallsBackForCwd() throws {
    let full = Data("""
    {"conversation_id":"conv-1","cwd":"/tmp/x","tool_name":"Shell",
     "workspace_roots":["/tmp/root"],"brand_new":{"a":1}}
    """.utf8)
    let decoded = try JSONDecoder().decode(CursorHooks.HookPayload.self, from: full)
    #expect(decoded.identity == "conv-1")
    #expect(decoded.directory == "/tmp/x")

    // sessionStart carries session_id and workspace_roots instead.
    let start = Data(#"{"session_id":"sess-2","workspace_roots":["/tmp/root"]}"#.utf8)
    let opened = try JSONDecoder().decode(CursorHooks.HookPayload.self, from: start)
    #expect(opened.identity == "sess-2")
    #expect(opened.directory == "/tmp/root")

    // No identity at all: nothing to key a record on.
    let empty = try JSONDecoder().decode(CursorHooks.HookPayload.self, from: Data(#"{}"#.utf8))
    #expect(empty.identity == nil)
}

// MARK: - App host walk

@Test func appHostWalkSkipsTheTransientHookShell() {
    // Cursor spawns each hook through sh -c. That shell exits the moment the
    // hook returns, so anchoring the session to it would drop the record
    // immediately; the walk must climb to the editor itself.
    let rows: [(pid: Int32, ppid: Int32, comm: String)] = [
        (pid: 90, ppid: 80, comm: "keepresso"),
        (pid: 80, ppid: 70, comm: "sh"),
        (pid: 70, ppid: 60, comm: "Cursor Helper (R"),
        (pid: 60, ppid: 1, comm: "Cursor"),
    ]
    let parents = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.ppid) })
    let comms = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.comm) })
    let host = AgentHooks.findAppHost(
        startingAt: 90, parentOf: { parents[$0] }, commandOf: { comms[$0] })
    #expect(host?.hostPid == 70)
    #expect(host?.origin == .ide)

    // A plain terminal session has no app host: it has an agent process
    // instead, which the agent walk finds.
    let shellOnly: [Int32: String] = [90: "keepresso", 80: "sh", 70: "zsh", 60: "login"]
    let shellParents: [Int32: Int32] = [90: 80, 80: 70, 70: 60, 60: 1]
    #expect(AgentHooks.findAppHost(
        startingAt: 90, parentOf: { shellParents[$0] }, commandOf: { shellOnly[$0] }) == nil)
}

// MARK: - Writing records

/// A scripted process tree for the two shapes a Cursor hook runs under.
private func tree(
    _ rows: [(pid: Int32, ppid: Int32, comm: String)], paths: [Int32: String] = [:]
) -> (parentOf: (Int32) -> Int32?, commandOf: (Int32) -> String?, pathOf: (Int32) -> String?) {
    let parents = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.ppid) })
    let comms = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.comm) })
    return ({ parents[$0] }, { comms[$0] }, { paths[$0] })
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cursor-hooks-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func handleAnchorsAnIDESessionToItsEditor() throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // The Cursor app: no process anywhere in the tree names the agent.
    let ide = tree([
        (pid: 90, ppid: 80, comm: "keepresso"),
        (pid: 80, ppid: 70, comm: "sh"),
        (pid: 70, ppid: 60, comm: "Cursor Helper (R"),
        (pid: 60, ppid: 1, comm: "Cursor"),
    ])
    CursorHooks.handle(
        event: "beforeSubmitPrompt",
        payloadData: Data(#"{"conversation_id":"conv-1","workspace_roots":["/proj"]}"#.utf8),
        parentPid: 90, in: dir,
        parentOf: ide.parentOf, commandOf: ide.commandOf, pathOf: ide.pathOf)

    let records = AgentHooks.readHookRecords(
        now: Date(), in: dir, isAlive: { _ in true }, isHostAlive: { _ in true })
    #expect(records.count == 1)
    #expect(records[0].state == .working)
    #expect(records[0].agentPid == nil)
    #expect(records[0].ownerPid == 70)
    #expect(records[0].agent == "cursor")
    #expect(records[0].origin == .ide)
    #expect(records[0].cwd == "/proj")
}

@Test func handleJoinsACLISessionOnItsAgentPid() throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // cursor-agent in a terminal: the real shape, where the agent process is
    // a `node` whose executable path is the only thing naming the tool.
    let cli = tree(
        [
            (pid: 90, ppid: 80, comm: "keepresso"),
            (pid: 80, ppid: 70, comm: "sh"),
            (pid: 70, ppid: 60, comm: "node"),
            (pid: 60, ppid: 1, comm: "zsh"),
        ],
        paths: [70: "/Users/x/.local/share/cursor-agent/versions/2026.07.23/node"])
    CursorHooks.handle(
        event: "postToolUse",
        payloadData: Data(#"{"conversation_id":"conv-2","cwd":"/proj","tool_name":"Shell"}"#.utf8),
        parentPid: 90, in: dir,
        parentOf: cli.parentOf, commandOf: cli.commandOf, pathOf: cli.pathOf)

    let records = AgentHooks.readHookRecords(
        now: Date(), in: dir, isAlive: { _ in true }, isHostAlive: { _ in true })
    #expect(records.count == 1)
    #expect(records[0].agentPid == 70)
    #expect(records[0].agent == "cursor-agent")
    #expect(records[0].ownerPid == nil)
    #expect(records[0].detail == "running-command")
    #expect(records[0].origin == .terminal)
}

@Test func sessionEndDeletesTheRecord() throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let ide = tree([(pid: 90, ppid: 1, comm: "Cursor")])
    let payload = Data(#"{"conversation_id":"conv-3"}"#.utf8)
    CursorHooks.handle(
        event: "beforeSubmitPrompt", payloadData: payload, parentPid: 90, in: dir,
        parentOf: ide.parentOf, commandOf: ide.commandOf, pathOf: ide.pathOf)
    CursorHooks.handle(
        event: "sessionEnd", payloadData: payload, parentPid: 90, in: dir,
        parentOf: ide.parentOf, commandOf: ide.commandOf, pathOf: ide.pathOf)
    #expect(AgentHooks.readHookRecords(
        now: Date(), in: dir, isAlive: { _ in true }, isHostAlive: { _ in true }).isEmpty)
}

// MARK: - Liveness of hook-only sessions

@Test func hookOnlyWorkingRecordSurvivesALongTurnButNotAClosedEditor() throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let start = Date()
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "conv-4", state: .working, ownerPid: 70, agent: "cursor",
            updatedAt: start),
        in: dir)
    // Well past staleAfter: a long model turn emits no hook events at all, so
    // age alone must not end it while the editor is still open.
    let later = start.addingTimeInterval(AgentHooks.staleAfter + 60)
    var records = AgentHooks.readHookRecords(
        now: later, in: dir, isAlive: { _ in false }, isHostAlive: { $0 == 70 })
    #expect(records.count == 1)
    #expect(records[0].state == .working)

    // Editor gone: the record is swept, or it would hold the Mac awake with
    // no session behind it.
    records = AgentHooks.readHookRecords(
        now: later, in: dir, isAlive: { _ in false }, isHostAlive: { _ in false })
    #expect(records.isEmpty)
}

// MARK: - Sessions with no process

@Test func hookOnlyRecordBecomesASessionOnlyWhenItNamesAHost() {
    let hosted = AgentHooks.HookRecord(
        sessionId: "conv-5", state: .working, detail: "editing", cwd: "/proj",
        origin: .ide, ownerPid: 70, agent: "cursor", updatedAt: Date())
    let session = PSAgentActivityMonitor.hookOnlySession(from: hosted)
    #expect(session?.agent == "cursor")
    #expect(session?.hookState == .working)
    #expect(session?.hookDetail == "editing")
    #expect(session?.origin == .ide)
    #expect(session?.cpuPercent == 0)
    // A stand-in pid can never be mistaken for a real one.
    #expect((session?.pid ?? 0) < 0)
    #expect(session?.label == "cursor (IDE)")

    // The ordinary unclaimed record, a CLI session racing the scan, must not
    // invent a row: it has a process, we just missed it this tick.
    let racing = AgentHooks.HookRecord(
        sessionId: "conv-6", state: .working, cwd: "/proj", agentPid: 500,
        agent: "claude", updatedAt: Date())
    #expect(PSAgentActivityMonitor.hookOnlySession(from: racing) == nil)
}

@Test func syntheticPidsAreStableDistinctAndNegative() {
    let a = PSAgentActivityMonitor.syntheticPid(forSessionId: "conv-a")
    let b = PSAgentActivityMonitor.syntheticPid(forSessionId: "conv-b")
    #expect(a == PSAgentActivityMonitor.syntheticPid(forSessionId: "conv-a"))
    #expect(a != b)
    #expect(a < 0 && b < 0)
    #expect(PSAgentActivityMonitor.syntheticPid(forSessionId: "") < 0)
}

@Test func unclaimedRecordsAreReportedSeparatelyFromJoinedOnes() {
    let sessions = [
        AgentSession(pid: 100, agent: "cursor-agent", tty: "s000", cpuPercent: 1)
    ]
    let joined = AgentHooks.HookRecord(
        sessionId: "cli", state: .working, agentPid: 100, agent: "cursor-agent",
        updatedAt: Date())
    let hookOnly = AgentHooks.HookRecord(
        sessionId: "ide", state: .working, origin: .ide, ownerPid: 70, agent: "cursor",
        updatedAt: Date())
    let result = PSAgentActivityMonitor.applyHookRecords(
        [joined, hookOnly], to: sessions, cwdOf: { _ in nil })
    #expect(result.sessions.count == 1)
    #expect(result.sessions[0].hookState == .working)
    #expect(result.unclaimed.count == 1)
    #expect(result.unclaimed[0].sessionId == "ide")

    // With no detected process at all, every record is unclaimed: the Cursor
    // app on its own is exactly this case.
    let noProcesses = PSAgentActivityMonitor.applyHookRecords(
        [hookOnly], to: [], cwdOf: { _ in nil })
    #expect(noProcesses.unclaimed.count == 1)
}

// MARK: - hooks.json editing

@Test func installMergesIntoForeignHooksAndIsIdempotent() throws {
    let existing = Data("""
    {"version":1,"hooks":{"stop":[{"command":"/usr/local/bin/mine"}],
     "beforeShellExecution":[{"command":"/usr/local/bin/guard"}]},"somethingElse":{"a":1}}
    """.utf8)
    let once = try CursorHooks.installHooks(into: existing, cliPath: "/Apps/K/keepresso")
    let twice = try CursorHooks.installHooks(into: once, cliPath: "/Apps/K/keepresso")
    #expect(once == twice)

    let root = try #require(try JSONSerialization.jsonObject(with: twice) as? [String: Any])
    #expect(root["somethingElse"] != nil)
    let hooks = try #require(root["hooks"] as? [String: Any])
    // The user's own stop hook survives beside ours.
    let stop = try #require(hooks["stop"] as? [[String: Any]])
    #expect(stop.count == 2)
    #expect(stop.contains { ($0["command"] as? String) == "/usr/local/bin/mine" })
    // Their permission hook is left exactly as it was: we add nothing there.
    let guarded = try #require(hooks["beforeShellExecution"] as? [[String: Any]])
    #expect(guarded.count == 1)
    #expect(CursorHooks.hookInstallState(of: twice, cliPath: "/Apps/K/keepresso") == .installed)
}

@Test func removeStripsOnlyOurEntries() throws {
    let mine = Data(#"{"version":1,"hooks":{"stop":[{"command":"/usr/local/bin/mine"}]}}"#.utf8)
    let installed = try CursorHooks.installHooks(into: mine, cliPath: "/Apps/K/keepresso")
    let removed = try CursorHooks.removeHooks(from: installed)
    #expect(CursorHooks.hookInstallState(of: removed, cliPath: "/Apps/K/keepresso") == .notInstalled)

    let root = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stop = try #require(hooks["stop"] as? [[String: Any]])
    #expect(stop.count == 1)
    #expect((stop[0]["command"] as? String) == "/usr/local/bin/mine")
}

@Test func installFromNothingWritesAVersionedConfig() throws {
    let fresh = try CursorHooks.installHooks(into: nil, cliPath: "/Apps/K/keepresso")
    let root = try #require(try JSONSerialization.jsonObject(with: fresh) as? [String: Any])
    // Cursor rejects a config with no schema version.
    #expect(root["version"] as? Int == 1)
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(Set(hooks.keys) == Set(CursorHooks.installedEvents))

    // Removing everything we added leaves no empty scaffolding behind.
    let removed = try CursorHooks.removeHooks(from: fresh)
    let bare = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
    #expect(bare["hooks"] == nil)
}

@Test func unreadableConfigIsNeverOverwritten() {
    // A file that exists but isn't a JSON object must throw rather than be
    // treated as absent: an install that mistook it for one would replace the
    // user's whole hook config.
    #expect(throws: AgentHooks.SettingsUnreadableError.self) {
        _ = try CursorHooks.installHooks(into: Data("not json".utf8), cliPath: "/k")
    }
    #expect(CursorHooks.hookInstallState(of: Data("not json".utf8), cliPath: "/Apps/K/keepresso") == .unreadable)
}

// MARK: - Shared record folder

@Test func purgingOneToolsRecordsLeavesTheOthersAlone() {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    AgentHooks.write(
        AgentHooks.HookRecord(sessionId: "c", state: .working, agent: "claude", updatedAt: now),
        in: dir)
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "u", state: .working, ownerPid: 70, agent: "cursor", updatedAt: now),
        in: dir)

    AgentHooks.purgeRecords(in: dir, where: CursorHooks.ownsRecord)
    let left = AgentHooks.readHookRecords(
        now: now, in: dir, isAlive: { _ in true }, isHostAlive: { _ in true })
    #expect(left.count == 1)
    #expect(left[0].agent == "claude")
}

@Test func recordsWrittenBeforeTheAgentFieldCountAsClaudes() {
    // Only Claude Code wrote records before the field existed, so a nameless
    // record must not be swept by a Cursor uninstall.
    let legacy = AgentHooks.HookRecord(sessionId: "old", state: .working, updatedAt: Date())
    #expect(!CursorHooks.ownsRecord(legacy))
}

@Test func cursorInstallKeepsEntriesItCannotParse() throws {
    // Same guarantee as Claude Code's: one unreadable element must not cost
    // the user every hook they had on that event.
    let existing = Data(#"{"version":1,"hooks":{"stop":[{"command":"mine"},"oops",null]}}"#.utf8)
    let installed = try CursorHooks.installHooks(into: existing, cliPath: "/Apps/K/keepresso")
    let root = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stop = try #require(hooks["stop"] as? [Any])
    #expect(stop.count == 4)
    #expect(stop.contains { ($0 as? [String: Any])?["command"] as? String == "mine" })
    #expect(stop.contains { ($0 as? String) == "oops" })
    #expect(stop.contains { $0 is NSNull })
    // Ours is there exactly once, and a re-install keeps it that way.
    func ours(_ d: Data) throws -> Int {
        let r = try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
        let h = try #require(r["hooks"] as? [String: Any])
        return (h["stop"] as? [Any] ?? []).filter { CursorHooks.isKeepresso($0) }.count
    }
    #expect(try ours(installed) == 1)
    #expect(try ours(try CursorHooks.installHooks(into: installed, cliPath: "/Apps/K/keepresso")) == 1)
}
