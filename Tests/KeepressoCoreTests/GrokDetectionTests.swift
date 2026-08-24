import Testing
import Foundation
@testable import KeepressoCore

/// Per-session Grok transcript evidence: pid join onto that conversation's
/// jsonl, never the project folder.

private let cwd = "/Users/x/git/demo"
private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let fresh = Date(timeIntervalSince1970: 1_700_000_000 - 5)
private let stale = Date(timeIntervalSince1970: 1_700_000_000 - 600)

private func grokHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-detect-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func env(_ home: URL) -> [String: String] {
    ["GROK_HOME": home.path]
}

private func writeActive(_ entries: [[String: Any]], home: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: entries)
    try data.write(to: home.appendingPathComponent("active_sessions.json"))
}

private func writeSessionFiles(
    home: URL,
    group: String,
    sessionId: String,
    files: [String: Date]
) throws {
    let sessionDir = home
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(group, isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    for (name, date) in files {
        let path = sessionDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
    }
}

private func writeProjectFile(home: URL, group: String, name: String, date: Date) throws {
    let groupDir = home
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(group, isDirectory: true)
    try FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
    let path = groupDir.appendingPathComponent(name)
    try Data("x".utf8).write(to: path)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
}

private func evidence(pid: Int32, cwd: String? = cwd, home: URL) -> Date? {
    PSAgentActivityMonitor.grokTranscriptWrite(
        pid: pid, cwd: cwd, home: "/unused", environment: env(home))
}

@Test func grokEvidenceIsPerSessionNotPerProject() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let group = PSAgentActivityMonitor.grokSessionDirName(forCwd: cwd)
    try writeSessionFiles(home: home, group: group, sessionId: "sess-a", files: [
        "updates.jsonl": fresh,
    ])
    try writeSessionFiles(home: home, group: group, sessionId: "sess-b", files: [
        "updates.jsonl": stale,
    ])
    try writeActive([
        ["session_id": "sess-a", "pid": 100, "cwd": cwd, "opened_at": "2026-01-01T00:00:00Z"],
        ["session_id": "sess-b", "pid": 200, "cwd": cwd],
    ], home: home)

    let a = try #require(evidence(pid: 100, home: home))
    #expect(abs(a.timeIntervalSince(fresh)) < 1)
    let b = try #require(evidence(pid: 200, home: home))
    #expect(abs(b.timeIntervalSince(stale)) < 1)
}

@Test func sharedPromptHistoryDoesNotMarkASiblingWorking() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let group = PSAgentActivityMonitor.grokSessionDirName(forCwd: cwd)
    try writeSessionFiles(home: home, group: group, sessionId: "sess-a", files: [
        "updates.jsonl": fresh,
    ])
    try writeSessionFiles(home: home, group: group, sessionId: "sess-b", files: [
        "updates.jsonl": stale,
        "resources_state.json": fresh,
    ])
    try writeProjectFile(home: home, group: group, name: "prompt_history.jsonl", date: now)
    try writeActive([
        ["session_id": "sess-a", "pid": 100, "cwd": cwd],
        ["session_id": "sess-b", "pid": 200, "cwd": cwd],
    ], home: home)

    #expect(evidence(pid: 200, home: home).map { abs($0.timeIntervalSince(stale)) < 1 } == true)
}

@Test func pidMissingFromActiveSessionsReturnsNil() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let group = PSAgentActivityMonitor.grokSessionDirName(forCwd: cwd)
    try writeSessionFiles(home: home, group: group, sessionId: "sess-a", files: [
        "updates.jsonl": fresh,
    ])
    try writeProjectFile(home: home, group: group, name: "prompt_history.jsonl", date: now)
    try writeActive([
        ["session_id": "sess-a", "pid": 100, "cwd": cwd],
    ], home: home)

    #expect(evidence(pid: 999, home: home) == nil)
}

