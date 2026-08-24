import Testing
import Foundation
@testable import KeepressoCore

private let cli = "/Applications/Keepresso.app/Contents/Helpers/keepresso"

private func tempHooksDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-hooks-\(UUID().uuidString)", isDirectory: true)
}

private func processTree(
    _ rows: [(pid: Int32, ppid: Int32, comm: String)]
) -> (parentOf: (Int32) -> Int32?, commandOf: (Int32) -> String?, pathOf: (Int32) -> String?) {
    let parents = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.ppid) })
    let comms = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.comm) })
    return ({ parents[$0] }, { comms[$0] }, { _ in nil })
}

private let grokTree = processTree([
    (pid: 90, ppid: 80, comm: "keepresso"),
    (pid: 80, ppid: 70, comm: "sh"),
    (pid: 70, ppid: 60, comm: "grok"),
    (pid: 60, ppid: 1, comm: "zsh"),
])

private func handle(
    event: String,
    payload: String,
    in dir: URL,
    environment: [String: String] = [:],
    now: Date = Date()
) {
    GrokHooks.handle(
        event: event,
        payloadData: Data(payload.utf8),
        parentPid: 90,
        now: now,
        in: dir,
        parentOf: grokTree.parentOf,
        commandOf: grokTree.commandOf,
        pathOf: grokTree.pathOf,
        environment: environment
    )
}

private func records(in dir: URL, now: Date = Date()) -> [AgentHooks.HookRecord] {
    AgentHooks.readHookRecords(now: now, in: dir, isAlive: { _ in true }, isHostAlive: { _ in true })
}

private func grokRecord(
    sessionId: String = "s-1",
    state: AgentHooks.HookSessionState = .working,
    agent: String? = "grok",
    promptId: String? = nil,
    now: Date = Date()
) -> AgentHooks.HookRecord {
    AgentHooks.HookRecord(
        sessionId: sessionId, state: state, agentPid: 70, agent: agent,
        promptId: promptId, updatedAt: now)
}

// MARK: - Install file

@Test func grokInstallWritesOurFileIdempotentlyWithTimeoutAndNoMatcher() throws {
    let once = try GrokHooks.installHooks(into: nil, cliPath: cli)
    let twice = try GrokHooks.installHooks(into: once, cliPath: cli)
    #expect(once == twice)

    let root = try #require(try JSONSerialization.jsonObject(with: twice) as? [String: Any])
    #expect(Set(root.keys) == ["hooks"])
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(Set(hooks.keys) == Set(GrokHooks.installedEvents))

    for event in GrokHooks.installedEvents {
        let groups = try #require(hooks[event] as? [Any])
        #expect(groups.count == 1)
        let group = try #require(groups[0] as? [String: Any])
        #expect(group["matcher"] == nil)
        let inner = try #require(group["hooks"] as? [Any])
        #expect(inner.count == 1)
        let command = try #require(inner[0] as? [String: Any])
        #expect(command["timeout"] as? Int == 5)
        let line = try #require(command["command"] as? String)
        #expect(line.contains("grok-hook \(event)"))
        #expect(line.contains(GrokHooks.hookMarker))
        #expect(line.hasSuffix(": # \(GrokHooks.hookMarker)") || line.contains("; : # \(GrokHooks.hookMarker)"))
    }
}

@Test func grokReinstallHealsAStaleBakedPath() throws {
    let moved = try GrokHooks.installHooks(
        into: nil, cliPath: "/Volumes/Old/Keepresso.app/Contents/Helpers/keepresso")
    let report = GrokHooks.inspect(moved, cliPath: cli)
    #expect(report.stale == Set(GrokHooks.installedEvents))
    guard case .needsRepair = GrokHooks.hookInstallState(of: moved, cliPath: cli) else {
        Issue.record("a moved app must ask to be repaired")
        return
    }
    let healed = try GrokHooks.installHooks(into: moved, cliPath: cli)
    #expect(GrokHooks.inspect(healed, cliPath: cli).isHealthy)
    #expect(GrokHooks.hookInstallState(of: healed, cliPath: cli) == .installed)
}

@Test func grokHealthReportsMissingDuplicatedStaleAndUnreadable() throws {
    #expect(GrokHooks.hookInstallState(of: nil, cliPath: cli) == .notInstalled)
    #expect(GrokHooks.inspect(nil, cliPath: cli).missing == Set(GrokHooks.installedEvents))

    let healthy = try GrokHooks.installHooks(into: nil, cliPath: cli)
    #expect(GrokHooks.hookInstallState(of: healthy, cliPath: cli) == .installed)

    var root = try #require(try JSONSerialization.jsonObject(with: healthy) as? [String: Any])
    var hooks = try #require(root["hooks"] as? [String: Any])
    let stop = try #require(hooks["Stop"] as? [Any])
    hooks["Stop"] = stop + stop
    root["hooks"] = hooks
    let duplicated = try JSONSerialization.data(withJSONObject: root)
    let dupReport = GrokHooks.inspect(duplicated, cliPath: cli)
    #expect(dupReport.duplicated.contains("Stop"))
    guard case .needsRepair = GrokHooks.hookInstallState(of: duplicated, cliPath: cli) else {
        Issue.record("duplicated Stop must ask to be repaired")
        return
    }

    #expect(GrokHooks.hookInstallState(of: Data("not json".utf8), cliPath: cli) == .unreadable)
    #expect(throws: AgentHooks.SettingsUnreadableError.self) {
        try GrokHooks.installHooks(into: Data("[1]".utf8), cliPath: cli)
    }
}

