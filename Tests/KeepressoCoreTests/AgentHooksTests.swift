import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Event reduction

@Test func reduceMapsLifecycleEventsToStates() {
    #expect(AgentHooks.reduce(event: "SessionStart", toolName: nil) == .set(.working, detail: nil))
    #expect(AgentHooks.reduce(event: "UserPromptSubmit", toolName: nil) == .set(.working, detail: nil))
    #expect(AgentHooks.reduce(event: "PostToolUse", toolName: "Bash") == .set(.working, detail: nil))
    #expect(AgentHooks.reduce(event: "Stop", toolName: nil) == .set(.idle, detail: nil))
    #expect(AgentHooks.reduce(event: "SessionEnd", toolName: nil) == .end)
    #expect(AgentHooks.reduce(event: "PermissionRequest", toolName: nil) == .set(.waiting, detail: "waiting-approval"))
    #expect(AgentHooks.reduce(event: "Notification", toolName: nil) == .set(.waiting, detail: nil))
    // Unknown events write nothing: new Claude Code events can't break us.
    #expect(AgentHooks.reduce(event: "SubagentStop", toolName: nil) == nil)
    #expect(AgentHooks.reduce(event: "SomethingNew", toolName: nil) == nil)
}

@Test func reduceLabelsPreToolUseWithSemanticTokens() {
    func token(_ tool: String?) -> String? {
        guard case .set(.working, let detail)? = AgentHooks.reduce(event: "PreToolUse", toolName: tool) else {
            Issue.record("PreToolUse must map to working")
            return nil
        }
        return detail
    }
    #expect(token("Bash") == "running-command")
    #expect(token("Edit") == "editing")
    #expect(token("Write") == "editing")
    #expect(token("NotebookEdit") == "editing")
    #expect(token("Read") == "reading")
    #expect(token("Grep") == "searching")
    #expect(token("Glob") == "searching")
    #expect(token("Task") == "subagent")
    #expect(token("WebFetch") == "browsing")
    #expect(token("WebSearch") == "browsing")
    #expect(token("SomeMCPTool") == "tool:SomeMCPTool")
    #expect(token("   ") == nil)
    #expect(token(nil) == nil)
}

// MARK: - Payload decoding

@Test func payloadDecodesMinimalAndUnknownFields() throws {
    let minimal = Data(#"{"session_id":"abc"}"#.utf8)
    let decoded = try JSONDecoder().decode(AgentHooks.HookPayload.self, from: minimal)
    #expect(decoded.sessionId == "abc")
    #expect(decoded.cwd == nil)

    let future = Data("""
    {"session_id":"abc","cwd":"/tmp/x","hook_event_name":"PreToolUse",
     "tool_name":"Bash","message":"hi","transcript_path":"/t.jsonl",
     "brand_new_field":{"nested":[1,2,3]},"another":42}
    """.utf8)
    let tolerant = try JSONDecoder().decode(AgentHooks.HookPayload.self, from: future)
    #expect(tolerant.toolName == "Bash")
    #expect(tolerant.cwd == "/tmp/x")
    #expect(tolerant.message == "hi")
}

// MARK: - Ancestor walk and origin

/// Builds parentOf/commandOf closures from a scripted chain of
/// (pid, parent, comm) rows.
private func processTree(
    _ rows: [(pid: Int32, ppid: Int32, comm: String)],
    paths: [Int32: String] = [:]
) -> (parentOf: (Int32) -> Int32?, commandOf: (Int32) -> String?, pathOf: (Int32) -> String?) {
    let parents = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.ppid) })
    let comms = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.comm) })
    return ({ parents[$0] }, { comms[$0] }, { paths[$0] })
}

@Test func ancestorWalkFindsDirectParentAgent() {
    let tree = processTree([
        (pid: 50, ppid: 40, comm: "keepresso"),
        (pid: 40, ppid: 30, comm: "claude"),
        (pid: 30, ppid: 1, comm: "zsh"),
    ])
    let match = AgentHooks.findAgentAncestor(
        startingAt: 50, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf)
    #expect(match?.agentPid == 40)
    #expect(match?.agentCommand == "claude")
    #expect(match?.origin == .terminal)
}

