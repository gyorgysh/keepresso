import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Helpers

private func processTree(
    _ rows: [(pid: Int32, ppid: Int32, comm: String)],
    paths: [Int32: String] = [:]
) -> (parentOf: (Int32) -> Int32?, commandOf: (Int32) -> String?, pathOf: (Int32) -> String?) {
    let parents = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.ppid) })
    let comms = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.comm) })
    return ({ parents[$0] }, { comms[$0] }, { paths[$0] })
}

private func tempHooksDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-desktop-hooks-\(UUID().uuidString)", isDirectory: true)
}

private let desktopCommand =
    "/Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled"

// MARK: - Origin and host classification

@Test func chatGPTCommClassifiesAsIDE() {
    #expect(AgentHooks.origin(forComm: "ChatGPT") == .ide)
    #expect(AgentHooks.origin(forComm: "ChatGPT Helper (R") == .ide)
}

@Test func parseProcArgs2JoinsArgv() {
    var bytes: [CChar] = []
    func appendNUL(_ s: String) {
        bytes.append(contentsOf: s.utf8.map { CChar(bitPattern: $0) })
        bytes.append(0)
    }
    var argc: Int32 = 3
    withUnsafeBytes(of: &argc) { raw in
        bytes.append(contentsOf: raw.map { CChar(bitPattern: $0) })
    }
    appendNUL("/Applications/ChatGPT.app/Contents/Resources/codex")
    bytes.append(0)
    appendNUL("/Applications/ChatGPT.app/Contents/Resources/codex")
    appendNUL("app-server")
    appendNUL("--analytics-default-enabled")
    let joined = bytes.withUnsafeBufferPointer {
        AgentHooks.parseProcArgs2($0.baseAddress!, length: $0.count)
    }
    #expect(joined?.contains("app-server") == true)
    #expect(joined?.contains("--analytics-default-enabled") == true)
}

@Test func codexAppServerIsRecognizedFromArgvNotFromCommAlone() {
    #expect(AgentHooks.isCodexAppServer(comm: "codex", path: nil, arguments: desktopCommand))
    #expect(!AgentHooks.isCodexAppServer(comm: "codex", path: nil, arguments: "/opt/homebrew/bin/codex exec"))
    #expect(!AgentHooks.isCodexAppServer(comm: "codex", path: nil, arguments: nil))
    #expect(PSAgentActivityMonitor.isCodexAppServerCommand(desktopCommand))
    #expect(!PSAgentActivityMonitor.isCodexAppServerCommand("/opt/homebrew/bin/codex exec"))
}

// MARK: - ps scan: evidence-only host

@Test func codexAppServerIsEvidenceOnlyWithZeroCPU() throws {
    typealias Sample = PSAgentActivityMonitor.ProcessSample
    let samples: [Sample] = [
        Sample(pid: 46_974, ppid: 1, pcpu: 12.0, tty: nil, command: desktopCommand),
        Sample(pid: 47_000, ppid: 46_974, pcpu: 40.0, tty: nil, command: "/usr/bin/python3 /tmp/tool.py"),
        Sample(pid: 80, ppid: 1, pcpu: 3.0, tty: "s003", command: "/opt/homebrew/bin/codex"),
    ]
    let sessions = PSAgentActivityMonitor.sessions(from: samples)
    #expect(sessions.count == 2)
    let desktop = try #require(sessions.first { $0.pid == 46_974 })
    #expect(desktop.agent == "codex")
    #expect(desktop.evidenceOnly)
    #expect(desktop.cpuPercent == 0)
    #expect(desktop.origin == .ide)
    let cli = try #require(sessions.first { $0.pid == 80 })
    #expect(!cli.evidenceOnly)
    #expect(abs(cli.cpuPercent - 3.0) < 0.001)
}

@Test func staleIdleOnAppServerDoesNotWorkFromSubtreeCPU() {
    // Report case 2: once the idle verdict ages out, CPU on the shared host
    // must not read as work. evidenceOnly + CPU 0 is that guarantee.
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(
        state, sample: 20, hookState: nil, evidenceOnly: true)
    #expect(!state.isWorking)
}

// MARK: - Hook write: skip app-server, ownerPid on ChatGPT

