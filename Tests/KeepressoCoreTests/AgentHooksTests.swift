import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Event reduction

@Test func reduceMapsLifecycleEventsToStates() {
    // SessionStart is idle, not working: a freshly opened REPL is waiting
    // for its first prompt and emits no further events until one arrives,
    // so a working record here would hold the trigger for the process's
    // whole lifetime.
    #expect(AgentHooks.reduce(event: "SessionStart", toolName: nil) == .set(.idle, detail: nil))
    #expect(AgentHooks.reduce(event: "UserPromptSubmit", toolName: nil) == .set(.working, detail: nil))
    #expect(AgentHooks.reduce(event: "PostToolUse", toolName: "Bash") == .set(.working, detail: nil))
    #expect(AgentHooks.reduce(event: "Stop", toolName: nil) == .set(.idle, detail: nil))
    #expect(AgentHooks.reduce(event: "SessionEnd", toolName: nil) == .end)
    #expect(AgentHooks.reduce(event: "PermissionRequest", toolName: nil) == .set(.waiting, detail: "waiting-approval"))
    // A permission prompt fires PermissionRequest and a Notification in no
    // guaranteed order; the message keeps the approval marker from being
    // overwritten. Other notifications are the idle nudge.
    #expect(AgentHooks.reduce(event: "Notification", toolName: nil, message: "Claude needs your permission to use Bash")
            == .set(.waiting, detail: "waiting-approval"))
    #expect(AgentHooks.reduce(event: "Notification", toolName: nil, message: "Claude is waiting for your input")
            == .set(.waiting, detail: nil))
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
    // A long model turn emits no events for minutes: an old working record
    // with a live agent stays trusted until Stop or the pid dying ends it.
    let staleLive = AgentHooks.HookRecord(
        sessionId: "stale-live", state: .working, agentPid: 22, updatedAt: now.addingTimeInterval(-600))
    let staleDead = AgentHooks.HookRecord(
        sessionId: "stale-dead", state: .working, agentPid: 33, updatedAt: now.addingTimeInterval(-600))
    let staleNoPid = AgentHooks.HookRecord(
        sessionId: "stale-nopid", state: .working, updatedAt: now.addingTimeInterval(-600))
    // An approval prompt emits no further events however long it sits: an
    // old waiting-approval record with a live agent stays trusted.
    let staleApproval = AgentHooks.HookRecord(
        sessionId: "stale-approval", state: .waiting, detail: "waiting-approval",
        agentPid: 44, updatedAt: now.addingTimeInterval(-600))
    // Idle carries no promise of future events, so it does expire: the
    // transcript + CPU fallbacks take over. The file stays while the agent
    // lives (the session still exists).
    let staleIdle = AgentHooks.HookRecord(
        sessionId: "stale-idle", state: .idle, agentPid: 55, updatedAt: now.addingTimeInterval(-600))
    for record in [fresh, staleLive, staleDead, staleNoPid, staleApproval, staleIdle] {
        AgentHooks.write(record, in: dir)
    }

    let records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { $0 != 33 })
    #expect(records.map(\.sessionId).sorted() == ["fresh", "stale-approval", "stale-live"])

    // The dead and pid-less stale files were cleaned up; the live ones stay.
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
    #expect(remaining == ["fresh.json", "stale-approval.json", "stale-idle.json", "stale-live.json"])
}

@Test func longQuietTurnStaysWorkingWhileTheAgentLives() {
    // The regression this pins: a model turn that thinks for minutes emits
    // no hook events, writes no transcript, and burns no CPU. The last
    // working record must keep the session working anyway, however old,
    // as long as the agent process is alive.
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "s-1", state: .working, agentPid: 100,
            updatedAt: now.addingTimeInterval(-600)),
        in: dir)

    let records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { $0 == 100 })
    let sessions = [AgentSession(pid: 100, agent: "claude", tty: "s003", cpuPercent: 0)]
    let joined = PSAgentActivityMonitor.applyHookRecords(records, to: sessions, cwdOf: { _ in nil }).sessions
    #expect(joined[0].hookState == .working)

    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(state, sample: 0, hookState: joined[0].hookState)
    #expect(state.isWorking)
}