@Test func ancestorWalkClimbsThroughWrappers() {
    // Hook commands run via sh -c, so sh sits between us and the agent.
    let tree = processTree([
        (pid: 60, ppid: 55, comm: "keepresso"),
        (pid: 55, ppid: 40, comm: "sh"),
        (pid: 40, ppid: 35, comm: "node"),
        (pid: 35, ppid: 30, comm: "codex"),
        (pid: 30, ppid: 20, comm: "fish"),
        (pid: 20, ppid: 1, comm: "iTerm2"),
    ])
    let match = AgentHooks.findAgentAncestor(
        startingAt: 60, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf)
    #expect(match?.agentPid == 35)
    #expect(match?.agentCommand == "codex")
    #expect(match?.origin == .terminal)
}

@Test func ancestorWalkClassifiesDesktopAppAndIDE() {
    // Electron comm names truncate at 16 chars.
    let appTree = processTree([
        (pid: 50, ppid: 45, comm: "sh"),
        (pid: 45, ppid: 40, comm: "claude"),
        (pid: 40, ppid: 30, comm: "Claude Helper (R"),
        (pid: 30, ppid: 1, comm: "Claude"),
    ])
    let appMatch = AgentHooks.findAgentAncestor(
        startingAt: 50, parentOf: appTree.parentOf, commandOf: appTree.commandOf, pathOf: appTree.pathOf)
    #expect(appMatch?.agentPid == 45)
    #expect(appMatch?.origin == .claudeApp)

    let ideTree = processTree([
        (pid: 50, ppid: 45, comm: "claude"),
        (pid: 45, ppid: 40, comm: "Code Helper (Plu"),
        (pid: 40, ppid: 1, comm: "Electron"),
    ])
    let ideMatch = AgentHooks.findAgentAncestor(
        startingAt: 50, parentOf: ideTree.parentOf, commandOf: ideTree.commandOf, pathOf: ideTree.pathOf)
    #expect(ideMatch?.origin == .ide)
}

@Test func ancestorWalkMatchesVersionedBinariesByPath() {
    // Claude Code's native install runs `~/.local/share/claude/versions/N.N.N`,
    // so the short comm is a bare version number; the executable path still
    // names the agent.
    let tree = processTree(
        [
            (pid: 50, ppid: 45, comm: "keepresso"),
            (pid: 45, ppid: 40, comm: "zsh"),
            (pid: 40, ppid: 30, comm: "2.1.210"),
            (pid: 30, ppid: 1, comm: "zsh"),
        ],
        paths: [40: "/Users/x/.local/share/claude/versions/2.1.210"])
    let match = AgentHooks.findAgentAncestor(
        startingAt: 50, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf)
    #expect(match?.agentPid == 40)
    #expect(match?.agentCommand == "claude")
    #expect(match?.origin == .terminal)
}

@Test func ancestorWalkOriginIsNilWhenNothingRecognizable() {
    let tree = processTree([
        (pid: 50, ppid: 40, comm: "claude"),
        (pid: 40, ppid: 1, comm: "weirdlauncher"),
    ])
    let match = AgentHooks.findAgentAncestor(
        startingAt: 50, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf)
    #expect(match?.agentPid == 50)
    #expect(match?.origin == nil)
}

