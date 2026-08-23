import Testing
import Foundation
@testable import KeepressoCore

private typealias Sample = PSAgentActivityMonitor.ProcessSample

@Test func newAgentBasenamesMatch() {
    let agents = PSAgentActivityMonitor.agentCommands
    func match(_ command: String) -> String? {
        PSAgentActivityMonitor.agentName(for: command, agents: agents)
    }
    #expect(match("hermes") == "hermes")
    #expect(match("/Users/x/.hermes/bin/hermes --resume") == "hermes")
    #expect(match("kilo") == "kilo")
    #expect(match("kilo serve") == "kilo")
    #expect(match("opencode") == "opencode")
    #expect(match("~/.opencode/bin/opencode2") == "opencode2")
    #expect(match("dsh") == "dsh")
    #expect(match("dsh web") == "dsh")
}

@Test func kiloDoesNotMatchAPathComponent() {
    let agents = PSAgentActivityMonitor.agentCommands
    #expect(AgentHooks.agentMatch(
        comm: nil, path: "/Users/kilo/bin/unrelated", agents: agents) == nil)
    #expect(AgentHooks.agentMatch(comm: "kilo", path: nil, agents: agents) == "kilo")
    // Long enough names still path-match.
    #expect(AgentHooks.agentMatch(
        comm: nil, path: "/Users/x/.local/share/hermes/versions/1.0.0", agents: agents) == "hermes")
}

@Test func dshNeverPathMatches() {
    // Three letters: basename only, like pi.
    let agents = PSAgentActivityMonitor.agentCommands
    #expect(AgentHooks.agentMatch(
        comm: nil, path: "/Users/dsh/bin/unrelated", agents: agents) == nil)
    #expect(AgentHooks.agentMatch(comm: "dsh", path: nil, agents: agents) == "dsh")
}

@Test func kiloServeAndDshWebAreEvidenceOnly() {
    let samples: [Sample] = [
        Sample(pid: 10, ppid: 1, pcpu: 22.0, tty: nil, command: "kilo serve"),
        Sample(pid: 11, ppid: 10, pcpu: 40.0, tty: nil, command: "/usr/bin/node /tmp/kilo-worker.js"),
        Sample(pid: 20, ppid: 1, pcpu: 5.0, tty: "s003", command: "kilo"),
        Sample(pid: 30, ppid: 1, pcpu: 8.0, tty: nil,
               command: "npx @deepseek-ai/dsh web"),
        Sample(pid: 40, ppid: 1, pcpu: 3.0, tty: "s004", command: "dsh"),
        Sample(pid: 50, ppid: 1, pcpu: 1.0, tty: "s005", command: "opencode2"),
        Sample(pid: 60, ppid: 1, pcpu: 1.0, tty: "s006", command: "hermes"),
    ]
    let sessions = PSAgentActivityMonitor.sessions(from: samples)
    let byPid = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) })
    #expect(sessions.count == 6)

    #expect(byPid[10]?.agent == "kilo")
    #expect(byPid[10]?.evidenceOnly == true)
    #expect(byPid[10]?.cpuPercent == 0)

    #expect(byPid[20]?.agent == "kilo")
    #expect(byPid[20]?.evidenceOnly == false)

    #expect(byPid[30]?.agent == "dsh")
    #expect(byPid[30]?.evidenceOnly == true)
    #expect(byPid[30]?.cpuPercent == 0)

    #expect(byPid[40]?.agent == "dsh")
    #expect(byPid[40]?.evidenceOnly == false)

    #expect(byPid[50]?.agent == "opencode2")
    #expect(byPid[60]?.agent == "hermes")
}

