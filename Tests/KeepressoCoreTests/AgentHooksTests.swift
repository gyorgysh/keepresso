import Testing
import Foundation
@testable import KeepressoCore


@Test func reduceMapsLifecycleEventsToStates() {
    #expect(AgentHooks.reduce(event: "SessionStart", toolName: nil) == .set(.idle, detail: nil))
    #expect(AgentHooks.reduce(event: "UserPromptSubmit", toolName: nil) == .set(.working, detail: nil))
    #expect(AgentHooks.reduce(event: "PostToolUse", toolName: "Bash") == .set(.working, detail: nil))
    #expect(AgentHooks.reduce(event: "Stop", toolName: nil) == .set(.idle, detail: nil))
    #expect(AgentHooks.reduce(event: "StopFailure", toolName: nil) == .set(.idle, detail: nil))
    #expect(AgentHooks.reduce(event: "SessionEnd", toolName: nil) == .end)
    #expect(AgentHooks.reduce(event: "PermissionRequest", toolName: nil) == .set(.waiting, detail: "waiting-approval"))
    #expect(AgentHooks.reduce(event: "Notification", toolName: nil, message: "Claude needs your permission to use Bash")
            == .set(.waiting, detail: "waiting-approval"))
    #expect(AgentHooks.reduce(event: "Notification", toolName: nil, message: "Claude is waiting for your input")
            == .set(.waiting, detail: nil))
    #expect(AgentHooks.reduce(event: "Notification", toolName: nil) == .set(.waiting, detail: nil))
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

@Test func payloadDecodesGrokCamelCase() throws {
    let grok = Data(#"{"sessionId":"g-1","cwd":"/proj","hookEventName":"pre_tool_use","toolName":"list_dir","transcriptPath":"/t.jsonl"}"#.utf8)
    let decoded = try JSONDecoder().decode(AgentHooks.HookPayload.self, from: grok)
    #expect(decoded.sessionId == "g-1")
    #expect(decoded.cwd == "/proj")
    #expect(decoded.hookEventName == "pre_tool_use")
    #expect(decoded.toolName == "list_dir")
    #expect(decoded.transcriptPath == "/t.jsonl")
}


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

    let cycle = processTree([
        (pid: 50, ppid: 40, comm: "sh"),
        (pid: 40, ppid: 50, comm: "sh"),
    ])
    #expect(AgentHooks.findAgentAncestor(
        startingAt: 50, parentOf: cycle.parentOf, commandOf: cycle.commandOf, pathOf: cycle.pathOf) == nil)

    var rows: [(pid: Int32, ppid: Int32, comm: String)] = []
    for pid in Int32(2)...60 { rows.append((pid: pid, ppid: pid - 1, comm: "sh")) }
    let deep = processTree(rows)
    #expect(AgentHooks.findAgentAncestor(
        startingAt: 60, parentOf: deep.parentOf, commandOf: deep.commandOf, pathOf: deep.pathOf) == nil)
}


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
        in: dir, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf,
        environment: [:])

    var records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { _ in true })
    #expect(records.count == 1)
    #expect(records.first?.sessionId == "s-1")
    #expect(records.first?.state == .working)
    #expect(records.first?.detail == "running-command")
    #expect(records.first?.cwd == "/tmp/proj")
    #expect(records.first?.agentPid == 40)
    #expect(records.first?.origin == .terminal)

    AgentHooks.handle(
        event: "SessionEnd", payloadData: Data(#"{"session_id":"s-1"}"#.utf8), parentPid: 50,
        now: now, in: dir, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf,
        environment: [:])
    records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { _ in true })
    #expect(records.isEmpty)
}

@Test func handleFallsBackToGrokSessionIdEnv() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tree = processTree([
        (pid: 50, ppid: 40, comm: "sh"),
        (pid: 40, ppid: 30, comm: "grok"),
        (pid: 30, ppid: 1, comm: "zsh"),
    ])
    AgentHooks.handle(
        event: "UserPromptSubmit",
        payloadData: Data(#"{}"#.utf8),
        parentPid: 50, now: Date(),
        in: dir, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf,
        environment: ["GROK_SESSION_ID": "env-sess"])
    let records = AgentHooks.readHookRecords(now: Date(), in: dir, isAlive: { _ in true })
    #expect(records.count == 1)
    #expect(records.first?.sessionId == "env-sess")
    #expect(records.first?.state == .working)
    #expect(records.first?.agentPid == 40)
}