@Test func ancestorWalkReturnsNilWithoutAgentAndSurvivesCycles() {
    let noAgent = processTree([
        (pid: 50, ppid: 40, comm: "sh"),
        (pid: 40, ppid: 1, comm: "zsh"),
    ])
    #expect(AgentHooks.findAgentAncestor(
        startingAt: 50, parentOf: noAgent.parentOf, commandOf: noAgent.commandOf, pathOf: noAgent.pathOf) == nil)

    // A pid cycle (raced/reused pids) must terminate, not loop.
    let cycle = processTree([
        (pid: 50, ppid: 40, comm: "sh"),
        (pid: 40, ppid: 50, comm: "sh"),
    ])
    #expect(AgentHooks.findAgentAncestor(
        startingAt: 50, parentOf: cycle.parentOf, commandOf: cycle.commandOf, pathOf: cycle.pathOf) == nil)

    // Deep unmatched chains stop at the depth cap.
    var rows: [(pid: Int32, ppid: Int32, comm: String)] = []
    for pid in Int32(2)...60 { rows.append((pid: pid, ppid: pid - 1, comm: "sh")) }
    let deep = processTree(rows)
    #expect(AgentHooks.findAgentAncestor(
        startingAt: 60, parentOf: deep.parentOf, commandOf: deep.commandOf, pathOf: deep.pathOf) == nil)
}

// MARK: - handle() end to end (temp directory)

private func tempHooksDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-hooks-tests-\(UUID().uuidString)", isDirectory: true)
    return url
}

@Test func handleWritesReadsAndEndsARecord() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tree = processTree([
        (pid: 50, ppid: 40, comm: "sh"),
        (pid: 40, ppid: 30, comm: "claude"),
        (pid: 30, ppid: 1, comm: "zsh"),
    ])
    let payload = Data(#"{"session_id":"s-1","cwd":"/tmp/proj","tool_name":"Bash"}"#.utf8)
    let now = Date()
    AgentHooks.handle(
        event: "PreToolUse", payloadData: payload, parentPid: 50, now: now,
        in: dir, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf)

    var records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { _ in true })
    #expect(records.count == 1)
    #expect(records.first?.sessionId == "s-1")
    #expect(records.first?.state == .working)
    #expect(records.first?.detail == "running-command")
    #expect(records.first?.cwd == "/tmp/proj")
    #expect(records.first?.agentPid == 40)
    #expect(records.first?.origin == .terminal)

    // SessionEnd deletes the file.
    AgentHooks.handle(
        event: "SessionEnd", payloadData: Data(#"{"session_id":"s-1"}"#.utf8), parentPid: 50,
        now: now, in: dir, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf)
    records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { _ in true })
    #expect(records.isEmpty)
}

@Test func handleIgnoresGarbageAndUnknownEvents() {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tree = processTree([(pid: 50, ppid: 1, comm: "sh")])
    // Garbage stdin: no session id, nothing written, no crash.
    AgentHooks.handle(
        event: "PreToolUse", payloadData: Data("not json".utf8), parentPid: 50,
        in: dir, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf)
    // Unknown event: nothing written.
    AgentHooks.handle(
        event: "BrandNewEvent", payloadData: Data(#"{"session_id":"s-9"}"#.utf8), parentPid: 50,
        in: dir, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf)
    #expect(AgentHooks.readHookRecords(now: Date(), in: dir, isAlive: { _ in true }).isEmpty)
}

@Test func hostileSessionIdsCannotEscapeTheDirectory() {
    #expect(AgentHooks.fileName(forSessionId: "../../etc/passwd") == "______etc_passwd.json")
    #expect(AgentHooks.fileName(forSessionId: "") == "session.json")
    #expect(AgentHooks.fileName(forSessionId: "ab12-cd34") == "ab12-cd34.json")
}

// MARK: - Staleness

@Test func staleRecordsAreIgnoredAndDeadOnesDeleted() {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    let fresh = AgentHooks.HookRecord(
        sessionId: "fresh", state: .working, agentPid: 11, updatedAt: now.addingTimeInterval(-30))
    let staleLive = AgentHooks.HookRecord(
        sessionId: "stale-live", state: .working, agentPid: 22, updatedAt: now.addingTimeInterval(-600))
    let staleDead = AgentHooks.HookRecord(
        sessionId: "stale-dead", state: .working, agentPid: 33, updatedAt: now.addingTimeInterval(-600))
    let staleNoPid = AgentHooks.HookRecord(
        sessionId: "stale-nopid", state: .working, updatedAt: now.addingTimeInterval(-600))
    for record in [fresh, staleLive, staleDead, staleNoPid] { AgentHooks.write(record, in: dir) }

    let records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { $0 != 33 })
    #expect(records.map(\.sessionId) == ["fresh"])

    // The dead and pid-less stale files were cleaned up; the live one stays
    // (hooks may be broken mid-session, but the session still exists).
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
    #expect(remaining == ["fresh.json", "stale-live.json"])
}

