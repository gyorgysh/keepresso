import Testing
import Foundation
@testable import KeepressoCore

private let cli = "/Applications/Keepresso.app/Contents/Helpers/keepresso"
private let hermesPid: Int32 = 4242

private func tempHooksDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("hermes-hooks-\(UUID().uuidString)", isDirectory: true)
}

private func handle(_ event: String, _ payload: String, in dir: URL, now: Date = Date()) {
    HermesHooks.handle(
        event: event, payloadData: Data(payload.utf8), parentPid: hermesPid, now: now, in: dir)
}

private func record(turn: String, in dir: URL) -> AgentHooks.HookRecord? {
    AgentHooks.readRecord(sessionId: "hermes-turn-\(turn)", in: dir)
}

@Suite struct HermesHooksTests {

    // MARK: - Turn lifecycle

    @Test func turnStartWritesAWorkingRowAnchoredToHermes() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle("TurnStart", #"{"turn":"t1","platform":"telegram"}"#, in: dir)
        let written = record(turn: "t1", in: dir)
        #expect(written?.state == .working)
        #expect(written?.agent == "hermes")
        #expect(written?.ownerPid == hermesPid)
        #expect(written?.agentPid == nil)
        // A gateway turn has no terminal to name.
        #expect(written?.origin == nil)
    }

    @Test func cliTurnsAreTerminalSessions() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle("TurnStart", #"{"turn":"t1","platform":"cli"}"#, in: dir)
        #expect(record(turn: "t1", in: dir)?.origin == .terminal)
    }

