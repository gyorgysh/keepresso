import Testing
import Foundation
@testable import PervigilCore

private let cli = "/Applications/Pervigil.app/Contents/Helpers/pervigil"

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
        .appendingPathComponent("pervigil-codexhome-\(UUID().uuidString)")
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
        into: nil, cliPath: "/Volumes/Old/Pervigil.app/Contents/Helpers/pervigil")
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

@Test func codexInstallUsesSupportedTimeouts() throws {
    let installed = try CodexHooks.installHooks(into: nil, cliPath: cli)
    let root = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    for event in CodexHooks.installedEvents {
        let groups = try #require(hooks[event] as? [[String: Any]])
        let entries = try #require(groups.first?["hooks"] as? [[String: Any]])
        #expect(entries.first?["timeout"] as? Int == (event == "SessionEnd" ? 3 : 5))
    }
}

@Test func codexRepairMigratesExcessiveSessionEndTimeout() throws {
    let fresh = try CodexHooks.installHooks(into: nil, cliPath: cli)
    for timeout in [1.0, 3.0, 3.5, 5.0] {
        var root = try #require(try JSONSerialization.jsonObject(with: fresh) as? [String: Any])
        var hooks = try #require(root["hooks"] as? [String: Any])
        let foreign: [String: Any] = ["type": "command", "command": "user-cleanup.sh", "timeout": 2]
        // A foreign sibling and an unreadable entry must not hide our old timeout.
        hooks["SessionEnd"] = [["matcher": "other", "hooks": [
            NSNull(), foreign,
            ["type": "command", "command": CodexHooks.hookCommand(event: "SessionEnd", cliPath: cli),
             "timeout": timeout] as [String: Any],
        ] as [Any]]]
        root["hooks"] = hooks
        let existing = try JSONSerialization.data(withJSONObject: root)
        let report = CodexHooks.inspect(existing, cliPath: cli)
        if timeout > 3 {
            #expect(report.stale == ["SessionEnd"])
            guard case .needsRepair = CodexHooks.hookInstallState(of: existing, cliPath: cli) else {
                Issue.record("an excessive SessionEnd timeout must trigger repair")
                continue
            }
        } else {
            #expect(report.isHealthy)
        }
        let repaired = try CodexHooks.installHooks(into: existing, cliPath: cli)
        #expect(CodexHooks.hookInstallState(of: repaired, cliPath: cli) == .installed)
        #expect(try CodexHooks.installHooks(into: repaired, cliPath: cli) == repaired)
        let repairedRoot = try #require(try JSONSerialization.jsonObject(with: repaired) as? [String: Any])
        let repairedHooks = try #require(repairedRoot["hooks"] as? [String: Any])
        let groups = try #require(repairedHooks["SessionEnd"] as? [[String: Any]])
        let preserved = try #require(groups.first?["hooks"] as? [Any])
        #expect(groups.first?["matcher"] as? String == "other")
        #expect(preserved.count == 2)
        #expect(preserved.first is NSNull)
        #expect(NSDictionary(dictionary: try #require(preserved.last as? [String: Any]))
            == NSDictionary(dictionary: foreign))
        let ours = try #require(groups.last?["hooks"] as? [[String: Any]])
        #expect(ours.count == 1)
        #expect(ours.first?["timeout"] as? Int == 3)
    }
}

@Test(arguments: ["\"3\"", "true", "false", "-1", "2.5", "3.0", "1e0", "{}", "[]",
                  "18446744073709551616"])
func codexRepairFixesMalformedTimeouts(literal: String) throws {
    for event in CodexHooks.installedEvents {
        let existing = try codexTimeoutFixture(event: event, literal: literal)
        let report = CodexHooks.inspect(existing, cliPath: cli)
        #expect(report.stale == [event], "\(event): \(literal)")
        guard case .needsRepair = CodexHooks.hookInstallState(of: existing, cliPath: cli) else {
            Issue.record("malformed timeout must trigger repair: \(event), \(literal)")
            continue
        }
        let repaired = try CodexHooks.installHooks(into: existing, cliPath: cli)
        #expect(CodexHooks.inspect(repaired, cliPath: cli).isHealthy)
        #expect(try CodexHooks.installHooks(into: repaired, cliPath: cli) == repaired)
    }
}

@Test(arguments: [nil, "null", "0", "1", "3"] as [String?])
func codexHealthAcceptsValidTimeouts(literal: String?) throws {
    for event in CodexHooks.installedEvents {
        let existing = try codexTimeoutFixture(event: event, literal: literal)
        #expect(CodexHooks.inspect(existing, cliPath: cli).isHealthy)
        #expect(CodexHooks.hookInstallState(of: existing, cliPath: cli) == .installed)
    }
}

private func codexTimeoutFixture(event: String, literal: String?) throws -> Data {
    let fresh = try CodexHooks.installHooks(into: nil, cliPath: cli)
    var root = try #require(try JSONSerialization.jsonObject(with: fresh) as? [String: Any])
    var hooks = try #require(root["hooks"] as? [String: Any])
    var groups = try #require(hooks[event] as? [[String: Any]])
    var entries = try #require(groups[0]["hooks"] as? [[String: Any]])
    // Insert the literal after serialization so Foundation cannot turn 3.0 into 3.
    entries[0]["timeout"] = literal == nil ? nil : "__pervigil_timeout_fixture__"
    // A foreign timeout above our limit must never trigger repair on its own.
    entries.append(["type": "command", "command": "user-hook.sh", "timeout": 120])
    groups[0]["hooks"] = entries
    hooks[event] = groups
    root["hooks"] = hooks
    let serialized = try JSONSerialization.data(withJSONObject: root)
    let json = try #require(String(data: serialized, encoding: .utf8))
    return Data(json.replacingOccurrences(of: "\"__pervigil_timeout_fixture__\"",
                                          with: literal ?? "null").utf8)
}

// MARK: - Records

@Test func codexRecordsAreOwnedByCodexAndSparedByOtherRemovals() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-hooks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // A codex session: the ancestor walk finds the codex process by name.
    let rows: [(pid: Int32, ppid: Int32, comm: String)] = [
        (pid: 90, ppid: 80, comm: "pervigil"),
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