@Test func handleIgnoresGarbageAndUnknownEvents() {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tree = processTree([(pid: 50, ppid: 1, comm: "sh")])
    AgentHooks.handle(
        event: "PreToolUse", payloadData: Data("not json".utf8), parentPid: 50,
        in: dir, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf,
        environment: [:])
    AgentHooks.handle(
        event: "BrandNewEvent", payloadData: Data(#"{"session_id":"s-9"}"#.utf8), parentPid: 50,
        in: dir, parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf,
        environment: [:])
    #expect(AgentHooks.readHookRecords(now: Date(), in: dir, isAlive: { _ in true }).isEmpty)
}

@Test func hostileSessionIdsCannotEscapeTheDirectory() {
    #expect(AgentHooks.fileName(forSessionId: "../../etc/passwd") == "______etc_passwd.json")
    #expect(AgentHooks.fileName(forSessionId: "") == "session.json")
    #expect(AgentHooks.fileName(forSessionId: "ab12-cd34") == "ab12-cd34.json")
}


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
    let staleApproval = AgentHooks.HookRecord(
        sessionId: "stale-approval", state: .waiting, detail: "waiting-approval",
        agentPid: 44, updatedAt: now.addingTimeInterval(-600))
    let staleIdle = AgentHooks.HookRecord(
        sessionId: "stale-idle", state: .idle, agentPid: 55, updatedAt: now.addingTimeInterval(-600))
    for record in [fresh, staleLive, staleDead, staleNoPid, staleApproval, staleIdle] {
        AgentHooks.write(record, in: dir)
    }

    let records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { $0 != 33 })
    #expect(records.map(\.sessionId).sorted() == ["fresh", "stale-approval", "stale-live"])

    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
    #expect(remaining == ["fresh.json", "stale-approval.json", "stale-idle.json", "stale-live.json"])
}

@Test func longQuietTurnStaysWorkingWhileTheAgentLives() {
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

@Test func staleOwnerPidWorkingDoesNotHoldWhileStaleAgentPidDoes() {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "ide-stuck", state: .working, origin: .ide,
            ownerPid: 900, agent: "cursor",
            updatedAt: now.addingTimeInterval(-AgentHooks.staleAfter - 30)),
        in: dir)
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "cli-quiet", state: .working, origin: .terminal,
            agentPid: 100, agent: "claude",
            updatedAt: now.addingTimeInterval(-AgentHooks.staleAfter - 30)),
        in: dir)
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "ide-fresh", state: .working, origin: .ide,
            ownerPid: 900, agent: "cursor", updatedAt: now),
        in: dir)

    let records = AgentHooks.readHookRecords(
        now: now, in: dir, isAlive: { $0 == 100 }, isHostAlive: { $0 == 900 })
    #expect(Set(records.map(\.sessionId)) == ["cli-quiet", "ide-fresh"])
    #expect(!FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("ide-stuck.json").path))
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

    AgentHooks.write(
        AgentHooks.HookRecord(sessionId: "c", state: .working, agentPid: 11, updatedAt: now),
        in: dir)
    let records = AgentHooks.readHookRecords(now: now, in: dir, isAlive: { _ in true })
    #expect(records.map(\.sessionId) == ["c"])
}


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
    var session = AgentSession(pid: 100, agent: "claude", tty: nil, cpuPercent: 1)
    session.origin = .claudeApp
    let records = [hookRecord("a", state: .working, agentPid: 100)]
    let joined = PSAgentActivityMonitor.applyHookRecords(
        records, to: [session], cwdOf: { _ in nil }).sessions
    #expect(joined[0].hookState == .working)
    #expect(joined[0].origin == .claudeApp)
}