@Test func grokEventNamesAreSpelledAsGrokMatchesThem() {
    #expect(GrokHooks.installedEvents == [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "Stop", "StopFailure", "StopCancelled",
        "Notification", "SessionEnd",
    ])
    for event in GrokHooks.installedEvents {
        #expect(GrokHooks.reduce(event: event, toolName: nil, notificationType: nil) != nil,
                "\(event) is installed but not reduced")
    }
}

@Test func grokMarkerIsDistinctFromTheOtherTools() {
    #expect(!GrokHooks.hookMarker.contains(AgentHooks.hookMarker))
    #expect(!AgentHooks.hookMarker.contains(GrokHooks.hookMarker))
    #expect(GrokHooks.hookMarker != CursorHooks.hookMarker)
    #expect(GrokHooks.hookMarker != CodexHooks.hookMarker)
    #expect(GrokHooks.hookMarker != AntigravityHooks.hookMarker)
}

@Test func grokHooksURLFollowsGrokHome() {
    #expect(GrokHooks.hooksURL(home: "/Users/x", environment: [:]).path
            == "/Users/x/.grok/hooks/keepresso.json")
    #expect(GrokHooks.hooksURL(home: "/Users/x", environment: ["GROK_HOME": "/tmp/gh"]).path
            == "/tmp/gh/hooks/keepresso.json")
}

// MARK: - Handle

@Test func grokCamelCasePayloadRecords() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(
        event: "PreToolUse",
        payload: #"{"sessionId":"s-1","cwd":"/proj","toolName":"run_terminal_command","promptId":"p1"}"#,
        in: dir)
    let found = records(in: dir)
    #expect(found.count == 1)
    #expect(found[0].sessionId == "s-1")
    #expect(found[0].state == .working)
    #expect(found[0].detail == "running-command")
    #expect(found[0].cwd == "/proj")
    #expect(found[0].agentPid == 70)
    #expect(found[0].agent == "grok")
    #expect(found[0].promptId == "p1")
    #expect(GrokHooks.ownsRecord(found[0]))
}

@Test func grokSnakeCasePayloadRecords() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(
        event: "PreToolUse",
        payload: #"{"session_id":"s-1","cwd":"/proj","tool_name":"search_replace","prompt_id":"p1"}"#,
        in: dir)
    let found = records(in: dir)
    #expect(found.count == 1)
    #expect(found[0].detail == "editing")
    #expect(found[0].promptId == "p1")
}

@Test func grokSessionIdEnvFallback() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(
        event: "UserPromptSubmit",
        payload: #"{"cwd":"/proj"}"#,
        in: dir,
        environment: ["GROK_SESSION_ID": "env-sess"])
    let found = records(in: dir)
    #expect(found.count == 1)
    #expect(found[0].sessionId == "env-sess")
    #expect(found[0].state == .working)
}

@Test func grokSessionStartIsIdle() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(event: "SessionStart", payload: #"{"sessionId":"s-1"}"#, in: dir)
    #expect(records(in: dir).first?.state == .idle)
}

@Test func grokStaleStopCancelledDoesNotIdleTheNewTurn() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    handle(
        event: "UserPromptSubmit",
        payload: #"{"sessionId":"s-1","promptId":"p1"}"#,
        in: dir, now: t0)
    handle(
        event: "UserPromptSubmit",
        payload: #"{"sessionId":"s-1","promptId":"p2"}"#,
        in: dir, now: t0.addingTimeInterval(1))
    handle(
        event: "StopCancelled",
        payload: #"{"sessionId":"s-1","promptId":"p1"}"#,
        in: dir, now: t0.addingTimeInterval(2))
    let afterStale = records(in: dir, now: t0.addingTimeInterval(2))
    #expect(afterStale.first?.state == .working)
    #expect(afterStale.first?.promptId == "p2")

    handle(
        event: "StopCancelled",
        payload: #"{"sessionId":"s-1","promptId":"p2"}"#,
        in: dir, now: t0.addingTimeInterval(3))
    #expect(records(in: dir, now: t0.addingTimeInterval(3)).first?.state == .idle)
}

@Test func grokStopWithoutPromptIdMaySettle() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(
        event: "UserPromptSubmit",
        payload: #"{"sessionId":"s-1","promptId":"p1"}"#,
        in: dir)
    handle(
        event: "Stop",
        payload: #"{"sessionId":"s-1","reason":"shutdown"}"#,
        in: dir)
    #expect(records(in: dir).first?.state == .idle)
}

@Test func grokSubagentTypeWritesNothing() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(
        event: "PreToolUse",
        payload: #"{"sessionId":"s-1","toolName":"read_file","subagentType":"explore"}"#,
        in: dir)
    #expect(records(in: dir).isEmpty)
}

