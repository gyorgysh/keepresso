import Testing
import Foundation
@testable import KeepressoCore

private func mac(_ paths: String...) -> (String) -> Bool {
    let present = Set(paths)
    return { present.contains($0) }
}

@Test func toolIsAbsentOnAMacThatHasNothing() {
    for tool in AgentTool.allCases {
        #expect(!tool.isPresent(home: "/Users/x", exists: { _ in false }))
    }
}

@Test func anySinglePieceOfEvidenceIsEnough() {
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
    let grok: [String] = [
        "/Users/x/.grok",
        "/Users/x/.grok/bin/grok",
        "/Users/x/.local/bin/grok",
        "/opt/homebrew/bin/grok",
        "/usr/local/bin/grok",
    ]
    for path in grok {
        #expect(AgentTool.grok.isPresent(home: "/Users/x", exists: mac(path)),
                "expected \(path) to prove Grok is installed")
    }
    let omp: [String] = [
        "/Users/x/.omp/agent",
        "/Users/x/.bun/bin/omp",
        "/Users/x/.local/bin/omp",
        "/opt/homebrew/bin/omp",
        "/usr/local/bin/omp",
    ]
    for path in omp {
        #expect(AgentTool.omp.isPresent(home: "/Users/x", exists: mac(path)),
                "expected \(path) to prove OMP is installed")
    }
}

@Test func oneToolsEvidenceNeverProvesTheOther() {
    #expect(!AgentTool.cursor.isPresent(home: "/Users/x", exists: mac("/Users/x/.claude")))
    #expect(!AgentTool.cursor.isPresent(home: "/Users/x", exists: mac("/Applications/Claude.app")))
    #expect(!AgentTool.claudeCode.isPresent(home: "/Users/x", exists: mac("/Users/x/.cursor")))
    #expect(!AgentTool.claudeCode.isPresent(home: "/Users/x", exists: mac("/Applications/Cursor.app")))
    #expect(!AgentTool.grok.isPresent(home: "/Users/x", exists: mac("/Users/x/.codex")))
    #expect(!AgentTool.codex.isPresent(home: "/Users/x", exists: mac("/Users/x/.grok")))
}

@Test func aBareAgentBinaryIsNotEvidenceOfCursor() {
    #expect(!AgentTool.cursor.isPresent(
        home: "/Users/x", exists: mac("/Users/x/.local/bin/agent")))
}

@Test func evidenceIsReadOnlyAndHomeRelative() {
    let elsewhere = AgentTool.claudeCode.evidencePaths(home: "/Volumes/Other/u")
    #expect(elsewhere.contains("/Volumes/Other/u/.claude"))
    #expect(!elsewhere.contains { $0.hasPrefix(NSHomeDirectory() + "/") })
    #expect(!AgentTool.claudeCode.isPresent(
        home: "/Volumes/Other/u", exists: mac("/Users/x/.claude")))
}


@Test func setupOffersOnlyToolsTheMacActuallyHas() {
    let tools = AgentTool.setupTools(
        present: { $0 == .claudeCode }, connected: { _ in false })
    #expect(tools == [.claudeCode])

    #expect(AgentTool.setupTools(present: { _ in false }, connected: { _ in false }).isEmpty)
}

@Test func anAlreadyConnectedToolStaysListedEvenIfItLooksGone() {
    let tools = AgentTool.setupTools(
        present: { _ in false }, connected: { $0 == .cursor })
    #expect(tools == [.cursor])
}

@Test func setupToolOrderIsStable() {
    let all = AgentTool.setupTools(present: { _ in true }, connected: { _ in false })
    #expect(all == AgentTool.allCases)
    #expect(all == AgentTool.setupTools(present: { _ in true }, connected: { _ in true }))
    #expect(AgentTool.allCases.map(\.displayName)
        == ["Claude Code", "Cursor", "Codex", "Antigravity", "Grok", "Oh My Pi (OMP)", "Hermes Agent",
            "Qwen Code", "Devin", "Kimi Code"])
}
