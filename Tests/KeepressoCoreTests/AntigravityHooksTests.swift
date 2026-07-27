import Testing
import Foundation
@testable import KeepressoCore

private let cli = "/Applications/Keepresso.app/Contents/Helpers/keepresso"

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func object(_ data: Data) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

// MARK: - Safety

@Test func antigravityNeverInstallsOnTheBlockingEvent() {
    // PreToolUse decides whether a tool call may run, and Keepresso's hook is
    // built to be a silent no-op when the CLI is gone. A no-op there could deny
    // every tool call in the session.
    #expect(AntigravityHooks.blockingEvents == ["PreToolUse"])
    for event in AntigravityHooks.installedEvents {
        #expect(!AntigravityHooks.blockingEvents.contains(event))
    }
}

@Test func antigravityHookCommandAnswersBeforeItCanFail() {
    let command = AntigravityHooks.hookCommand(event: "Stop", cliPath: cli)
    // The inert response is printed first, so a missing or wedged binary still
    // leaves valid, opinion-free output on stdout.
    #expect(command.hasPrefix("printf '{}';"))
    #expect(!command.contains("allow"))
    #expect(!command.contains("force_continue"))
    #expect(command.contains("antigravity-hook Stop"))
    #expect(command.contains(AntigravityHooks.hookMarker))
}

// MARK: - Event reduction

@Test func antigravityEventsMapToSessionStates() {
    func reduce(_ event: String, tool: String? = nil, fullyIdle: Bool? = nil) -> AgentHooks.HookEventEffect? {
        AntigravityHooks.reduce(event: event, toolName: tool, fullyIdle: fullyIdle)
    }
    #expect(reduce("PreInvocation") == .set(.working, detail: nil))
    #expect(reduce("PostInvocation") == .set(.working, detail: nil))
    #expect(reduce("PostToolUse", tool: "run_command") == .set(.working, detail: "running-command"))
    #expect(reduce("PostToolUse", tool: "edit_file") == .set(.working, detail: "editing"))
    // An unknown tool still reads as work, named generically.
    #expect(reduce("PostToolUse", tool: "wobble") == .set(.working, detail: "tool:wobble"))
    // An unknown event writes nothing at all.
    #expect(reduce("SomethingNew") == nil)
}

@Test func onlyAFullyIdleStopEndsTheWork() {
    func stop(_ fullyIdle: Bool?) -> AgentHooks.HookEventEffect? {
        AntigravityHooks.reduce(event: "Stop", toolName: nil, fullyIdle: fullyIdle)
    }
    #expect(stop(true) == .set(.idle, detail: nil))
    // More execution follows: ending the session here would drop the Mac
    // mid-task, which is the whole failure this trigger exists to prevent.
    #expect(stop(false) == .set(.working, detail: nil))
    // A payload without the field is the plain stop it looks like.
    #expect(stop(nil) == .set(.idle, detail: nil))
}

// MARK: - Payload

@Test func antigravityPayloadDecodesTheDocumentedShape() {
    let data = Data("""
    {"conversationId":"ed6b90f5","workspacePaths":["/Users/x/site","/Users/x/other"],
     "transcriptPath":"/Users/x/.gemini/antigravity/brain/ed6b90f5/transcript.jsonl",
     "toolCall":{"name":"run_command","args":{"command":"npm test"}},
     "stepIdx":42,"unknownFutureField":true}
    """.utf8)
    let payload = try! JSONDecoder().decode(AntigravityHooks.HookPayload.self, from: data)
    #expect(payload.identity == "ed6b90f5")
    #expect(payload.toolCall?.name == "run_command")
    // No cwd field in this payload: the first workspace root stands in.
    #expect(payload.directory == "/Users/x/site")
}

@Test func aPayloadWithoutAConversationIsIgnored() {
    // No identity means no record to write or delete: handling must be inert
    // rather than inventing a session.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ag-hooks-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    AntigravityHooks.handle(
        event: "PreInvocation", payloadData: Data("{}".utf8), parentPid: 1, in: directory)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? false)
}

// MARK: - Host resolution

@Test func theEditorHostIsMatchedByItsBundleNotItsBinaryName() {
    // Several editors ship a "language_server"; only the bundle says whose.
    #expect(AntigravityHooks.isEditorHostPath(
        "/Applications/Antigravity.app/Contents/Resources/bin/language_server"))
    #expect(!AntigravityHooks.isEditorHostPath(
        "/Applications/Other.app/Contents/Resources/bin/language_server"))
    #expect(!AntigravityHooks.isEditorHostPath(
        "/Applications/Antigravity.app/Contents/MacOS/Antigravity"))
}