@Test func sqliteStoreWriteCountsWALAndIgnoresSiblingLogs() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-sqlite-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let walTime = Date(timeIntervalSince1970: 1_700_000_100)
    let logTime = Date(timeIntervalSince1970: 1_700_000_500)
    let wal = root.appendingPathComponent("opencode.db-wal")
    let log = root.appendingPathComponent("opencode.log")
    try Data([1]).write(to: wal)
    try Data([2]).write(to: log)
    try FileManager.default.setAttributes([.modificationDate: walTime], ofItemAtPath: wal.path)
    try FileManager.default.setAttributes([.modificationDate: logTime], ofItemAtPath: log.path)

    #expect(PSAgentActivityMonitor.newestSqliteStoreWrite(in: root.path, basename: "opencode.db") == walTime)
}

@Test func opencodeStoreHonoursDataDirOverride() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-opencode-\(UUID().uuidString)", isDirectory: true)
    let override = root.appendingPathComponent("custom", isDirectory: true)
    let defaultDir = root.appendingPathComponent(".local/share/opencode", isDirectory: true)
    try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let overrideTime = Date(timeIntervalSince1970: 1_700_000_200)
    let defaultTime = Date(timeIntervalSince1970: 1_700_000_900)
    let overrideDB = override.appendingPathComponent("opencode.db")
    let defaultDB = defaultDir.appendingPathComponent("opencode.db")
    try Data([1]).write(to: overrideDB)
    try Data([2]).write(to: defaultDB)
    try FileManager.default.setAttributes([.modificationDate: overrideTime], ofItemAtPath: overrideDB.path)
    try FileManager.default.setAttributes([.modificationDate: defaultTime], ofItemAtPath: defaultDB.path)

    #expect(PSAgentActivityMonitor.opencodeStoreWrite(
        home: root.path, environment: ["OPENCODE_DATA_DIR": override.path]) == overrideTime)
    #expect(PSAgentActivityMonitor.opencodeStoreWrite(
        home: root.path, environment: [:]) == defaultTime)
}

@Test func hermesStoreReadsProfileStateDBs() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-hermes-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent(".hermes", isDirectory: true)
    let profile = home.appendingPathComponent("profiles/work", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let newer = Date(timeIntervalSince1970: 1_700_000_300)
    let rootDB = home.appendingPathComponent("state.db")
    let profileDB = profile.appendingPathComponent("state.db-wal")
    try Data([1]).write(to: rootDB)
    try Data([2]).write(to: profileDB)
    try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: rootDB.path)
    try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: profileDB.path)

    #expect(PSAgentActivityMonitor.hermesStoreWrite(home: root.path, environment: [:]) == newer)
}

@Test func dshNestedSessionFileCountsAndSiblingsDoNot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-dsh-\(UUID().uuidString)", isDirectory: true)
    let sessionDir = root.appendingPathComponent(
        ".dsh/sessions/%2FUsers%2Fx%2Fproj/session-abc", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fileTime = Date(timeIntervalSince1970: 1_700_000_100)
    let noiseTime = Date(timeIntervalSince1970: 1_700_000_800)
    let transcript = sessionDir.appendingPathComponent("session.jsonl.zstd")
    let noise = sessionDir.appendingPathComponent("cache.bin")
    try Data([1]).write(to: transcript)
    try Data([2]).write(to: noise)
    try FileManager.default.setAttributes([.modificationDate: fileTime], ofItemAtPath: transcript.path)
    try FileManager.default.setAttributes([.modificationDate: noiseTime], ofItemAtPath: noise.path)

    #expect(PSAgentActivityMonitor.dshSessionWrite(home: root.path, environment: [:]) == fileTime)
}

@Test func burstWindowsCoverTheNewSQLiteAgents() {
    #expect(PSAgentActivityMonitor.evidenceWindow(for: "opencode") == 20)
    #expect(PSAgentActivityMonitor.evidenceWindow(for: "opencode2") == 20)
    #expect(PSAgentActivityMonitor.evidenceWindow(for: "kilo") == 20)
    #expect(PSAgentActivityMonitor.evidenceWindow(for: "hermes") == 20)
    #expect(PSAgentActivityMonitor.evidenceWindow(for: "dsh")
        == PSAgentActivityMonitor.evidenceFreshWindow)
}
