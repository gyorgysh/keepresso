import Foundation
import Testing
@testable import KeepressoCore

@Test func ompLifecycleMarksWorkWaitAndEnd() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-hooks-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    OMPHooks.record(event: .sessionStart, sessionId: "one", cwd: "/repo", agentPid: 101, at: now, in: directory)
    #expect(AgentHooks.readRecord(sessionId: "one", in: directory)?.state == .waiting)

    OMPHooks.record(event: .agentStart, sessionId: "one", cwd: "/repo", agentPid: 101, at: now, in: directory)
    #expect(AgentHooks.readRecord(sessionId: "one", in: directory)?.state == .working)

    OMPHooks.record(event: .agentEnd, sessionId: "one", cwd: "/repo", agentPid: 101, at: now, in: directory)
    let waiting = try #require(AgentHooks.readRecord(sessionId: "one", in: directory))
    #expect(waiting.state == .waiting)
    #expect(waiting.detail == "waiting")

    OMPHooks.record(
        event: .agentEnd, sessionId: "one", cwd: "/repo", agentPid: 101,
        willContinue: true, at: now, in: directory)
    #expect(AgentHooks.readRecord(sessionId: "one", in: directory)?.state == .working)

    OMPHooks.record(
        event: .agentEnd, sessionId: "one", cwd: "/repo", agentPid: 101,
        awaitingAsyncWork: true, at: now, in: directory)
    #expect(AgentHooks.readRecord(sessionId: "one", in: directory)?.state == .working)

    OMPHooks.record(event: .sessionEnd, sessionId: "one", cwd: "/repo", agentPid: 101, at: now, in: directory)
    #expect(AgentHooks.readRecord(sessionId: "one", in: directory) == nil)
}

@Test func ompHookResolvesTheLiveAgentAncestorAndFailsOpenForUnknownEvents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-ancestor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let parent: (Int32) -> Int32? = { $0 == 11 ? 22 : 1 }
    let command: (Int32) -> String? = { $0 == 22 ? "omp" : "keepresso" }

    OMPHooks.handle(
        event: "agent-start", sessionId: "live", cwd: "/repo",
        willContinue: false, awaitingAsyncWork: false, parentPid: 11,
        in: directory, parentOf: parent, commandOf: command, pathOf: { _ in nil }, argumentsOf: { _ in nil })
    let record = try #require(AgentHooks.readRecord(sessionId: "live", in: directory))
    #expect(record.agent == "omp")
    #expect(record.agentPid == 22)

    OMPHooks.handle(
        event: "future-event", sessionId: "live", cwd: "/repo",
        willContinue: false, awaitingAsyncWork: false, parentPid: 11,
        in: directory, parentOf: parent, commandOf: command, pathOf: { _ in nil }, argumentsOf: { _ in nil })
    #expect(AgentHooks.readRecord(sessionId: "live", in: directory) == record)
}

@Test func ompHookFindsOMPRunningUnderBunOrNode() throws {
    // A Bun or npm install runs as `bun …/omp` or `node …/omp`: the short
    // command is the runtime, and only argv names OMP.
    for runtime in ["bun", "node"] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent: (Int32) -> Int32? = { [11: 22, 22: 33][$0] ?? 1 }
        let command: (Int32) -> String? = { [11: "keepresso", 22: runtime, 33: "zsh"][$0] }
        let arguments: (Int32) -> String? = {
            $0 == 22 ? "\(runtime) /Users/x/.bun/bin/omp -p hello" : nil
        }
        OMPHooks.handle(
            event: "agent-start", sessionId: "s-\(runtime)", cwd: "/repo",
            willContinue: false, awaitingAsyncWork: false, parentPid: 11,
            in: directory, parentOf: parent, commandOf: command,
            pathOf: { _ in "/Users/x/.bun/bin/\(runtime)" }, argumentsOf: arguments)
        let record = try #require(AgentHooks.readRecord(sessionId: "s-\(runtime)", in: directory))
        #expect(record.agentPid == 22)
        #expect(record.state == .working)
    }
}

@Test func ompHookIgnoresARuntimeRunningSomethingElse() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-other-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    OMPHooks.handle(
        event: "agent-start", sessionId: "other", cwd: "/repo",
        willContinue: false, awaitingAsyncWork: false, parentPid: 11,
        in: directory, parentOf: { $0 == 11 ? 22 : 1 }, commandOf: { $0 == 22 ? "bun" : "keepresso" },
        pathOf: { _ in nil }, argumentsOf: { $0 == 22 ? "bun run dev" : nil })
    #expect(AgentHooks.readRecord(sessionId: "other", in: directory) == nil)
}

@Test func ompExtensionSendsEventsInOrderAndSkipsSubagents() {
    let source = OMPHooks.extensionSource(cliPath: "/Applications/Keepresso.app/Contents/Helpers/keepresso")
    #expect(source.contains("queue = queue.then("))
    #expect(source.contains(#"ctx.agent?.kind !== "sub""#))
    #expect(source.contains(#"const keepresso = "/Applications/Keepresso.app/Contents/Helpers/keepresso";"#))
}