@Test func hookRecordsJoinTheEditorHostByPid() {
    // hook shell (7) -> language_server (5) -> the app (3).
    let parents: [Int32: Int32] = [7: 5, 5: 3, 3: 1]
    let paths: [Int32: String] = [
        7: "/bin/zsh",
        5: "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
        3: "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
    ]
    let host = AntigravityHooks.findEditorHost(
        startingAt: 7, parentOf: { parents[$0] }, pathOf: { paths[$0] })
    #expect(host == 5)
}

@Test func aRecordFromTheEditorHostSurvivesTheAgentLivenessProbe() {
    // The trust probe demands that a record's pid still *be* an agent, which
    // an editor binary never is. Without the host exemption every record these
    // hooks write is read back as belonging to a dead agent and dropped, and
    // the whole integration silently does nothing.
    let host = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
    #expect(AgentHooks.agentMatch(
        comm: "language_server", path: host,
        agents: PSAgentActivityMonitor.agentCommands) == nil)
    #expect(AntigravityHooks.isEditorHostPath(host))
}

@Test func aStaleWorkingRecordFromAnEditorHostAgesOut() {
    // Antigravity IDE is ownerPid-only, same as Cursor: past staleAfter the
    // record must not stay trusted just because the editor host still runs.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ag-live-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "ed6b90f5", state: .working, detail: nil, cwd: "/Users/x/site",
            origin: .ide, ownerPid: 71776, agent: "antigravity",
            updatedAt: now.addingTimeInterval(-AgentHooks.staleAfter - 60)),
        in: directory)
    #expect(AgentHooks.readHookRecords(
        now: now, in: directory, isAlive: { _ in false }, isHostAlive: { $0 == 71776 }).isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("ed6b90f5.json").path))
}

@Test func aCLIAgyWorkingRecordOutlivesStalenessWhileAgentLives() {
    // CLI `agy` sessions carry agentPid; long silent turns must keep trusting
    // working while that process is alive (IDE ownerPid-only does not).
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ag-cli-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    AgentHooks.write(
        AgentHooks.HookRecord(
            sessionId: "cli-turn", state: .working, cwd: "/Users/x/site",
            origin: .terminal, agentPid: 4242, agent: "agy",
            updatedAt: now.addingTimeInterval(-AgentHooks.staleAfter - 60)),
        in: directory)
    let live = AgentHooks.readHookRecords(
        now: now, in: directory, isAlive: { $0 == 4242 }, isHostAlive: { _ in false })
    #expect(live.count == 1)
    #expect(live.first?.state == .working)
}

@Test func handleAnchorsAnIDESessionToItsEditorHost() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ag-handle-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // hook shell (7) -> language_server (5) -> the app (3). No `agy` in the
    // tree, so this is an in-editor turn.
    let parents: [Int32: Int32] = [7: 5, 5: 3, 3: 1]
    let paths: [Int32: String] = [
        7: "/bin/zsh",
        5: "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
        3: "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
    ]
    AntigravityHooks.handle(
        event: "PreInvocation",
        payloadData: Data(#"{"conversationId":"ed6b90f5","workspacePaths":["/Users/x/site"]}"#.utf8),
        parentPid: 7, in: directory,
        parentOf: { parents[$0] }, commandOf: { _ in nil }, pathOf: { paths[$0] })
    let records = AgentHooks.readHookRecords(
        now: Date(), in: directory, isAlive: { _ in true }, isHostAlive: { _ in true })
    #expect(records.count == 1)
    #expect(records[0].state == .working)
    // Owner, not agent: the language_server is shared across conversations, so
    // joining on it would let one chat's Stop idle another still-working chat.
    #expect(records[0].agentPid == nil)
    #expect(records[0].ownerPid == 5)
    #expect(records[0].agent == "antigravity")
    #expect(records[0].origin == .ide)
    #expect(records[0].cwd == "/Users/x/site")
}