@Test func purgeRecordsRemovesEverythingAndWritesRecover() {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    for id in ["a", "b"] {
        AgentHooks.write(
            AgentHooks.HookRecord(sessionId: id, state: .working, agentPid: 11, updatedAt: now),
            in: dir)
    }

    AgentHooks.purgeRecords(in: dir)
    #expect(AgentHooks.readHookRecords(now: now, in: dir, isAlive: { _ in true }).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: dir.path))

    // A later install starts clean: write recreates the folder.
    AgentHooks.write(
        AgentHooks.HookRecord(sessionId: "c", state: .working, agentPid: 11, updatedAt: now),
        in: dir)
    let records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { _ in true })
    #expect(records.map(\.sessionId) == ["c"])
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
        cwdOf: { $0 == 300 ? "/proj/two" : "/proj/one" }).sessions
    #expect(joined[0].hookState == .working)
    #expect(joined[0].hookDetail == "editing")
    #expect(joined[1].hookState == nil)
    #expect(joined[2].hookState == .waiting)
    #expect(joined[2].origin == .claudeApp)
}

@Test func recordWithoutOriginKeepsTheClassifiedOne() {
    // The ps-scan ancestor walk already named this session; a joined hook
    // record that carries no origin must not erase that.
    var session = AgentSession(pid: 100, agent: "claude", tty: nil, cpuPercent: 1)
    session.origin = .claudeApp
    let records = [hookRecord("a", state: .working, agentPid: 100)]
    let joined = PSAgentActivityMonitor.applyHookRecords(
        records, to: [session], cwdOf: { _ in nil }).sessions
    #expect(joined[0].hookState == .working)
    #expect(joined[0].origin == .claudeApp)
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
        records, to: sessions, cwdOf: { _ in "/shared" }).sessions
    #expect(joined.allSatisfy { $0.hookState == nil })
}

@Test func newestRecordWinsAContestedSession() {
    let sessions = [AgentSession(pid: 100, agent: "claude", tty: "s003", cpuPercent: 1)]
    let records = [
        hookRecord("old", state: .idle, agentPid: 100, age: 90),
        hookRecord("new", state: .working, agentPid: 100, age: 5),
    ]
    let joined = PSAgentActivityMonitor.applyHookRecords(
        records, to: sessions, cwdOf: { _ in nil }).sessions
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

    // A pending approval is mid-task and counts as working; letting it read
    // as idle would flap the trigger through every permission prompt.
    var approval = AgentActivityTrigger.State()
    approval = AgentActivityTrigger.step(
        approval, sample: 0.1, hookState: .waiting, hookDetail: "waiting-approval")
    #expect(approval.isWorking)

    // The idle nudge (a prompt left unanswered) is a session at rest.
    var nudged = AgentActivityTrigger.State()
    nudged = AgentActivityTrigger.step(nudged, sample: 0.1, hookState: .waiting)
    #expect(!nudged.isWorking)

    // Per-rule override: overnight unattended runs can treat waiting as work.
    var overnight = AgentActivityTrigger.State()
    overnight = AgentActivityTrigger.step(
        overnight, sample: 0.1, hookState: .waiting, countWaitingAsWorking: true)
    #expect(overnight.isWorking)
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
    // No bare PATH lookup: a stale hook must not run an unrelated `keepresso`.
    #expect(!command.contains("command -v"))

    // Non-tool events carry no matcher.
    let stop = try #require(hooks["Stop"] as? [[String: Any]])
    #expect(stop[0]["matcher"] == nil)

    #expect(AgentHooks.hookInstallState(of: installed, cliPath: cliPath) == .installed)
    #expect(AgentHooks.hookInstallState(of: nil, cliPath: "/Apps/K/keepresso") == .notInstalled)
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
    #expect(AgentHooks.hookInstallState(of: removed, cliPath: "/Apps/K/keepresso") == .notInstalled)

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

@Test func hookCommandSingleQuotesTheBakedPath() {
    // A quote or backtick in the install path must stay literal: an `sh -c`
    // syntax error exits 2 before the trailing `:` can pin exit 0, and
    // Claude Code treats hook exit 2 as a blocking failure on every tool
    // call.
    let hostile = "/Users/x/My \"Apps\"/`weird`/Keepresso.app/Contents/Helpers/keepresso"
    let command = AgentHooks.hookCommand(event: "Stop", cliPath: hostile)
    #expect(command.hasPrefix("c='/Users/x/My \"Apps\"/`weird`/"))
    #expect(AgentHooks.shellSingleQuoted("it's") == #"'it'\''s'"#)
    #expect(AgentHooks.shellSingleQuoted("/plain/path") == "'/plain/path'")
}

@Test func readSettingsTellsMissingFromUnreadable() throws {
    let manager = FileManager.default
    let dir = manager.temporaryDirectory
        .appendingPathComponent("keepresso-settings-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: dir) }

    // No file yet: nil, safe to start from an empty object.
    #expect(try AgentHooks.readSettings(at: dir.appendingPathComponent("settings.json")) == nil)

    // A readable file comes back verbatim.
    let real = dir.appendingPathComponent("real.json")
    try Data("{}".utf8).write(to: real)
    #expect(try AgentHooks.readSettings(at: real) == Data("{}".utf8))

    // Exists but unreadable (a directory at the path stands in for a
    // permission failure): must throw, never read as "missing", or an
    // install would replace the user's whole settings file.
    #expect(throws: AgentHooks.SettingsUnreadableError.self) {
        try AgentHooks.readSettings(at: dir)
    }
}

@Test func unreadableSettingsAreReportedAndNeverEdited() {
    let broken = Data("{not json at all".utf8)
    #expect(AgentHooks.hookInstallState(of: broken, cliPath: "/Apps/K/keepresso") == .unreadable)
    #expect(throws: AgentHooks.SettingsUnreadableError.self) {
        try AgentHooks.installHooks(into: broken, cliPath: cliPath)
    }
    #expect(throws: AgentHooks.SettingsUnreadableError.self) {
        try AgentHooks.removeHooks(from: broken)
    }
    // A top-level array is valid JSON but not a settings object.
    let array = Data("[1,2,3]".utf8)
    #expect(AgentHooks.hookInstallState(of: array, cliPath: "/Apps/K/keepresso") == .unreadable)
}

