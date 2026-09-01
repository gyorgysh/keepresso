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
    #expect(match("muse") == "muse")
    #expect(match("/Users/x/.local/bin/muse --yolo") == "muse")
    #expect(match("/Users/x/.local/bin/muse-bin-1.0.1-R2006.1") == "muse")
    #expect(match("muse-bin") == "muse")
    #expect(match("muse-code") == "muse")
    #expect(match("muse-cli exec") == "muse")
    #expect(match("museum") == nil)
    #expect(match("muse-helper") == nil)
    #expect(match("grep muse notes.txt") == nil)
    #expect(match("devin") == "devin")
    #expect(match("/Users/x/.local/bin/devin") == "devin")
    #expect(match("devin acp") == "devin")
    #expect(match("devin-cli") == "devin")
    #expect(match("/Users/x/.local/bin/devin-cli --resume") == "devin")
    #expect(match("grep devin notes.txt") == nil)
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

@Test func museDoesNotMatchAPathComponent() {
    // Four letters, same /Users/muse/... trap as kilo. The live binary is
    // `muse-bin-<version>`, matched by prefix on the command basename.
    let agents = PSAgentActivityMonitor.agentCommands
    #expect(AgentHooks.agentMatch(
        comm: nil, path: "/Users/muse/bin/unrelated", agents: agents) == nil)
    #expect(AgentHooks.agentMatch(
        comm: nil, path: "/Users/x/.local/share/muse/versions/1.0.0", agents: agents) == nil)
    #expect(AgentHooks.agentMatch(comm: "muse", path: nil, agents: agents) == "muse")
}

@Test func devinDoesNotMatchAPathComponent() {
    // Five letters, same /Users/devin/... trap as kilo. The live command
    // basename is `devin` or `devin-cli`.
    let agents = PSAgentActivityMonitor.agentCommands
    #expect(AgentHooks.agentMatch(
        comm: nil, path: "/Users/devin/bin/unrelated", agents: agents) == nil)
    #expect(AgentHooks.agentMatch(
        comm: nil, path: "/Users/x/.local/share/devin/cli/_versions/3000.6.7/bin/unrelated",
        agents: agents) == nil)
    #expect(AgentHooks.agentMatch(comm: "devin", path: nil, agents: agents) == "devin")
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
    #expect(PSAgentActivityMonitor.evidenceWindow(for: "muse")
        == PSAgentActivityMonitor.evidenceFreshWindow)
    #expect(PSAgentActivityMonitor.evidenceWindow(for: "devin") == 20)
}

@Test func museSessionMessageIsNotASession() {
    let samples: [Sample] = [
        Sample(pid: 10, ppid: 1, pcpu: 0.7, tty: "s006",
               command: "/Users/x/.local/bin/muse-bin-1.0.1-R2006.1"),
        Sample(pid: 11, ppid: 1, pcpu: 0.0, tty: "s006",
               command: "/Users/x/.local/bin/muse-bin-0.2.1-R1215.1 session-message serve --socket /tmp/muse.sock"),
        Sample(pid: 12, ppid: 10, pcpu: 40.0, tty: "s006", command: "/bin/zsh -c swift test"),
    ]
    let sessions = PSAgentActivityMonitor.sessions(from: samples)
    #expect(sessions.count == 1)
    #expect(sessions[0].pid == 10)
    #expect(sessions[0].agent == "muse")
    #expect(sessions[0].evidenceOnly == false)
    #expect(abs(sessions[0].cpuPercent - 40.7) < 0.001)
}

@Test func museSessionJsonlCountsAndSiblingsDoNot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-muse-\(UUID().uuidString)", isDirectory: true)
    let now = Date(timeIntervalSince1970: 1_788_258_000) // 2026-09-01 10:20 UTC
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.calendar = Calendar(identifier: .gregorian)
    day.dateFormat = "yyyy/MM/dd"
    day.timeZone = .current
    let sessionDir = root.appendingPathComponent(
        ".local/share/muse/sessions/\(day.string(from: now))/sess-1", isDirectory: true)
    let subDir = sessionDir.appendingPathComponent("subagent/child-1", isDirectory: true)
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let jsonlTime = Date(timeIntervalSince1970: 1_788_258_100)
    let subTime = Date(timeIntervalSince1970: 1_788_258_200)
    let noiseTime = Date(timeIntervalSince1970: 1_788_258_900)
    let jsonl = sessionDir.appendingPathComponent("session.jsonl")
    let sub = subDir.appendingPathComponent("session.jsonl")
    let noise = sessionDir.appendingPathComponent("cron.db")
    try Data([1]).write(to: jsonl)
    try Data([2]).write(to: sub)
    try Data([3]).write(to: noise)
    try FileManager.default.setAttributes([.modificationDate: jsonlTime], ofItemAtPath: jsonl.path)
    try FileManager.default.setAttributes([.modificationDate: subTime], ofItemAtPath: sub.path)
    try FileManager.default.setAttributes([.modificationDate: noiseTime], ofItemAtPath: noise.path)

    #expect(PSAgentActivityMonitor.museSessionWrite(
        home: root.path, now: now, environment: [:]) == subTime)
}