@Test func desktopHookWritesOwnerPidNotAgentPid() throws {
    let dir = tempHooksDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let tree = processTree([
        (pid: 90, ppid: 80, comm: "keepresso"),
        (pid: 80, ppid: 70, comm: "sh"),
        (pid: 70, ppid: 60, comm: "codex"),
        (pid: 60, ppid: 1, comm: "ChatGPT"),
    ])
    let arguments: [Int32: String] = [70: desktopCommand]
    CodexHooks.handle(
        event: "UserPromptSubmit",
        payloadData: Data(#"{"session_id":"conv-a","cwd":"/proj"}"#.utf8),
        parentPid: 90, now: Date(), in: dir,
        parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf,
        argumentsOf: { arguments[$0] })

    let records = AgentHooks.readHookRecords(
        now: Date(), in: dir, isAlive: { _ in true }, isHostAlive: { $0 == 60 },
        isSharedHostAgent: { $0 == 70 })
    #expect(records.count == 1)
    #expect(records[0].sessionId == "conv-a")
    #expect(records[0].agentPid == nil)
    #expect(records[0].ownerPid == 60)
    #expect(records[0].origin == .ide)
    #expect(records[0].agent == "codex")
    #expect(records[0].state == .working)
}

@Test func dedicatedCodexCLIStillWritesAgentPid() throws {
    let dir = tempHooksDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let tree = processTree([
        (pid: 90, ppid: 80, comm: "keepresso"),
        (pid: 80, ppid: 70, comm: "sh"),
        (pid: 70, ppid: 60, comm: "codex"),
        (pid: 60, ppid: 1, comm: "zsh"),
    ])
    CodexHooks.handle(
        event: "PreToolUse",
        payloadData: Data(#"{"session_id":"s-cli","cwd":"/proj","tool_name":"Bash"}"#.utf8),
        parentPid: 90, now: Date(), in: dir,
        parentOf: tree.parentOf, commandOf: tree.commandOf, pathOf: tree.pathOf,
        argumentsOf: { $0 == 70 ? "/opt/homebrew/bin/codex" : nil })

    let records = AgentHooks.readHookRecords(
        now: Date(), in: dir, isAlive: { $0 == 70 }, isHostAlive: { _ in false })
    #expect(records.count == 1)
    #expect(records[0].agentPid == 70)
    #expect(records[0].ownerPid == nil)
    #expect(records[0].origin == .terminal)
}

// MARK: - Join: conversations stay separate

@Test func twoDesktopConversationsBothSurviveAsHookOnly() throws {
    // Report case 1, after the write-side change: a newer idle chat must not
    // idle a different working chat on the same host.
    let host: Int32 = 60
    let working = AgentHooks.HookRecord(
        sessionId: "still-working", state: .working, origin: .ide,
        ownerPid: host, agent: "codex",
        updatedAt: Date().addingTimeInterval(-10))
    let idle = AgentHooks.HookRecord(
        sessionId: "just-finished", state: .idle, origin: .ide,
        ownerPid: host, agent: "codex",
        updatedAt: Date().addingTimeInterval(-1))
    let process = [
        AgentSession(pid: host, agent: "codex", tty: nil, cpuPercent: 0, origin: .ide, evidenceOnly: true)
    ]
    let join = PSAgentActivityMonitor.applyHookRecords(
        [working, idle], to: process, cwdOf: { _ in nil })
    #expect(join.sessions[0].hookState == nil)
    #expect(join.unclaimed.count == 2)
    let sessions = join.unclaimed.compactMap(PSAgentActivityMonitor.hookOnlySession(from:))
    #expect(sessions.count == 2)
    #expect(sessions.contains { $0.hookState == .working })
    #expect(sessions.contains { $0.hookState == .idle })
    #expect(Set(sessions.map(\.pid)).count == 2)

    var state = AgentActivityTrigger.State()
    let workingSession = try #require(sessions.first { $0.hookState == .working })
    state = AgentActivityTrigger.step(state, sample: 0, hookState: workingSession.hookState)
    #expect(state.isWorking)
}

@Test func leftoverAppServerAgentPidIsNormalizedToOwnerPid() throws {
    // Records written before the fix named the app-server as agentPid.
    // Reading them must not forever-trust that pid, and must not collapse.
    let dir = tempHooksDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    let pid: Int32 = 46_974
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "still-working", state: .working, agentPid: pid, agent: "codex",
            updatedAt: now.addingTimeInterval(-10)),
        in: dir)
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "just-finished", state: .idle, agentPid: pid, agent: "codex",
            updatedAt: now.addingTimeInterval(-1)),
        in: dir)

    let records = AgentHooks.readHookRecords(
        now: now, in: dir, isAlive: { $0 == pid }, isHostAlive: { $0 == pid },
        isSharedHostAgent: { $0 == pid })
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0.agentPid == nil && $0.ownerPid == pid })
    let join = PSAgentActivityMonitor.applyHookRecords(
        records,
        to: [AgentSession(pid: pid, agent: "codex", tty: nil, cpuPercent: 0, evidenceOnly: true)],
        cwdOf: { _ in nil })
    #expect(join.unclaimed.count == 2)
    #expect(join.unclaimed.contains { $0.sessionId == "still-working" && $0.state == .working })
}