@Test func grokNotificationPermissionPromptIsWaitingApproval() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(
        event: "Notification",
        payload: #"{"sessionId":"s-1","notificationType":"permission_prompt"}"#,
        in: dir)
    let found = records(in: dir)
    #expect(found.first?.state == .waiting)
    #expect(found.first?.detail == "waiting-approval")

    handle(
        event: "Notification",
        payload: #"{"sessionId":"s-1","notificationType":"idle_prompt"}"#,
        in: dir)
    #expect(records(in: dir).first?.state == .waiting)
    #expect(records(in: dir).first?.detail == nil)
}

@Test func grokSessionEndDeletesTheRecord() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(event: "UserPromptSubmit", payload: #"{"sessionId":"s-1"}"#, in: dir)
    #expect(!records(in: dir).isEmpty)
    handle(event: "SessionEnd", payload: #"{"sessionId":"s-1"}"#, in: dir)
    #expect(records(in: dir).isEmpty)
}

@Test func grokUnknownEventWritesNothing() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(event: "SubagentStop", payload: #"{"sessionId":"s-1"}"#, in: dir)
    #expect(records(in: dir).isEmpty)
}

@Test func grokToolNamesMapToDetailTokens() {
    #expect(AgentHooks.detailToken(forTool: "run_terminal_command") == "running-command")
    #expect(AgentHooks.detailToken(forTool: "search_replace") == "editing")
    #expect(AgentHooks.detailToken(forTool: "read_file") == "reading")
    #expect(AgentHooks.detailToken(forTool: "grep") == "searching")
    #expect(AgentHooks.detailToken(forTool: "list_dir") == "searching")
    #expect(AgentHooks.detailToken(forTool: "web_search") == "browsing")
    #expect(AgentHooks.detailToken(forTool: "web_fetch") == "browsing")
    #expect(AgentHooks.detailToken(forTool: "spawn_subagent") == "subagent")
    #expect(AgentHooks.detailToken(forTool: "image_gen") == "tool:image_gen")
}

@Test func agentHookOnAGrokAncestorDoesNotClobberPromptId() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    handle(
        event: "UserPromptSubmit",
        payload: #"{"sessionId":"s-1","promptId":"p2"}"#,
        in: dir, now: t0)
    AgentHooks.handle(
        event: "Stop",
        payloadData: Data(#"{"sessionId":"s-1","promptId":"p1"}"#.utf8),
        parentPid: 90,
        now: t0.addingTimeInterval(1),
        in: dir,
        parentOf: grokTree.parentOf,
        commandOf: grokTree.commandOf,
        pathOf: grokTree.pathOf,
        environment: [:])
    let afterStale = records(in: dir, now: t0.addingTimeInterval(1))
    #expect(afterStale.first?.state == .working)
    #expect(afterStale.first?.promptId == "p2")

    AgentHooks.handle(
        event: "UserPromptSubmit",
        payloadData: Data(#"{"sessionId":"s-1","promptId":"p2"}"#.utf8),
        parentPid: 90,
        now: t0.addingTimeInterval(2),
        in: dir,
        parentOf: grokTree.parentOf,
        commandOf: grokTree.commandOf,
        pathOf: grokTree.pathOf,
        environment: [:])
    let afterSubmit = records(in: dir, now: t0.addingTimeInterval(2))
    #expect(afterSubmit.first?.state == .working)
    #expect(afterSubmit.first?.promptId == "p2")
}

@Test func agentHookOnAGrokAncestorIgnoresSubagentStop() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    handle(
        event: "UserPromptSubmit",
        payload: #"{"sessionId":"s-1","promptId":"p2"}"#,
        in: dir)
    AgentHooks.handle(
        event: "Stop",
        payloadData: Data(#"{"sessionId":"s-1","promptId":"p2","subagentType":"explore"}"#.utf8),
        parentPid: 90,
        now: Date(),
        in: dir,
        parentOf: grokTree.parentOf,
        commandOf: grokTree.commandOf,
        pathOf: grokTree.pathOf,
        environment: [:])
    let found = records(in: dir)
    #expect(found.first?.state == .working)
    #expect(found.first?.promptId == "p2")
}

@Test func grokRecordsSurviveAClaudeUninstallPredicate() throws {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    AgentHooks.write(grokRecord(now: now), in: dir)
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "claude-1", state: .working, agentPid: 11, agent: "claude",
            updatedAt: now),
        in: dir)
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "cursor-1", state: .working, ownerPid: 12, agent: "cursor",
            updatedAt: now),
        in: dir)
    AgentHooks.purgeRecords(in: dir, where: AgentHooks.shouldPurgeOnClaudeUninstall)
    let left = records(in: dir, now: now)
    #expect(Set(left.map(\.sessionId)) == ["s-1", "cursor-1"])
    #expect(GrokHooks.ownsRecord(grokRecord()))
    #expect(!GrokHooks.ownsRecord(grokRecord(agent: "cursor")))
    #expect(!GrokHooks.ownsRecord(grokRecord(agent: nil)))
    #expect(!CursorHooks.ownsRecord(grokRecord()))
}