@Test func museSessionHonoursXDGDataHomeAndYesterday() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-muse-xdg-\(UUID().uuidString)", isDirectory: true)
    let now = Date(timeIntervalSince1970: 1_788_258_000)
    let yesterday = now.addingTimeInterval(-86_400)
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.calendar = Calendar(identifier: .gregorian)
    day.dateFormat = "yyyy/MM/dd"
    day.timeZone = .current
    let xdg = root.appendingPathComponent("xdg", isDirectory: true)
    let yDir = xdg.appendingPathComponent(
        "muse/sessions/\(day.string(from: yesterday))/old-sess", isDirectory: true)
    try FileManager.default.createDirectory(at: yDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let yTime = Date(timeIntervalSince1970: 1_788_171_600)
    let jsonl = yDir.appendingPathComponent("session.jsonl")
    try Data([1]).write(to: jsonl)
    try FileManager.default.setAttributes([.modificationDate: yTime], ofItemAtPath: jsonl.path)

    #expect(PSAgentActivityMonitor.museSessionWrite(
        home: root.path, now: now, environment: ["XDG_DATA_HOME": xdg.path]) == yTime)
    #expect(PSAgentActivityMonitor.museSessionWrite(
        home: root.path, now: now, environment: [:]) == nil)
}

@Test func devinAcpIsEvidenceOnlyAndFoldsUnderTheTUI() {
    let samples: [Sample] = [
        Sample(pid: 10, ppid: 1, pcpu: 0.7, tty: "s008", command: "devin"),
        Sample(pid: 11, ppid: 10, pcpu: 0.1, tty: "s008",
               command: "/Users/x/.local/bin/devin acp"),
        Sample(pid: 20, ppid: 1, pcpu: 3.0, tty: nil,
               command: "/Users/x/.local/bin/devin acp"),
        Sample(pid: 30, ppid: 1, pcpu: 1.2, tty: "s009", command: "devin-cli"),
    ]
    let sessions = PSAgentActivityMonitor.sessions(from: samples)
    let byPid = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) })
    #expect(sessions.count == 3)
    #expect(byPid[11] == nil)

    #expect(byPid[10]?.agent == "devin")
    #expect(byPid[10]?.evidenceOnly == false)
    #expect(abs((byPid[10]?.cpuPercent ?? 0) - 0.8) < 0.001)

    #expect(byPid[20]?.agent == "devin")
    #expect(byPid[20]?.evidenceOnly == true)
    #expect(byPid[20]?.cpuPercent == 0)

    #expect(byPid[30]?.agent == "devin")
    #expect(byPid[30]?.evidenceOnly == false)
}

@Test func devinStoreCountsSqliteAndTranscriptsNotLogs() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-devin-\(UUID().uuidString)", isDirectory: true)
    let cli = root.appendingPathComponent(".local/share/devin/cli", isDirectory: true)
    let transcripts = cli.appendingPathComponent("transcripts", isDirectory: true)
    let logs = cli.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let walTime = Date(timeIntervalSince1970: 1_788_260_100)
    let jsonTime = Date(timeIntervalSince1970: 1_788_260_200)
    let noiseTime = Date(timeIntervalSince1970: 1_788_260_900)
    let wal = cli.appendingPathComponent("sessions.db-wal")
    let json = transcripts.appendingPathComponent("cheddar-windscreen.json")
    let log = logs.appendingPathComponent("devin_20260901.log")
    let appState = cli.appendingPathComponent("app_state.json")
    try Data([1]).write(to: wal)
    try Data([2]).write(to: json)
    try Data([3]).write(to: log)
    try Data([4]).write(to: appState)
    try FileManager.default.setAttributes([.modificationDate: walTime], ofItemAtPath: wal.path)
    try FileManager.default.setAttributes([.modificationDate: jsonTime], ofItemAtPath: json.path)
    try FileManager.default.setAttributes([.modificationDate: noiseTime], ofItemAtPath: log.path)
    try FileManager.default.setAttributes([.modificationDate: noiseTime], ofItemAtPath: appState.path)

    #expect(PSAgentActivityMonitor.devinStoreWrite(home: root.path, environment: [:]) == jsonTime)
}

@Test func devinStoreHonoursXDGDataHome() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-devin-xdg-\(UUID().uuidString)", isDirectory: true)
    let xdg = root.appendingPathComponent("xdg", isDirectory: true)
    let xdgCli = xdg.appendingPathComponent("devin/cli", isDirectory: true)
    let defaultCli = root.appendingPathComponent(".local/share/devin/cli", isDirectory: true)
    try FileManager.default.createDirectory(at: xdgCli, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: defaultCli, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let xdgTime = Date(timeIntervalSince1970: 1_788_260_300)
    let defaultTime = Date(timeIntervalSince1970: 1_788_260_900)
    let xdgDB = xdgCli.appendingPathComponent("sessions.db")
    let defaultDB = defaultCli.appendingPathComponent("sessions.db")
    try Data([1]).write(to: xdgDB)
    try Data([2]).write(to: defaultDB)
    try FileManager.default.setAttributes([.modificationDate: xdgTime], ofItemAtPath: xdgDB.path)
    try FileManager.default.setAttributes([.modificationDate: defaultTime], ofItemAtPath: defaultDB.path)

    #expect(PSAgentActivityMonitor.devinStoreWrite(
        home: root.path, environment: ["XDG_DATA_HOME": xdg.path]) == xdgTime)
    #expect(PSAgentActivityMonitor.devinStoreWrite(
        home: root.path, environment: [:]) == defaultTime)
}