@Test func twoIDEConversationsStayIndependentSessions() {
    // The failure this guards: both chats write records for the same host, the
    // newer Stop would stamp the shared pid idle, and the Mac would sleep while
    // the older chat was still mid-tool. Owner-anchored records each become
    // their own hook-only row instead.
    let now = Date()
    let records = [
        AgentHooks.HookRecord(
            sessionId: "chat-a", state: .working, detail: "running-command",
            cwd: "/Users/x/site", origin: .ide, ownerPid: 5, agent: "antigravity",
            updatedAt: now.addingTimeInterval(-10)),
        AgentHooks.HookRecord(
            sessionId: "chat-b", state: .idle, detail: nil,
            cwd: "/Users/x/site", origin: .ide, ownerPid: 5, agent: "antigravity",
            updatedAt: now),
    ]
    // No process to join: both fall through as hook-only sessions.
    let join = PSAgentActivityMonitor.applyHookRecords(records, to: [], cwdOf: { _ in nil })
    let sessions = join.unclaimed.compactMap(PSAgentActivityMonitor.hookOnlySession(from:))
    #expect(sessions.count == 2)
    let byId = Dictionary(uniqueKeysWithValues: sessions.map {
        ($0.pid, $0)
    })
    let pidA = PSAgentActivityMonitor.syntheticPid(forSessionId: "chat-a")
    let pidB = PSAgentActivityMonitor.syntheticPid(forSessionId: "chat-b")
    #expect(byId[pidA]?.hookState == .working)
    #expect(byId[pidB]?.hookState == .idle)
}

@Test func ideHooksSuppressTheEvidenceOnlyHostAfterStop() {
    // language_server evidence-only row + idle hook-only chat: after Stop the
    // host must not keep the trigger on via conversation DB freshness.
    let host = AgentSession(
        pid: 5, agent: "antigravity", tty: nil, cpuPercent: 0,
        hasFreshEvidence: true, origin: .ide, evidenceOnly: true)
    let idleHook = AgentHooks.HookRecord(
        sessionId: "chat-1", state: .idle, cwd: "/Users/x/site",
        origin: .ide, ownerPid: 5, agent: "antigravity", updatedAt: Date())
    let remaining = PSAgentActivityMonitor.suppressingHookCoveredEvidenceHosts(
        [host], hookRecords: [idleHook])
    #expect(remaining.isEmpty)

    // Without IDE hooks the evidence-only host still stands (hooks not installed).
    #expect(PSAgentActivityMonitor.suppressingHookCoveredEvidenceHosts(
        [host], hookRecords: []) == [host])

    // A Stop'd chat with hooks: trigger reads only the idle hook-only row.
    let join = PSAgentActivityMonitor.applyHookRecords(
        [idleHook], to: [host], cwdOf: { _ in "/Users/x/site" })
    var sessions = PSAgentActivityMonitor.suppressingHookCoveredEvidenceHosts(
        join.sessions, hookRecords: [idleHook])
    sessions.append(contentsOf: join.unclaimed.compactMap(PSAgentActivityMonitor.hookOnlySession(from:)))
    #expect(sessions.count == 1)
    #expect(sessions[0].hookState == .idle)
    #expect(sessions[0].evidenceOnly == false)
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(
        state, sample: sessions[0].cpuPercent, freshEvidence: false,
        hookState: sessions[0].hookState, evidenceOnly: sessions[0].evidenceOnly)
    #expect(!state.isWorking)
}

// MARK: - hooks.json install and remove

@Test func installWritesOneGroupPerObservedEvent() {
    let data = try! AntigravityHooks.installHooks(into: nil, cliPath: cli)
    let ours = object(data)[AntigravityHooks.hookName] as! [String: Any]
    #expect(ours["enabled"] as? Bool == true)
    #expect(ours["PreToolUse"] == nil)
    for event in AntigravityHooks.installedEvents {
        let groups = ours[event] as! [Any]
        #expect(groups.count == 1)
        let hooks = (groups[0] as! [String: Any])["hooks"] as! [Any]
        let hook = hooks[0] as! [String: Any]
        #expect(hook["type"] as? String == "command")
        #expect(hook["timeout"] as? Int == 5)
        #expect((hook["command"] as! String).contains("antigravity-hook \(event)"))
    }
}

@Test func installLeavesEveryOtherAuthorsHooksAlone() {
    let existing = json([
        "someone-elses-hook": [
            "enabled": true,
            "PreToolUse": [["matcher": "run_command",
                            "hooks": [["type": "command", "command": "./check.sh"]]]],
        ]
    ])
    let data = try! AntigravityHooks.installHooks(into: existing, cliPath: cli)
    let root = object(data)
    let theirs = root["someone-elses-hook"] as! [String: Any]
    let groups = theirs["PreToolUse"] as! [Any]
    let hooks = (groups[0] as! [String: Any])["hooks"] as! [Any]
    #expect((hooks[0] as! [String: Any])["command"] as? String == "./check.sh")
    #expect(root[AntigravityHooks.hookName] != nil)
}