@Test func twoSessionsForOnePidTakeTheNewestWrite() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let group = PSAgentActivityMonitor.grokSessionDirName(forCwd: cwd)
    try writeSessionFiles(home: home, group: group, sessionId: "sess-a", files: [
        "chat_history.jsonl": stale,
    ])
    try writeSessionFiles(home: home, group: group, sessionId: "sess-b", files: [
        "events.jsonl": fresh,
    ])
    try writeActive([
        ["session_id": "sess-a", "pid": 100, "cwd": cwd],
        ["session_id": "sess-b", "pid": 100, "cwd": cwd],
    ], home: home)

    let written = try #require(evidence(pid: 100, home: home))
    #expect(abs(written.timeIntervalSince(fresh)) < 1)
}

@Test func grokHomeRelocatesTheIndexAndTheSessionsTree() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let group = PSAgentActivityMonitor.grokSessionDirName(forCwd: cwd)
    try writeSessionFiles(home: home, group: group, sessionId: "sess-a", files: [
        "updates.jsonl": fresh,
    ])
    try writeActive([
        ["session_id": "sess-a", "pid": 100, "cwd": cwd],
    ], home: home)

    #expect(PSAgentActivityMonitor.grokHome(home: "/Users/x", environment: [:])
            == "/Users/x/.grok")
    #expect(PSAgentActivityMonitor.grokHome(
        home: "/Users/x", environment: ["GROK_HOME": home.path]) == home.path)
    #expect(evidence(pid: 100, home: home) != nil)
    #expect(PSAgentActivityMonitor.grokTranscriptWrite(
        pid: 100, cwd: cwd, home: "/Users/x", environment: [:]) == nil)
}

@Test func encodedCwdMatchesGrokSessionDirName() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let group = PSAgentActivityMonitor.grokSessionDirName(forCwd: cwd)
    #expect(group == "%2FUsers%2Fx%2Fgit%2Fdemo")
    try writeSessionFiles(home: home, group: group, sessionId: "sess-a", files: [
        "updates.jsonl": fresh,
    ])
    try writeActive([
        ["session_id": "sess-a", "pid": 100, "cwd": cwd],
    ], home: home)
    #expect(evidence(pid: 100, home: home) != nil)
}

@Test func slugPlusHashGroupIsFoundViaCwdFile() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let slug = "demo-abc123def456"
    try writeSessionFiles(home: home, group: slug, sessionId: "sess-a", files: [
        "updates.jsonl": fresh,
    ])
    let marker = home
        .appendingPathComponent("sessions/\(slug)/.cwd")
    try Data(cwd.utf8).write(to: marker)
    try writeActive([
        ["session_id": "sess-a", "pid": 100, "cwd": cwd],
    ], home: home)

    let written = try #require(evidence(pid: 100, home: home))
    #expect(abs(written.timeIntervalSince(fresh)) < 1)
}

@Test func tornActiveSessionsIndexIsNoMapping() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("{".utf8).write(to: home.appendingPathComponent("active_sessions.json"))
    let group = PSAgentActivityMonitor.grokSessionDirName(forCwd: cwd)
    try writeSessionFiles(home: home, group: group, sessionId: "sess-a", files: [
        "updates.jsonl": fresh,
    ])
    #expect(evidence(pid: 100, home: home) == nil)
}

@Test func oneBadActiveSessionRowDoesNotDropTheRest() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let group = PSAgentActivityMonitor.grokSessionDirName(forCwd: cwd)
    try writeSessionFiles(home: home, group: group, sessionId: "sess-a", files: [
        "updates.jsonl": fresh,
    ])
    try writeActive([
        ["session_id": "sess-a", "pid": 100, "cwd": cwd],
        ["session_id": "no-pid", "cwd": cwd],
        ["session_id": "string-pid", "pid": "200", "cwd": cwd],
        ["not": "a session"],
    ], home: home)
    #expect(evidence(pid: 100, home: home) != nil)
    #expect(evidence(pid: 200, home: home) == nil)
}

@Test func camelCaseActiveSessionKeysAreAccepted() throws {
    let home = try grokHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let group = PSAgentActivityMonitor.grokSessionDirName(forCwd: cwd)
    try writeSessionFiles(home: home, group: group, sessionId: "sess-a", files: [
        "updates.jsonl": fresh,
    ])
    try writeActive([
        ["sessionId": "sess-a", "pid": 100, "cwd": cwd],
    ], home: home)
    #expect(evidence(pid: 100, home: home) != nil)
}
