import Testing
import Foundation
@testable import KeepressoCore

/// A Mac with exactly the given paths on it.
private func mac(_ paths: String...) -> (String) -> Bool {
    let present = Set(paths)
    return { present.contains($0) }
}

@Test func toolIsAbsentOnAMacThatHasNothing() {
    // The case that matters: nothing offered, so nothing is written. A user
    // who has never installed Cursor must not be invited to create its config.
    for tool in AgentTool.allCases {
        #expect(!tool.isPresent(home: "/Users/x", exists: { _ in false }))
    }
}

@Test func anySinglePieceOfEvidenceIsEnough() {
    // Each of these on its own is a real shape a working install takes, and
    // any one of them should count.
    let claude: [String] = [
        "/Users/x/.claude",
        "/Users/x/.claude.json",
        "/Users/x/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/Applications/Claude.app",
    ]
    for path in claude {
        #expect(AgentTool.claudeCode.isPresent(home: "/Users/x", exists: mac(path)),
                "expected \(path) to prove Claude Code is installed")
    }
    let cursor: [String] = [
        "/Users/x/.cursor",
        "/Users/x/.local/bin/cursor-agent",
        "/opt/homebrew/bin/cursor-agent",
        "/usr/local/bin/cursor-agent",
        "/Applications/Cursor.app",
    ]
    for path in cursor {
        #expect(AgentTool.cursor.isPresent(home: "/Users/x", exists: mac(path)),
                "expected \(path) to prove Cursor is installed")
    }
}

@Test func oneToolsEvidenceNeverProvesTheOther() {
    // Both tools ship a CLI and an app bundle, and both keep a dot-directory
    // in the home folder, so it would be easy to write a probe that fires for
    // whichever happens to be installed.
    #expect(!AgentTool.cursor.isPresent(home: "/Users/x", exists: mac("/Users/x/.claude")))
    #expect(!AgentTool.cursor.isPresent(home: "/Users/x", exists: mac("/Applications/Claude.app")))
    #expect(!AgentTool.claudeCode.isPresent(home: "/Users/x", exists: mac("/Users/x/.cursor")))
    #expect(!AgentTool.claudeCode.isPresent(home: "/Users/x", exists: mac("/Applications/Cursor.app")))
}

@Test func aBareAgentBinaryIsNotEvidenceOfCursor() {
    // Cursor's installer makes both a `cursor-agent` and a bare `agent`
    // symlink, but plenty of unrelated things are called `agent`, so only the
    // specific name counts.
    #expect(!AgentTool.cursor.isPresent(
        home: "/Users/x", exists: mac("/Users/x/.local/bin/agent")))
}

@Test func evidenceIsReadOnlyAndHomeRelative() {
    // Nothing is executed to answer the question, and the home-relative paths
    // really do follow the injected home rather than the real one.
    let elsewhere = AgentTool.claudeCode.evidencePaths(home: "/Volumes/Other/u")
    #expect(elsewhere.contains("/Volumes/Other/u/.claude"))
    #expect(!elsewhere.contains { $0.hasPrefix(NSHomeDirectory() + "/") })
    // A path under the wrong home must not count.
    #expect(!AgentTool.claudeCode.isPresent(
        home: "/Volumes/Other/u", exists: mac("/Users/x/.claude")))
}

// MARK: - What the setup step offers

@Test func setupOffersOnlyToolsTheMacActuallyHas() {
    // The whole point: someone who only uses Claude Code should not be walked
    // through connecting Cursor and Codex during onboarding.
    let tools = AgentTool.setupTools(
        present: { $0 == .claudeCode }, connected: { _ in false })
    #expect(tools == [.claudeCode])

    // Nothing installed, nothing offered: the step should be able to vanish
    // rather than show three buttons that would each create a config file.
    #expect(AgentTool.setupTools(present: { _ in false }, connected: { _ in false }).isEmpty)
}

@Test func anAlreadyConnectedToolStaysListedEvenIfItLooksGone() {
    // Hooks are in its config but the tool now reads as absent (uninstalled,
    // or installed somewhere the probe doesn't look). It must stay visible, or
    // there would be no way to see or undo the connection.
    let tools = AgentTool.setupTools(
        present: { _ in false }, connected: { $0 == .cursor })
    #expect(tools == [.cursor])
}

@Test func setupToolOrderIsStable() {
    // The rows must not reshuffle between visits to the step.
    let all = AgentTool.setupTools(present: { _ in true }, connected: { _ in false })
    #expect(all == AgentTool.allCases)
    #expect(all == AgentTool.setupTools(present: { _ in true }, connected: { _ in true }))
    #expect(AgentTool.allCases.map(\.displayName)
        == ["Claude Code", "Cursor", "Codex", "Antigravity"])
}