@Test func ompSessionSwitchPathResolvesThePreviousSessionId() {
    let sessionFile = "/Users/x/.omp/agent/sessions/project/2026-11-04T10-30-45-123Z_abc-123.jsonl"
    #expect(OMPHooks.sessionId(fromSessionFile: sessionFile) == "abc-123")
    #expect(OMPHooks.sessionId(fromSessionFile: "/tmp/session-id.jsonl") == "session-id")
    #expect(OMPHooks.sessionId(fromSessionFile: "/tmp/custom_session_id.jsonl") == "custom_session_id")
    #expect(OMPHooks.sessionId(fromSessionFile: "/tmp/not-a-session.txt") == nil)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-switch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    OMPHooks.record(event: .agentStart, sessionId: "abc-123", cwd: "/repo", agentPid: 101, in: directory)
    OMPHooks.handle(
        event: "session-end", sessionId: sessionFile, cwd: "/repo",
        willContinue: false, awaitingAsyncWork: false, parentPid: 1, in: directory)
    #expect(AgentHooks.readRecord(sessionId: "abc-123", in: directory) == nil)
}

@Test func ompSessionsAreStoredIndependentlyAndRemoveOnlyEndedSession() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-sessions-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    OMPHooks.record(event: .agentStart, sessionId: "session-a", cwd: "/a", agentPid: 101, in: directory)
    OMPHooks.record(event: .agentStart, sessionId: "session-b", cwd: "/b", agentPid: 202, in: directory)
    OMPHooks.record(event: .agentEnd, sessionId: "session-b", cwd: "/b", agentPid: 202, in: directory)

    #expect(AgentHooks.readRecord(sessionId: "session-a", in: directory)?.state == .working)
    #expect(AgentHooks.readRecord(sessionId: "session-b", in: directory)?.state == .waiting)

    OMPHooks.record(event: .sessionEnd, sessionId: "session-a", cwd: "/a", agentPid: 101, in: directory)
    #expect(AgentHooks.readRecord(sessionId: "session-a", in: directory) == nil)
    #expect(AgentHooks.readRecord(sessionId: "session-b", in: directory)?.state == .waiting)
}

@Test func deadOmpProcessInvalidatesItsWorkingHookRecord() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-dead-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    OMPHooks.record(event: .agentStart, sessionId: "running", cwd: "/repo", agentPid: 404, at: now, in: directory)

    let records = AgentHooks.readHookRecords(now: now, in: directory, isAlive: { $0 != 404 })
    #expect(records.isEmpty)
}

@Test func ompExtensionInstallIsIdempotentAndRemovePreservesOtherExtensions() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-config-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let other = directory.appendingPathComponent("extensions/other.ts")
    try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("export default () => {};".utf8).write(to: other)

    try OMPHooks.install(cliPath: "/Applications/Keepresso.app/Contents/Helpers/keepresso", agentDirectory: directory)
    let extensionURL = OMPHooks.extensionURL(agentDirectory: directory)
    let installed = try String(contentsOf: extensionURL, encoding: .utf8)
    #expect(installed.contains("KEEPRESSO OMP ACTIVITY EXTENSION"))
    #expect(installed.contains("/Applications/Keepresso.app/Contents/Helpers/keepresso"))
    #expect(installed.contains("session_start"))
    #expect(installed.contains("agent_start"))
    #expect(installed.contains("agent_end"))
    #expect(installed.contains("session_shutdown"))
    #expect(!installed.contains("setInterval"))
    #expect(OMPHooks.installState(cliPath: "/Applications/Keepresso.app/Contents/Helpers/keepresso", agentDirectory: directory) == .installed)

    try OMPHooks.install(cliPath: "/Applications/Keepresso.app/Contents/Helpers/keepresso", agentDirectory: directory)
    #expect(try String(contentsOf: extensionURL, encoding: .utf8) == installed)

    try OMPHooks.remove(agentDirectory: directory)
    #expect(!FileManager.default.fileExists(atPath: extensionURL.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
}

@Test func ompInstallDoesNotOverwriteAnUnownedExtension() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-foreign-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let extensionURL = OMPHooks.extensionURL(agentDirectory: directory)
    try FileManager.default.createDirectory(at: extensionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("export default function other() {}".utf8).write(to: extensionURL)

    #expect(OMPHooks.installState(cliPath: "/keepresso", agentDirectory: directory) == .unreadable)
    #expect(throws: OMPHooks.InstallError.self) {
        try OMPHooks.install(cliPath: "/keepresso", agentDirectory: directory)
    }
    #expect(try String(contentsOf: extensionURL, encoding: .utf8) == "export default function other() {}")
}

@Test func ompEmptyWorkingDirectoryIsStoredAsUnknown() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-cwd-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    OMPHooks.handle(
        event: "agent-start", sessionId: "no-cwd", cwd: "",
        willContinue: false, awaitingAsyncWork: false, parentPid: 11,
        in: directory, parentOf: { $0 == 11 ? 22 : 1 }, commandOf: { $0 == 22 ? "omp" : "keepresso" },
        pathOf: { _ in nil }, argumentsOf: { _ in nil })
    let record = try #require(AgentHooks.readRecord(sessionId: "no-cwd", in: directory))
    #expect(record.cwd == nil)
}

@Test func ompRemoveDropsTheExtensionsFolderOnlyWhenEmpty() throws {
    let agentDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-agent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: agentDirectory) }
    let extensions = OMPHooks.extensionURL(agentDirectory: agentDirectory).deletingLastPathComponent()

    try OMPHooks.install(cliPath: "/tmp/keepresso", agentDirectory: agentDirectory)
    try OMPHooks.remove(agentDirectory: agentDirectory)
    #expect(!FileManager.default.fileExists(atPath: extensions.path))

    try OMPHooks.install(cliPath: "/tmp/keepresso", agentDirectory: agentDirectory)
    let other = extensions.appendingPathComponent("mine.ts")
    try Data("export default () => {}".utf8).write(to: other)
    try OMPHooks.remove(agentDirectory: agentDirectory)
    #expect(FileManager.default.fileExists(atPath: other.path))
}