// MARK: - Stale policy

@Test func dedicatedCodexCLIKeepsForeverWhileAliveWorking() {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "s-1", state: .working, origin: .terminal,
            agentPid: 100, agent: "codex",
            updatedAt: now.addingTimeInterval(-600)),
        in: dir)
    let records = AgentHooks.readHookRecords(
        now: now, in: dir, isAlive: { $0 == 100 }, isSharedHostAgent: { _ in false })
    #expect(records.map(\.sessionId) == ["s-1"])
    let joined = PSAgentActivityMonitor.applyHookRecords(
        records,
        to: [AgentSession(pid: 100, agent: "codex", tty: "s003", cpuPercent: 0)],
        cwdOf: { _ in nil }).sessions
    #expect(joined[0].hookState == .working)
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(state, sample: 0, hookState: joined[0].hookState)
    #expect(state.isWorking)
}

@Test func staleSharedHostWorkingPastTenMinutesIsDropped() {
    // Report case 3: a missed Stop must not hold for the life of ChatGPT.app.
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "stuck", state: .working, origin: .ide,
            ownerPid: 60, agent: "codex",
            updatedAt: now.addingTimeInterval(-AgentHooks.sharedHostWorkingStaleAfter - 30)),
        in: dir)
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "recent", state: .working, origin: .ide,
            ownerPid: 60, agent: "codex",
            updatedAt: now.addingTimeInterval(-300)),
        in: dir)

    let records = AgentHooks.readHookRecords(
        now: now, in: dir, isAlive: { _ in false }, isHostAlive: { $0 == 60 },
        isSharedHostAgent: { _ in false })
    #expect(records.map(\.sessionId) == ["recent"])
    #expect(!FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("stuck.json").path))
}

@Test func leftoverAppServerWorkingDoesNotTrustForever() {
    let dir = tempHooksDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    let pid: Int32 = 46_974
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "stuck", state: .working, agentPid: pid, agent: "codex",
            updatedAt: now.addingTimeInterval(-AgentHooks.sharedHostWorkingStaleAfter - 30)),
        in: dir)
    let records = AgentHooks.readHookRecords(
        now: now, in: dir, isAlive: { $0 == pid }, isHostAlive: { $0 == pid },
        isSharedHostAgent: { $0 == pid })
    #expect(records.isEmpty)
}

// MARK: - Rollout corroboration

@Test func codexRolloutWriteMatchesSessionIdInFilename() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-rollout-\(UUID().uuidString)", isDirectory: true)
    let day = "2026/08/24"
    let dir = root.appendingPathComponent(".codex/sessions/\(day)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionId = "01a02f9b-23f9-72c1-901b-dc8cf4f6ca3c"
    let matching = dir.appendingPathComponent(
        "rollout-2026-08-24T01-11-31-\(sessionId).jsonl")
    let other = dir.appendingPathComponent(
        "rollout-2026-08-24T01-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
    try Data([1]).write(to: matching)
    try Data([2]).write(to: other)
    let written = Date(timeIntervalSince1970: 1_800_000_000)
    try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: matching.path)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)], ofItemAtPath: other.path)

    // Pin "now" inside that calendar day so today/yesterday lookup hits `day`.
    let now = Date(timeIntervalSince1970: 1_787_529_600) // 2026-08-24 00:00 UTC+0 approx
    let found = PSAgentActivityMonitor.codexRolloutWrite(
        forSessionId: sessionId, home: root.path, now: now)
    #expect(found == written)
    #expect(PSAgentActivityMonitor.codexRolloutWrite(
        forSessionId: "no-such-session", home: root.path, now: now) == nil)
}