    @Test func toolApprovalAndEndFollowTheTurn() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle("TurnStart", #"{"turn":"t1"}"#, in: dir)
        handle("PreToolUse", #"{"turn":"t1","tool_name":"terminal"}"#, in: dir)
        #expect(record(turn: "t1", in: dir)?.detail == "running-command")
        handle("ApprovalRequest", #"{"turn":"t1"}"#, in: dir)
        #expect(record(turn: "t1", in: dir)?.state == .waiting)
        #expect(record(turn: "t1", in: dir)?.detail == "waiting-approval")
        handle("ApprovalResponse", #"{"turn":"t1"}"#, in: dir)
        #expect(record(turn: "t1", in: dir)?.state == .working)
        handle("TurnEnd", #"{"turn":"t1"}"#, in: dir)
        #expect(record(turn: "t1", in: dir) == nil)
    }

    @Test func concurrentTurnsKeepSeparateRows() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle("TurnStart", #"{"turn":"a"}"#, in: dir)
        handle("TurnStart", #"{"turn":"b"}"#, in: dir)
        handle("TurnEnd", #"{"turn":"a"}"#, in: dir)
        #expect(record(turn: "a", in: dir) == nil)
        #expect(record(turn: "b", in: dir)?.state == .working)
    }

    @Test func heartbeatRefreshesWithoutChangingState() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        handle("TurnStart", #"{"turn":"t1"}"#, in: dir, now: start)
        handle("ApprovalRequest", #"{"turn":"t1"}"#, in: dir, now: start)
        let later = start.addingTimeInterval(90)
        handle("Heartbeat", #"{"turn":"t1"}"#, in: dir, now: later)
        let refreshed = record(turn: "t1", in: dir)
        #expect(refreshed?.updatedAt == later)
        #expect(refreshed?.detail == "waiting-approval")
    }

    @Test func heartbeatNeverResurrectsAnEndedTurn() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle("TurnStart", #"{"turn":"t1"}"#, in: dir)
        handle("TurnEnd", #"{"turn":"t1"}"#, in: dir)
        handle("Heartbeat", #"{"turn":"t1"}"#, in: dir)
        #expect(record(turn: "t1", in: dir) == nil)
    }

    @Test func presenceIsAnIdleRowForTheProcess() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle("Presence", #"{"turn":""}"#, in: dir)
        let presence = AgentHooks.readRecord(sessionId: "hermes-host-\(hermesPid)", in: dir)
        #expect(presence?.state == .idle)
        #expect(presence?.ownerPid == hermesPid)
    }

    @Test func eventsWithoutATurnOrUnknownNamesWriteNothing() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        handle("TurnStart", #"{}"#, in: dir)
        handle("SomethingNew", #"{"turn":"t1"}"#, in: dir)
        handle("TurnStart", "not json", in: dir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(names.isEmpty)
    }

    /// The rows are host-anchored, so they get the hook-only trust rules: a
    /// turn whose heartbeat stopped (end event lost, plugin wedged) expires
    /// instead of holding the Mac awake for the life of the gateway.
    @Test func aSilentTurnExpiresEvenWhileHermesRuns() {
        let dir = tempHooksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        handle("TurnStart", #"{"turn":"t1"}"#, in: dir, now: start)
        let fresh = AgentHooks.readHookRecords(
            now: start.addingTimeInterval(60), in: dir, isHostAlive: { _ in true })
        #expect(fresh.map(\.sessionId) == ["hermes-turn-t1"])
        let stale = AgentHooks.readHookRecords(
            now: start.addingTimeInterval(AgentHooks.staleAfter + 1), in: dir,
            isHostAlive: { _ in true })
        #expect(stale.isEmpty)
    }

    // MARK: - Detail tokens

    @Test func hermesToolNamesMapToSharedTokens() {
        #expect(HermesHooks.detailToken(forTool: "terminal") == "running-command")
        #expect(HermesHooks.detailToken(forTool: "patch") == "editing")
        #expect(HermesHooks.detailToken(forTool: "search_files") == "searching")
        #expect(HermesHooks.detailToken(forTool: "browser_navigate") == "browsing")
        #expect(HermesHooks.detailToken(forTool: "delegate_task") == "subagent")
        #expect(HermesHooks.detailToken(forTool: "vision") == "tool:vision")
    }

    // MARK: - Install state

    private func files(cliPath: String = cli) -> [String: Data?] {
        HermesHooks.pluginFiles(cliPath: cliPath).mapValues { Data($0.utf8) }
    }

    @Test func installedNeedsCurrentFilesAndEnablement() {
        #expect(HermesHooks.installState(files: files(), enabled: true, cliPath: cli) == .installed)
        guard case .needsRepair = HermesHooks.installState(files: files(), enabled: false, cliPath: cli) else {
            Issue.record("written but not enabled should be repairable")
            return
        }
    }

    @Test func noFilesAndNotEnabledIsNotInstalled() {
        #expect(HermesHooks.installState(files: [:], enabled: false, cliPath: cli) == .notInstalled)
    }

    @Test func aMovedAppIsRepairable() {
        let old = files(cliPath: "/Users/me/Downloads/Keepresso.app/Contents/Helpers/keepresso")
        guard case .needsRepair(let report) = HermesHooks.installState(
            files: old, enabled: true, cliPath: cli) else {
            Issue.record("a stale baked path should be repairable")
            return
        }
        #expect(report.stale == ["__init__.py"])
    }

    @Test func pythonQuotingSurvivesQuotesAndBackslashes() {
        #expect(HermesHooks.pythonQuoted(#"/A "b"\c"#) == #""/A \"b\"\\c""#)
        #expect(HermesHooks.pythonQuoted("/Applications/K.app") == #""/Applications/K.app""#)
    }

    @Test func pluginSourceSendsNoConversationContent() {
        let source = HermesHooks.pluginSource(cliPath: cli)
        for field in ["user_message", "conversation_history", "assistant_response", "\"args\"", "result"] {
            #expect(!source.contains("kwargs.get(\(field)") && !source.contains("kwargs[\(field)"))
        }
        #expect(source.contains(HermesHooks.hookMarker))
    }

    // MARK: - config.yaml

    @Test func enabledInABlockList() {
        let yaml = """
            model: x
            plugins:
              disabled: []
              enabled:
              - disk-cleanup
              - keepresso
            display:
              skin: default
            """
        #expect(HermesHooks.isEnabled(inConfig: yaml))
    }

    /// Exactly what `hermes plugins enable keepresso` writes (Hermes 0.20).
    @Test func enabledAsHermesWritesIt() {
        let yaml = """
            plugins:
              enabled:
                - keepresso
              disabled: []
              entries:
                keepresso:
                  allow_tool_override: false

            # ── Security ──
            security:
              redact: true
            """
        #expect(HermesHooks.isEnabled(inConfig: yaml))
    }

    @Test func enabledInAFlowList() {
        #expect(HermesHooks.isEnabled(inConfig: "plugins:\n  enabled: [spotify, 'keepresso']\n"))
    }

    @Test func otherListsDoNotCount() {
        let yaml = """
            plugins:
              disabled:
              - keepresso
              enabled:
              - spotify
            toolsets:
              enabled:
              - keepresso
            """
        #expect(!HermesHooks.isEnabled(inConfig: yaml))
        #expect(!HermesHooks.isEnabled(inConfig: nil))
        #expect(!HermesHooks.isEnabled(inConfig: "plugins:\n  enabled: []\n"))
    }

    // MARK: - Coexistence

    @Test func claudeUninstallLeavesHermesRowsAlone() {
        let row = AgentHooks.HookRecord(
            sessionId: "hermes-turn-t1", state: .working, ownerPid: hermesPid,
            agent: "hermes", updatedAt: Date())
        #expect(!AgentHooks.shouldPurgeOnClaudeUninstall(row))
    }

    @Test func pluginRowsReplaceTheHeuristicRowForTheSameProcess() {
        let heuristic = AgentSession(pid: hermesPid, agent: "hermes", tty: nil, cpuPercent: 40)
        let other = AgentSession(pid: 77, agent: "hermes", tty: nil, cpuPercent: 40)
        let presence = AgentHooks.HookRecord(
            sessionId: "hermes-host-\(hermesPid)", state: .idle, ownerPid: hermesPid,
            agent: "hermes", updatedAt: Date())
        let kept = PSAgentActivityMonitor.suppressingHookCoveredEvidenceHosts(
            [heuristic, other], hookRecords: [presence])
        #expect(kept.map(\.pid) == [77])
    }
}