// MARK: - Joining records onto sessions

private func hookRecord(
    _ sessionId: String, state: AgentHooks.HookSessionState, detail: String? = nil,
    cwd: String? = nil, origin: AgentHooks.HookSessionOrigin? = nil,
    agentPid: Int32? = nil, age: TimeInterval = 0
) -> AgentHooks.HookRecord {
    AgentHooks.HookRecord(
        sessionId: sessionId, state: state, detail: detail, cwd: cwd,
        origin: origin, agentPid: agentPid, updatedAt: Date().addingTimeInterval(-age))
}

@Test func recordsJoinByPidFirstThenUnambiguousCwd() {
    let sessions = [
        AgentSession(pid: 100, agent: "claude", tty: "s003", cpuPercent: 1),
        AgentSession(pid: 200, agent: "claude", tty: "s004", cpuPercent: 1),
        AgentSession(pid: 300, agent: "codex", tty: nil, cpuPercent: 1),
    ]
    let records = [
        hookRecord("a", state: .working, detail: "editing", agentPid: 100),
        // No pid: joins pid 300 through its unique cwd.
        hookRecord("b", state: .waiting, cwd: "/proj/two", origin: .claudeApp),
    ]
    let joined = PSAgentActivityMonitor.applyHookRecords(
        records, to: sessions,
        cwdOf: { $0 == 300 ? "/proj/two" : "/proj/one" })
    #expect(joined[0].hookState == .working)
    #expect(joined[0].hookDetail == "editing")
    #expect(joined[1].hookState == nil)
    #expect(joined[2].hookState == .waiting)
    #expect(joined[2].origin == .claudeApp)
}

@Test func ambiguousCwdFallbackJoinsNothing() {
    // Two sessions in one directory and a pid-less record: joining either
    // would be a guess, so neither gets stamped.
    let sessions = [
        AgentSession(pid: 100, agent: "claude", tty: "s003", cpuPercent: 1),
        AgentSession(pid: 200, agent: "claude", tty: "s004", cpuPercent: 1),
    ]
    let records = [hookRecord("a", state: .working, cwd: "/shared")]
    let joined = PSAgentActivityMonitor.applyHookRecords(
        records, to: sessions, cwdOf: { _ in "/shared" })
    #expect(joined.allSatisfy { $0.hookState == nil })
}

@Test func newestRecordWinsAContestedSession() {
    let sessions = [AgentSession(pid: 100, agent: "claude", tty: "s003", cpuPercent: 1)]
    let records = [
        hookRecord("old", state: .idle, agentPid: 100, age: 90),
        hookRecord("new", state: .working, agentPid: 100, age: 5),
    ]
    let joined = PSAgentActivityMonitor.applyHookRecords(
        records, to: sessions, cwdOf: { _ in nil })
    #expect(joined[0].hookState == .working)
}

// MARK: - Verdict precedence in the trigger step

@Test func hookStateDecidesOutright() {
    // working beats a quiet CPU with no transcript evidence.
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(state, sample: 0.1, hookState: .working)
    #expect(state.isWorking)

    // idle beats a hot CPU and fresh evidence.
    var hot = AgentActivityTrigger.State()
    hot = AgentActivityTrigger.step(hot, sample: 95, freshEvidence: true, hookState: .idle)
    #expect(!hot.isWorking)

    // waiting is not working by default: the human is away.
    var waiting = AgentActivityTrigger.State()
    waiting = AgentActivityTrigger.step(waiting, sample: 95, hookState: .waiting)
    #expect(!waiting.isWorking)
}