@Test func originLabelsReplaceThePidFallback() {
    #expect(AgentSession(
        pid: 9, agent: "claude", tty: nil, cpuPercent: 0, origin: .claudeApp
    ).label == "claude (Claude app)")
    // The origin wins even over a pty: the desktop app allocates one for its
    // embedded session, and "s001" would misread as a plain CLI.
    #expect(AgentSession(
        pid: 9, agent: "claude", tty: "s001", cpuPercent: 0, origin: .claudeApp
    ).label == "claude (Claude app)")
    #expect(AgentSession(
        pid: 9, agent: "claude", tty: nil, cpuPercent: 0, origin: .ide
    ).label == "claude (IDE)")
}

// MARK: - Not losing the user's own hooks

@Test func installKeepsForeignEntriesItCannotParse() throws {
    // A settings file is the user's. An element we don't recognise (a null an
    // editor left behind, a shape a future Claude Code writes) used to make
    // the whole event array fail one cast, fall back to empty, and take every
    // one of their hooks for that event with it.
    let existing = Data("""
    {"hooks":{"PreToolUse":[
        {"matcher":"Bash","hooks":[{"type":"command","command":"my-linter.sh"}]},
        null,
        "a bare string"
    ]}}
    """.utf8)
    let installed = try AgentHooks.installHooks(into: existing, cliPath: "/Apps/K/keepresso")
    let root = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let pre = try #require(hooks["PreToolUse"] as? [Any])
    // Their group, both unreadable elements, and ours: nothing dropped.
    #expect(pre.count == 4)
    let commands = pre.compactMap { ($0 as? [String: Any])?["hooks"] as? [Any] }
        .flatMap { $0 }
        .compactMap { ($0 as? [String: Any])?["command"] as? String }
    #expect(commands.contains("my-linter.sh"))
    #expect(pre.contains { $0 is NSNull })
    #expect(pre.contains { ($0 as? String) == "a bare string" })
}

@Test func reinstallNeverLeavesTwoOfOurHooksOnOneEvent() throws {
    // The duplicate that mattered: an unreadable sibling inside a group used
    // to stop our own entry being stripped, so each re-install appended
    // another copy. The hook then fired once per copy, and remove could not
    // find it either.
    let first = try AgentHooks.installHooks(into: nil, cliPath: "/Apps/K/keepresso")
    // Slip an unreadable sibling in beside our entry.
    var root = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
    var hooks = try #require(root["hooks"] as? [String: Any])
    var stop = try #require(hooks["Stop"] as? [Any])
    var group = try #require(stop[0] as? [String: Any])
    var inner = try #require(group["hooks"] as? [Any])
    inner.append(NSNull())
    group["hooks"] = inner
    stop[0] = group
    hooks["Stop"] = stop
    root["hooks"] = hooks
    let tampered = try JSONSerialization.data(withJSONObject: root)

    func ourCommandCount(_ data: Data) throws -> Int {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        return (hooks["Stop"] as? [Any] ?? []).flatMap { AgentHooks.keepressoCommands(in: $0) }.count
    }
    #expect(try ourCommandCount(tampered) == 1)
    let again = try AgentHooks.installHooks(into: tampered, cliPath: "/Apps/K/keepresso")
    #expect(try ourCommandCount(again) == 1, "a re-install must replace our entry, never add a second")
    // And it must still be removable, with the user's stray element intact.
    let removed = try AgentHooks.removeHooks(from: again)
    #expect(try ourCommandCount(removed) == 0)
    #expect(AgentHooks.hookInstallState(of: removed, cliPath: "/Apps/K/keepresso") == .notInstalled)
}

