import Testing
import Foundation
@testable import KeepressoCore

private let cli = "/Applications/Keepresso.app/Contents/Helpers/keepresso"

// MARK: - The file format Codex is strict about

@Test func onlyTheTwoKeysCodexToleratesAreEverWritten() throws {
    // Codex parses hooks.json with unknown fields denied and accepts only
    // `description` and `hooks`. One stray key at the top level makes it
    // reject the entire file and load none of the hooks in it, the user's
    // included, so writing anything else back would be actively harmful.
    let messy = Data("""
    {"description":"my hooks","hooks":{},"state":{"x":1},"bogusTopLevel":42}
    """.utf8)
    let installed = try CodexHooks.installHooks(into: messy, cliPath: cli)
    let root = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
    #expect(Set(root.keys) == ["description", "hooks"])
    // The user's own description survives; the keys Codex would choke on don't.
    #expect(root["description"] as? String == "my hooks")
}

@Test func eventNamesAreSpelledExactlyAsCodexMatchesThem() {
    // Codex does not validate these names. A lowercase letter parses cleanly,
    // registers zero hooks, and warns nowhere, so the integration would look
    // installed and do nothing at all. Pin the spelling.
    #expect(CodexHooks.installedEvents == [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "SessionEnd",
    ])
    // Every event we install must be one the shared reducer actually maps,
    // or we would write a hook whose events go nowhere.
    for event in CodexHooks.installedEvents {
        #expect(AgentHooks.reduce(event: event, toolName: "Bash") != nil,
                "\(event) is installed but not reduced")
    }
}

@Test func codexMarkerIsDistinctFromTheOtherTools() {
    // Removing one integration must never strip another's entries.
    #expect(!CodexHooks.hookMarker.contains(AgentHooks.hookMarker))
    #expect(!AgentHooks.hookMarker.contains(CodexHooks.hookMarker))
    #expect(CodexHooks.hookMarker != CursorHooks.hookMarker)
}

@Test func hooksURLFollowsCodexHome() {
    // CODEX_HOME relocates the whole directory, and people do set it.
    #expect(CodexHooks.hooksURL(home: "/Users/x", environment: [:]).path
            == "/Users/x/.codex/hooks.json")
    #expect(CodexHooks.hooksURL(home: "/Users/x", environment: ["CODEX_HOME": "/tmp/ch"]).path
            == "/tmp/ch/hooks.json")
}

@Test func detectionReadsRolloutsUnderCodexHome() throws {
    // Hooks install under CODEX_HOME, so detection must read the rollout
    // files from the same root, or a set CODEX_HOME means hooks install
    // correctly while detection watches an empty default directory.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-codexhome-\(UUID().uuidString)")
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.calendar = Calendar(identifier: .gregorian)
    day.dateFormat = "yyyy/MM/dd"
    let dir = root.appendingPathComponent("sessions/\(day.string(from: Date()))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rollout = dir.appendingPathComponent("rollout-2026-01-01-abc123.jsonl")
    FileManager.default.createFile(atPath: rollout.path, contents: Data("{}".utf8))
    defer { try? FileManager.default.removeItem(at: root) }

    let env = ["CODEX_HOME": root.path]
    let written = PSAgentActivityMonitor.codexRolloutWrite(
        forSessionId: "abc123", home: "/Users/nobody", environment: env)
    #expect(written != nil)
    // Without the env override the fixture is invisible.
    #expect(PSAgentActivityMonitor.codexRolloutWrite(
        forSessionId: "abc123", home: "/Users/nobody", environment: [:]) == nil)
}

// MARK: - Merging

@Test func installMergesBesideTheUsersOwnHooksAndIsIdempotent() throws {
    let existing = Data("""
    {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"theirs.sh"}]}],
              "SessionStart":[{"hooks":[{"type":"command","command":"mine.sh"}]}, null]}}
    """.utf8)
    let once = try CodexHooks.installHooks(into: existing, cliPath: cli)
    let twice = try CodexHooks.installHooks(into: once, cliPath: cli)
    #expect(once == twice, "re-installing must replace our entry, never add another")

    let root = try #require(try JSONSerialization.jsonObject(with: twice) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let pre = try #require(hooks["PreToolUse"] as? [Any])
    // Theirs plus ours.
    #expect(pre.count == 2)
    // The element we could not read is carried through untouched.
    let start = try #require(hooks["SessionStart"] as? [Any])
    #expect(start.contains { $0 is NSNull })
    #expect(start.contains {
        (($0 as? [String: Any])?["hooks"] as? [Any])?.contains {
            ($0 as? [String: Any])?["command"] as? String == "mine.sh"
        } ?? false
    })
    #expect(CodexHooks.hookInstallState(of: twice, cliPath: cli) == .installed)
}

@Test func codexRemoveStripsOnlyOurEntries() throws {
    let mine = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"theirs"}]}]}}"#.utf8)
    let installed = try CodexHooks.installHooks(into: mine, cliPath: cli)
    let removed = try CodexHooks.removeHooks(from: installed)
    #expect(CodexHooks.hookInstallState(of: removed, cliPath: cli) == .notInstalled)
    let root = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stop = try #require(hooks["Stop"] as? [Any])
    #expect(stop.count == 1)
}

// MARK: - Health

@Test func codexHealthReportsDriftLikeTheOthers() throws {
    let moved = try CodexHooks.installHooks(
        into: nil, cliPath: "/Volumes/Old/Keepresso.app/Contents/Helpers/keepresso")
    let report = CodexHooks.inspect(moved, cliPath: cli)
    #expect(report.stale == Set(CodexHooks.installedEvents))
    #expect(!report.isHealthy)
    guard case .needsRepair = CodexHooks.hookInstallState(of: moved, cliPath: cli) else {
        Issue.record("a moved app must ask to be repaired")
        return
    }
    #expect(CodexHooks.inspect(
        try CodexHooks.installHooks(into: moved, cliPath: cli), cliPath: cli).isHealthy)
}

// MARK: - Records

@Test func codexRecordsAreOwnedByCodexAndSparedByOtherRemovals() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-hooks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // A codex session: the ancestor walk finds the codex process by name.
    let rows: [(pid: Int32, ppid: Int32, comm: String)] = [
        (pid: 90, ppid: 80, comm: "keepresso"),
        (pid: 80, ppid: 70, comm: "sh"),
        (pid: 70, ppid: 60, comm: "codex"),
        (pid: 60, ppid: 1, comm: "zsh"),
    ]
    let parents = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.ppid) })
    let comms = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.comm) })
    CodexHooks.handle(
        event: "PreToolUse",
        payloadData: Data(#"{"session_id":"s-1","cwd":"/proj","tool_name":"Bash"}"#.utf8),
        parentPid: 90, in: dir,
        parentOf: { parents[$0] }, commandOf: { comms[$0] }, pathOf: { _ in nil })

    let records = AgentHooks.readHookRecords(
        now: Date(), in: dir, isAlive: { _ in true }, isHostAlive: { _ in true })
    #expect(records.count == 1)
    #expect(records[0].agent == "codex")
    #expect(records[0].agentPid == 70)
    #expect(records[0].detail == "running-command")
    #expect(CodexHooks.ownsRecord(records[0]))
    // Not Cursor's, so a Cursor uninstall leaves it alone.
    #expect(!CursorHooks.ownsRecord(records[0]))
    AgentHooks.purgeRecords(in: dir, where: CursorHooks.ownsRecord)
    #expect(AgentHooks.readHookRecords(
        now: Date(), in: dir, isAlive: { _ in true }, isHostAlive: { _ in true }).count == 1)
}