@Test func missingHookStateFallsBackToHeuristics() {
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(state, sample: 0.1, freshEvidence: true)
    #expect(state.isWorking)
    var quiet = AgentActivityTrigger.State()
    quiet = AgentActivityTrigger.step(quiet, sample: 0.1)
    #expect(!quiet.isWorking)
}

@Test func emaKeepsWarmingWhileHooksDecide() {
    // The averages advance under a hook verdict, so losing hooks mid-session
    // hands over to a warmed-up CPU fallback, not a cold start.
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(state, sample: 40, hookState: .idle)
    #expect(state.average == 40)
    #expect(state.baseline != nil)
    state = AgentActivityTrigger.step(state, sample: 10, hookState: .idle)
    #expect(state.average == 32.5) // 40 + 0.25 * (10 - 40): still smoothing
}

// MARK: - Row labels

@Test func rowLabelsAppendLocalizedDetails() {
    let working = AgentActivityTrigger.SessionState(
        session: AgentSession(
            pid: 1, agent: "claude", tty: "s003", cpuPercent: 5,
            hookState: .working, hookDetail: "running-command"),
        isWorking: true)
    #expect(AgentActivityTrigger.rowLabel(for: working) == "claude (s003) - running command")

    let waiting = AgentActivityTrigger.SessionState(
        session: AgentSession(
            pid: 1, agent: "claude", tty: "s003", cpuPercent: 0,
            hookState: .waiting, hookDetail: "waiting-approval"),
        isWorking: false)
    #expect(AgentActivityTrigger.rowLabel(for: waiting) == "claude (s003) - waiting for approval")

    // No hook data: the plain label, exactly as before.
    let plain = AgentActivityTrigger.SessionState(
        session: AgentSession(pid: 7, agent: "codex", tty: nil, cpuPercent: 0),
        isWorking: false)
    #expect(AgentActivityTrigger.rowLabel(for: plain) == "codex (pid 7)")

    // Unknown future tokens degrade to the plain label, never crash.
    let unknown = AgentActivityTrigger.SessionState(
        session: AgentSession(
            pid: 1, agent: "claude", tty: "s003", cpuPercent: 5,
            hookState: .working, hookDetail: "mystery-token"),
        isWorking: true)
    #expect(AgentActivityTrigger.rowLabel(for: unknown) == "claude (s003)")
}

// MARK: - settings.json transforms

private let cliPath = "/Applications/Keepresso.app/Contents/Helpers/keepresso"

private func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func installCreatesHooksFromScratch() throws {
    let installed = try AgentHooks.installHooks(into: nil, cliPath: cliPath)
    let root = try json(installed)
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(Set(hooks.keys) == Set(AgentHooks.installedEvents))

    let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(pre.count == 1)
    #expect(pre[0]["matcher"] as? String == "*")
    let entry = try #require((pre[0]["hooks"] as? [[String: Any]])?.first)
    #expect(entry["type"] as? String == "command")
    #expect(entry["timeout"] as? Int == 5)
    let command = try #require(entry["command"] as? String)
    #expect(command.contains(cliPath))
    #expect(command.contains("agent-hook PreToolUse"))
    #expect(command.contains(AgentHooks.hookMarker))
    #expect(command.contains("command -v keepresso"))

    // Non-tool events carry no matcher.
    let stop = try #require(hooks["Stop"] as? [[String: Any]])
    #expect(stop[0]["matcher"] == nil)

    #expect(AgentHooks.hookInstallState(of: installed) == .installed)
    #expect(AgentHooks.hookInstallState(of: nil) == .notInstalled)
}