// MARK: - Install health

@Test func aHealthyInstallIsOnlyHealthyWhenEveryEventIsCurrent() throws {
    let installed = try AgentHooks.installHooks(into: nil, cliPath: cliPath)
    let report = AgentHooks.inspect(installed, cliPath: cliPath)
    #expect(report.isHealthy)
    #expect(!report.isAbsent)
    #expect(report.healthy == Set(AgentHooks.installedEvents))
    #expect(AgentHooks.hookInstallState(of: installed, cliPath: cliPath) == .installed)
}

@Test func aMovedAppIsReportedStaleRatherThanConnected() throws {
    // The quiet failure this exists for: the app moves, the baked absolute
    // path stops resolving, every hook silently no-ops, and the row used to
    // keep saying "connected" forever.
    let installed = try AgentHooks.installHooks(
        into: nil, cliPath: "/Volumes/Old/Keepresso.app/Contents/Helpers/keepresso")
    let report = AgentHooks.inspect(installed, cliPath: cliPath)
    #expect(report.stale == Set(AgentHooks.installedEvents))
    #expect(report.healthy.isEmpty)
    #expect(!report.isHealthy)
    #expect(AgentHooks.hookInstallState(of: installed, cliPath: cliPath) != .installed)
    // Re-installing is the repair, and it fully heals.
    let repaired = try AgentHooks.installHooks(into: installed, cliPath: cliPath)
    #expect(AgentHooks.inspect(repaired, cliPath: cliPath).isHealthy)
}

@Test func aPartialInstallIsNotReportedAsConnected() throws {
    // A settings sync, a hand edit, or a version that grew its event list can
    // leave some events behind. One surviving entry used to read as fully
    // connected.
    let installed = try AgentHooks.installHooks(into: nil, cliPath: cliPath)
    var root = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
    var hooks = try #require(root["hooks"] as? [String: Any])
    let kept = "Stop"
    for event in AgentHooks.installedEvents where event != kept { hooks.removeValue(forKey: event) }
    root["hooks"] = hooks
    let partial = try JSONSerialization.data(withJSONObject: root)

    let report = AgentHooks.inspect(partial, cliPath: cliPath)
    #expect(report.healthy == [kept])
    #expect(report.missing == Set(AgentHooks.installedEvents).subtracting([kept]))
    #expect(!report.isHealthy)
    #expect(!report.isAbsent)
    guard case .needsRepair = AgentHooks.hookInstallState(of: partial, cliPath: cliPath) else {
        Issue.record("a partial install must ask to be repaired, not claim to be connected")
        return
    }
}

@Test func anEntryUnderARetiredEventIsReportedOrphaned() throws {
    // An older version installed events this build no longer uses. They are
    // still in the file and still firing, and a re-install only rewrites the
    // events it knows, so nothing else would ever notice them.
    var root: [String: Any] = ["hooks": [
        "SomeRetiredEvent": [
            ["hooks": [["type": "command",
                        "command": "old-path/keepresso agent-hook SomeRetiredEvent; : # \(AgentHooks.hookMarker)"]]],
        ],
    ]]
    let withOrphan = try JSONSerialization.data(withJSONObject: root)
    let report = AgentHooks.inspect(withOrphan, cliPath: cliPath)
    #expect(report.orphaned == ["SomeRetiredEvent"])
    #expect(!report.isAbsent)
    #expect(!report.isHealthy)
    // Removing still gets rid of it: remove sweeps every event, not just ours.
    let removed = try AgentHooks.removeHooks(from: withOrphan)
    #expect(AgentHooks.inspect(removed, cliPath: cliPath).isAbsent)
    root = [:]
}

@Test func anEmptyOrForeignFileIsAbsentRatherThanBroken() throws {
    #expect(AgentHooks.inspect(nil, cliPath: cliPath).isAbsent)
    #expect(AgentHooks.inspect(Data("{}".utf8), cliPath: cliPath).isAbsent)
    // Someone else's hooks are not ours, and must not read as a broken install.
    let foreign = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"theirs"}]}]}}"#.utf8)
    let report = AgentHooks.inspect(foreign, cliPath: cliPath)
    #expect(report.isAbsent)
    #expect(AgentHooks.hookInstallState(of: foreign, cliPath: cliPath) == .notInstalled)
}