@Test func ambiguousCwdFallbackJoinsNothing() {
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

@Test func ownerPidRecordsDoNotCwdJoinOntoProcessSessions() throws {
    let sessions = [
        AgentSession(pid: 100, agent: "claude", tty: "s003", cpuPercent: 40),
    ]
    let ideIdle = AgentHooks.HookRecord(
        sessionId: "conv-ide", state: .idle, cwd: "/Users/x/proj",
        origin: .ide, ownerPid: 900, agent: "cursor",
        updatedAt: Date())
    let join = PSAgentActivityMonitor.applyHookRecords(
        [ideIdle], to: sessions, cwdOf: { _ in "/Users/x/proj" })
    #expect(join.sessions[0].hookState == nil)
    #expect(join.sessions[0].cpuPercent == 40)
    #expect(join.unclaimed.count == 1)
    #expect(join.unclaimed[0].sessionId == "conv-ide")
    let hookOnly = try #require(PSAgentActivityMonitor.hookOnlySession(from: join.unclaimed[0]))
    #expect(hookOnly.hookState == .idle)
}


@Test func hookStateDecidesOutright() {
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(state, sample: 0.1, hookState: .working)
    #expect(state.isWorking)

    var hot = AgentActivityTrigger.State()
    hot = AgentActivityTrigger.step(hot, sample: 95, freshEvidence: true, hookState: .idle)
    #expect(!hot.isWorking)

    var approval = AgentActivityTrigger.State()
    approval = AgentActivityTrigger.step(
        approval, sample: 0.1, hookState: .waiting, hookDetail: "waiting-approval")
    #expect(approval.isWorking)

    var nudged = AgentActivityTrigger.State()
    nudged = AgentActivityTrigger.step(nudged, sample: 0.1, hookState: .waiting)
    #expect(!nudged.isWorking)

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
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(state, sample: 40, hookState: .idle)
    #expect(state.average == 40)
    #expect(state.baseline != nil)
    state = AgentActivityTrigger.step(state, sample: 10, hookState: .idle)
    #expect(state.average == 32.5)
}


@Test func rowLabelsAppendLocalizedDetails() {
    let working = AgentActivityTrigger.SessionState(
        session: AgentSession(
            pid: 1, agent: "claude", tty: "s003", cpuPercent: 5,
            hookState: .working, hookDetail: "running-command"),
        isWorking: true)
    #expect(AgentActivityTrigger.rowLabel(for: working) == "claude (s003) - run")

    let waiting = AgentActivityTrigger.SessionState(
        session: AgentSession(
            pid: 1, agent: "claude", tty: "s003", cpuPercent: 0,
            hookState: .waiting, hookDetail: "waiting-approval"),
        isWorking: false)
    #expect(AgentActivityTrigger.rowLabel(for: waiting) == "claude (s003) - permission")

    let reading = AgentActivityTrigger.SessionState(
        session: AgentSession(
            pid: 1, agent: "claude", tty: "s003", cpuPercent: 5,
            hookState: .working, hookDetail: "reading"),
        isWorking: true)
    #expect(AgentActivityTrigger.rowLabel(for: reading) == "claude (s003) - read")

    let tool = AgentActivityTrigger.SessionState(
        session: AgentSession(
            pid: 1, agent: "claude", tty: "s003", cpuPercent: 5,
            hookState: .working, hookDetail: "tool:SomeMCPTool"),
        isWorking: true)
    #expect(AgentActivityTrigger.rowLabel(for: tool) == "claude (s003) - tool")

    let plain = AgentActivityTrigger.SessionState(
        session: AgentSession(pid: 7, agent: "codex", tty: nil, cpuPercent: 0),
        isWorking: false)
    #expect(AgentActivityTrigger.rowLabel(for: plain) == "codex (pid 7)")

    let unknown = AgentActivityTrigger.SessionState(
        session: AgentSession(
            pid: 1, agent: "claude", tty: "s003", cpuPercent: 5,
            hookState: .working, hookDetail: "mystery-token"),
        isWorking: true)
    #expect(AgentActivityTrigger.rowLabel(for: unknown) == "claude (s003)")
}


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
    #expect(!command.contains("command -v"))

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
    #expect(once == twice)

    let root = try json(twice)
    #expect(root["model"] as? String == "opus")
    #expect((root["permissions"] as? [String: Any]) != nil)
    let hooks = try #require(root["hooks"] as? [String: Any])
    let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
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
    #expect(Set(hooks.keys) == ["PreToolUse"])
    let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(pre.count == 1)
    #expect((pre[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "my-linter.sh")
    #expect(AgentHooks.hookInstallState(of: removed, cliPath: "/Apps/K/keepresso") == .notInstalled)

    let scratch = try AgentHooks.installHooks(into: nil, cliPath: cliPath)
    let bare = try json(try AgentHooks.removeHooks(from: scratch))
    #expect(bare["hooks"] == nil)
}

@Test func removeStripsOurCommandFromASharedGroup() throws {
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

    #expect(try AgentHooks.readSettings(at: dir.appendingPathComponent("settings.json")) == nil)

    let real = dir.appendingPathComponent("real.json")
    try Data("{}".utf8).write(to: real)
    #expect(try AgentHooks.readSettings(at: real) == Data("{}".utf8))

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
    let array = Data("[1,2,3]".utf8)
    #expect(AgentHooks.hookInstallState(of: array, cliPath: "/Apps/K/keepresso") == .unreadable)
}

@Test func originLabelsReplaceThePidFallback() {
    #expect(AgentSession(
        pid: 9, agent: "claude", tty: nil, cpuPercent: 0, origin: .claudeApp
    ).label == "claude (Claude app)")
    #expect(AgentSession(
        pid: 9, agent: "claude", tty: "s001", cpuPercent: 0, origin: .claudeApp
    ).label == "claude (Claude app)")
    #expect(AgentSession(
        pid: 9, agent: "claude", tty: nil, cpuPercent: 0, origin: .ide
    ).label == "claude (IDE)")
}