@Test func installIsIdempotentAndRepairsAStalePath() {
    let first = try! AntigravityHooks.installHooks(into: nil, cliPath: "/old/path/keepresso")
    #expect(AntigravityHooks.hookInstallState(of: first, cliPath: cli) != .installed)
    let second = try! AntigravityHooks.installHooks(into: first, cliPath: cli)
    #expect(AntigravityHooks.hookInstallState(of: second, cliPath: cli) == .installed)
    let third = try! AntigravityHooks.installHooks(into: second, cliPath: cli)
    #expect(object(third).count == object(second).count)
    #expect(AntigravityHooks.hookInstallState(of: third, cliPath: cli) == .installed)
}

@Test func aDisabledInstallIsNotAHealthyOne() {
    var root = object(try! AntigravityHooks.installHooks(into: nil, cliPath: cli))
    var ours = root[AntigravityHooks.hookName] as! [String: Any]
    ours["enabled"] = false
    root[AntigravityHooks.hookName] = ours
    // Toggled off in the file, the hooks never fire; reporting "installed"
    // would promise tracking that isn't happening.
    #expect(AntigravityHooks.hookInstallState(of: json(root), cliPath: cli) != .installed)
}

@Test func removeTakesOursAndNothingElse() {
    let existing = json([
        "someone-elses-hook": [
            "enabled": true,
            "Stop": [["hooks": [["type": "command", "command": "./theirs.sh"]]]],
        ]
    ])
    let installed = try! AntigravityHooks.installHooks(into: existing, cliPath: cli)
    let removed = try! AntigravityHooks.removeHooks(from: installed)
    let root = object(removed)
    #expect(root[AntigravityHooks.hookName] == nil)
    let theirs = root["someone-elses-hook"] as! [String: Any]
    let groups = theirs["Stop"] as! [Any]
    let hooks = (groups[0] as! [String: Any])["hooks"] as! [Any]
    #expect((hooks[0] as! [String: Any])["command"] as? String == "./theirs.sh")
    #expect(AntigravityHooks.hookInstallState(of: removed, cliPath: cli) == .notInstalled)
}

@Test func aStrayEntryInsideAnotherObjectIsSweptOut() {
    // What an older install could have left behind: ours nested in a foreign
    // hook object, still firing, invisible to a plain key removal.
    let stray = json([
        "theirs": [
            "enabled": true,
            "Stop": [["hooks": [
                ["type": "command", "command": "./theirs.sh"],
                ["type": "command",
                 "command": "keepresso antigravity-hook Stop # \(AntigravityHooks.hookMarker)"],
            ]]],
        ]
    ])
    let removed = try! AntigravityHooks.removeHooks(from: stray)
    let hooks = ((object(removed)["theirs"] as! [String: Any])["Stop"] as! [Any])
        .compactMap { ($0 as! [String: Any])["hooks"] as? [Any] }
        .flatMap { $0 }
    #expect(hooks.count == 1)
    #expect((hooks[0] as! [String: Any])["command"] as? String == "./theirs.sh")
}

@Test func unreadableConfigIsReportedNotOverwritten() {
    let garbage = Data("not json at all".utf8)
    #expect(AntigravityHooks.hookInstallState(of: garbage, cliPath: cli) == .unreadable)
    #expect(throws: AgentHooks.SettingsUnreadableError.self) {
        _ = try AntigravityHooks.installHooks(into: garbage, cliPath: cli)
    }
}

@Test func antigravityOwnsOnlyItsOwnRecords() {
    func record(agent: String?) -> AgentHooks.HookRecord {
        AgentHooks.HookRecord(
            sessionId: "s", state: .working, detail: nil, cwd: nil,
            agent: agent, updatedAt: Date())
    }
    #expect(AntigravityHooks.ownsRecord(record(agent: "antigravity")))
    #expect(AntigravityHooks.ownsRecord(record(agent: "agy")))
    #expect(!AntigravityHooks.ownsRecord(record(agent: "cursor")))
    #expect(!AntigravityHooks.ownsRecord(record(agent: nil)))
}