@Test func installPreservesForeignKeysAndHooksAndIsIdempotent() throws {
    let existing = Data("""
    {
      "model": "opus",
      "permissions": {"allow": ["Bash(ls *)"]},
      "hooks": {
        "PreToolUse": [
          {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-linter.sh"}]}
        ],
        "SessionStart": [
          {"hooks": [{"type": "command", "command": "echo hi"}]}
        ]
      }
    }
    """.utf8)
    let once = try AgentHooks.installHooks(into: existing, cliPath: cliPath)
    let twice = try AgentHooks.installHooks(into: once, cliPath: cliPath)
    #expect(once == twice) // double-install is byte-idempotent

    let root = try json(twice)
    #expect(root["model"] as? String == "opus")
    #expect((root["permissions"] as? [String: Any]) != nil)
    let hooks = try #require(root["hooks"] as? [String: Any])
    let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
    // The foreign linter entry survives next to exactly one of ours.
    #expect(pre.count == 2)
    #expect((pre[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "my-linter.sh")
}

@Test func removeStripsOnlyOurEntriesAndPrunesEmpties() throws {
    let existing = Data("""
    {
      "model": "opus",
      "hooks": {
        "PreToolUse": [
          {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-linter.sh"}]}
        ]
      }
    }
    """.utf8)
    let installed = try AgentHooks.installHooks(into: existing, cliPath: cliPath)
    let removed = try AgentHooks.removeHooks(from: installed)
    let root = try json(removed)
    #expect(root["model"] as? String == "opus")
    let hooks = try #require(root["hooks"] as? [String: Any])
    // Only the foreign PreToolUse group remains; our event keys are pruned.
    #expect(Set(hooks.keys) == ["PreToolUse"])
    let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(pre.count == 1)
    #expect((pre[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "my-linter.sh")
    #expect(AgentHooks.hookInstallState(of: removed) == .notInstalled)

    // Removing from a from-scratch install leaves an empty object: the
    // `hooks` key itself is pruned.
    let scratch = try AgentHooks.installHooks(into: nil, cliPath: cliPath)
    let bare = try json(try AgentHooks.removeHooks(from: scratch))
    #expect(bare["hooks"] == nil)
}

@Test func removeStripsOurCommandFromASharedGroup() throws {
    // A hand-merged group holding a foreign hook and ours: only our command
    // goes, the group and the foreign hook stay.
    let mixed = Data("""
    {
      "hooks": {
        "Stop": [
          {"hooks": [
            {"type": "command", "command": "notify-me.sh"},
            {"type": "command", "command": "x agent-hook Stop; : # __keepresso_hook"}
          ]}
        ]
      }
    }
    """.utf8)
    let removed = try AgentHooks.removeHooks(from: mixed)
    let hooks = try #require(try json(removed)["hooks"] as? [String: Any])
    let stop = try #require(hooks["Stop"] as? [[String: Any]])
    let inner = try #require(stop[0]["hooks"] as? [[String: Any]])
    #expect(inner.count == 1)
    #expect(inner[0]["command"] as? String == "notify-me.sh")
}

@Test func unreadableSettingsAreReportedAndNeverEdited() {
    let broken = Data("{not json at all".utf8)
    #expect(AgentHooks.hookInstallState(of: broken) == .unreadable)
    #expect(throws: AgentHooks.SettingsUnreadableError.self) {
        try AgentHooks.installHooks(into: broken, cliPath: cliPath)
    }
    #expect(throws: AgentHooks.SettingsUnreadableError.self) {
        try AgentHooks.removeHooks(from: broken)
    }
    // A top-level array is valid JSON but not a settings object.
    let array = Data("[1,2,3]".utf8)
    #expect(AgentHooks.hookInstallState(of: array) == .unreadable)
}

@Test func originLabelsReplaceThePidFallback() {
    #expect(AgentSession(
        pid: 9, agent: "claude", tty: nil, cpuPercent: 0, origin: .claudeApp
    ).label == "claude (Claude app)")
    #expect(AgentSession(
        pid: 9, agent: "claude", tty: "s001", cpuPercent: 0, origin: .claudeApp
    ).label == "claude (s001)")
    #expect(AgentSession(
        pid: 9, agent: "claude", tty: nil, cpuPercent: 0, origin: .ide
    ).label == "claude (IDE)")
}