@Test func repairingClearsEverythingItReportsIncludingRetiredEvents() throws {
    // The Repair button just re-installs, so re-installing has to be able to
    // clear every kind of drift the report can raise. An entry left under an
    // event this build no longer installs is still ours and still firing, and
    // if a re-install cannot remove it the row stays "needs repair" forever
    // and the button appears to do nothing.
    let installed = try AgentHooks.installHooks(into: nil, cliPath: cliPath)
    var root = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
    var hooks = try #require(root["hooks"] as? [String: Any])
    hooks["SomeRetiredEvent"] = [
        ["hooks": [["type": "command",
                    "command": "old/keepresso agent-hook SomeRetiredEvent; : # \(AgentHooks.hookMarker)"]]],
    ]
    root["hooks"] = hooks
    let drifted = try JSONSerialization.data(withJSONObject: root)
    #expect(AgentHooks.inspect(drifted, cliPath: cliPath).orphaned == ["SomeRetiredEvent"])

    let repaired = try AgentHooks.installHooks(into: drifted, cliPath: cliPath)
    let after = AgentHooks.inspect(repaired, cliPath: cliPath)
    #expect(after.orphaned.isEmpty, "repair must drop our entries under events we no longer install")
    #expect(after.isHealthy, "after repairing, the report must be clean")
}

@Test func oneRepairPassFixesEveryKindOfDriftAtOnce() throws {
    // Auto-repair tries once per tool per run, so a single re-install has to
    // converge on a healthy file no matter how many things are wrong. This
    // builds a file with all four kinds of drift present together.
    let installed = try AgentHooks.installHooks(into: nil, cliPath: cliPath)
    var root = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
    var hooks = try #require(root["hooks"] as? [String: Any])

    // 1. missing: drop an event entirely.
    hooks.removeValue(forKey: "SessionEnd")
    // 2. stale: rewrite one event's command to an old app location.
    hooks["Stop"] = [["hooks": [["type": "command",
        "command": "/Volumes/Old/keepresso agent-hook Stop; : # \(AgentHooks.hookMarker)"]]]]
    // 3. duplicated: two of ours on one event.
    let dupe: [String: Any] = ["matcher": "*", "hooks": [["type": "command",
        "command": AgentHooks.hookCommand(event: "PreToolUse", cliPath: cliPath)]]]
    var pre = try #require(hooks["PreToolUse"] as? [Any])
    pre.append(dupe)
    hooks["PreToolUse"] = pre
    // 4. orphaned: ours under an event this build no longer installs.
    hooks["SomeRetiredEvent"] = [["hooks": [["type": "command",
        "command": "old/keepresso agent-hook SomeRetiredEvent; : # \(AgentHooks.hookMarker)"]]]]
    // And a foreign hook that must survive all of it.
    hooks["PostToolUse"] = [
        ["hooks": [["type": "command", "command": "their-linter.sh"]]],
    ]
    root["hooks"] = hooks
    let drifted = try JSONSerialization.data(withJSONObject: root)

    let before = AgentHooks.inspect(drifted, cliPath: cliPath)
    #expect(before.missing.contains("SessionEnd"))
    #expect(before.stale == ["Stop"])
    #expect(before.duplicated == ["PreToolUse"])
    #expect(before.orphaned == ["SomeRetiredEvent"])

    // One pass, exactly what auto-repair does.
    let repaired = try AgentHooks.installHooks(into: drifted, cliPath: cliPath)
    #expect(AgentHooks.inspect(repaired, cliPath: cliPath).isHealthy,
            "one repair pass must be enough, because only one is attempted")
    #expect(AgentHooks.hookInstallState(of: repaired, cliPath: cliPath) == .installed)

    // The user's own hook is still there, untouched.
    let out = try #require(try JSONSerialization.jsonObject(with: repaired) as? [String: Any])
    let outHooks = try #require(out["hooks"] as? [String: Any])
    let post = try #require(outHooks["PostToolUse"] as? [Any])
    #expect(post.contains {
        (($0 as? [String: Any])?["hooks"] as? [Any])?.contains {
            ($0 as? [String: Any])?["command"] as? String == "their-linter.sh"
        } ?? false
    })
    // And repairing an already-healthy file changes nothing.
    #expect(try AgentHooks.installHooks(into: repaired, cliPath: cliPath) == repaired)
}