@Test func installKeepsForeignEntriesItCannotParse() throws {
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
    #expect(pre.count == 4)
    let commands = pre.compactMap { ($0 as? [String: Any])?["hooks"] as? [Any] }
        .flatMap { $0 }
        .compactMap { ($0 as? [String: Any])?["command"] as? String }
    #expect(commands.contains("my-linter.sh"))
    #expect(pre.contains { $0 is NSNull })
    #expect(pre.contains { ($0 as? String) == "a bare string" })
}

@Test func reinstallNeverLeavesTwoOfOurHooksOnOneEvent() throws {
    let first = try AgentHooks.installHooks(into: nil, cliPath: "/Apps/K/keepresso")
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
    let removed = try AgentHooks.removeHooks(from: again)
    #expect(try ourCommandCount(removed) == 0)
    #expect(AgentHooks.hookInstallState(of: removed, cliPath: "/Apps/K/keepresso") == .notInstalled)
}


@Test func aHealthyInstallIsOnlyHealthyWhenEveryEventIsCurrent() throws {
    let installed = try AgentHooks.installHooks(into: nil, cliPath: cliPath)
    let report = AgentHooks.inspect(installed, cliPath: cliPath)
    #expect(report.isHealthy)
    #expect(!report.isAbsent)
    #expect(report.healthy == Set(AgentHooks.installedEvents))
    #expect(AgentHooks.hookInstallState(of: installed, cliPath: cliPath) == .installed)
}

@Test func aMovedAppIsReportedStaleRatherThanConnected() throws {
    let installed = try AgentHooks.installHooks(
        into: nil, cliPath: "/Volumes/Old/Keepresso.app/Contents/Helpers/keepresso")
    let report = AgentHooks.inspect(installed, cliPath: cliPath)
    #expect(report.stale == Set(AgentHooks.installedEvents))
    #expect(report.healthy.isEmpty)
    #expect(!report.isHealthy)
    #expect(AgentHooks.hookInstallState(of: installed, cliPath: cliPath) != .installed)
    let repaired = try AgentHooks.installHooks(into: installed, cliPath: cliPath)
    #expect(AgentHooks.inspect(repaired, cliPath: cliPath).isHealthy)
}

@Test func aPartialInstallIsNotReportedAsConnected() throws {
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
    let removed = try AgentHooks.removeHooks(from: withOrphan)
    #expect(AgentHooks.inspect(removed, cliPath: cliPath).isAbsent)
    root = [:]
}

@Test func anEmptyOrForeignFileIsAbsentRatherThanBroken() throws {
    #expect(AgentHooks.inspect(nil, cliPath: cliPath).isAbsent)
    #expect(AgentHooks.inspect(Data("{}".utf8), cliPath: cliPath).isAbsent)
    let foreign = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"theirs"}]}]}}"#.utf8)
    let report = AgentHooks.inspect(foreign, cliPath: cliPath)
    #expect(report.isAbsent)
    #expect(AgentHooks.hookInstallState(of: foreign, cliPath: cliPath) == .notInstalled)
}

@Test func repairingClearsEverythingItReportsIncludingRetiredEvents() throws {
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
    let installed = try AgentHooks.installHooks(into: nil, cliPath: cliPath)
    var root = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
    var hooks = try #require(root["hooks"] as? [String: Any])

    hooks.removeValue(forKey: "SessionEnd")
    hooks["Stop"] = [["hooks": [["type": "command",
        "command": "/Volumes/Old/keepresso agent-hook Stop; : # \(AgentHooks.hookMarker)"]]]]
    let dupe: [String: Any] = ["matcher": "*", "hooks": [["type": "command",
        "command": AgentHooks.hookCommand(event: "PreToolUse", cliPath: cliPath)]]]
    var pre = try #require(hooks["PreToolUse"] as? [Any])
    pre.append(dupe)
    hooks["PreToolUse"] = pre
    hooks["SomeRetiredEvent"] = [["hooks": [["type": "command",
        "command": "old/keepresso agent-hook SomeRetiredEvent; : # \(AgentHooks.hookMarker)"]]]]
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

    let repaired = try AgentHooks.installHooks(into: drifted, cliPath: cliPath)
    #expect(AgentHooks.inspect(repaired, cliPath: cliPath).isHealthy,
            "one repair pass must be enough, because only one is attempted")
    #expect(AgentHooks.hookInstallState(of: repaired, cliPath: cliPath) == .installed)

    let out = try #require(try JSONSerialization.jsonObject(with: repaired) as? [String: Any])
    let outHooks = try #require(out["hooks"] as? [String: Any])
    let post = try #require(outHooks["PostToolUse"] as? [Any])
    #expect(post.contains {
        (($0 as? [String: Any])?["hooks"] as? [Any])?.contains {
            ($0 as? [String: Any])?["command"] as? String == "their-linter.sh"
        } ?? false
    })
    #expect(try AgentHooks.installHooks(into: repaired, cliPath: cliPath) == repaired)
}
