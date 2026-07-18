import Testing
import Foundation
@testable import KeepressoCore

/// Scripted agent-session source standing in for the `ps`-backed monitor.
private final class FakeAgentActivity: AgentActivityMonitoring {
    var current: AgentSnapshot
    init(_ sessions: [AgentSession] = []) { current = AgentSnapshot(sessions: sessions) }
}

private func session(pid: Int32, agent: String = "claude", tty: String? = "s003", cpu: Double) -> AgentSession {
    AgentSession(pid: pid, agent: agent, tty: tty, cpuPercent: cpu)
}

// MARK: - ps output parsing

@Test func parseReadsWellFormedRowsAndSkipsMalformedOnes() {
    let raw = """
      812     1  12.5 ttys003  node /opt/homebrew/bin/claude
        1     0   0.0 ??       /sbin/launchd
     9999   812   3.0 ttys003  /bin/zsh -c swift build --verbose
    not a row at all
        7     1  bad  ttys000  /usr/bin/thing
    """
    let samples = PSAgentActivityMonitor.parse(raw)
    #expect(samples.count == 3)
    #expect(samples[0] == .init(pid: 812, ppid: 1, pcpu: 12.5, tty: "s003", command: "node /opt/homebrew/bin/claude"))
    // A "??" terminal reads as nil; the "tty" prefix is dropped for display.
    #expect(samples[1].tty == nil)
    // The command keeps its embedded spaces intact.
    #expect(samples[2].command == "/bin/zsh -c swift build --verbose")
}

// MARK: - Root matching

@Test func agentNameMatchesRootCommandBasenameOnly() {
    let agents = PSAgentActivityMonitor.agentCommands
    func match(_ command: String) -> String? {
        PSAgentActivityMonitor.agentName(for: command, agents: agents)
    }
    #expect(match("claude --resume") == "claude")
    #expect(match("/opt/homebrew/bin/codex exec") == "codex")
    // Case-sensitive on purpose: the Claude desktop app's Electron binary is
    // "Claude", and matching it would root the session at the whole app.
    #expect(match("CLAUDE") == nil)
    #expect(match("/Applications/Claude.app/Contents/MacOS/Claude") == nil)
    #expect(match("/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)") == nil)
    // The Claude Code copy embedded in the desktop app is lowercase and real.
    #expect(match("/Users/x/Library/Application Support/Claude/claude-code/2.1.209/claude.app/Contents/MacOS/claude") == "claude")
    // A runtime wrapper is skipped to the script it runs, past its flags.
    #expect(match("node /Users/x/.volta/bin/claude") == "claude")
    #expect(match("node --max-old-space-size=4096 /usr/local/bin/claude chat") == "claude")
    // Mentions of an agent anywhere else must not count.
    #expect(match("grep claude notes.txt") == nil)
    #expect(match("vim notes-about-claude.md") == nil)
    #expect(match("/bin/ps -axww") == nil)
    #expect(match("node server.js") == nil)
}

// MARK: - Session reduction

@Test func sessionsFoldNestedAgentsAndSumSubtreeCPU() {
    typealias Sample = PSAgentActivityMonitor.ProcessSample
    let samples: [Sample] = [
        Sample(pid: 100, ppid: 1, pcpu: 2.0, tty: "s003", command: "claude"),
        // A tool call two levels down: counts toward pid 100's subtree.
        Sample(pid: 200, ppid: 100, pcpu: 1.0, tty: "s003", command: "/bin/zsh -c swift build"),
        Sample(pid: 201, ppid: 200, pcpu: 40.0, tty: "s003", command: "swift-frontend compile"),
        // A claude-spawned subagent: folded into pid 100, not its own row.
        Sample(pid: 300, ppid: 200, pcpu: 5.0, tty: "s003", command: "claude --subagent"),
        // An unrelated process.
        Sample(pid: 400, ppid: 1, pcpu: 90.0, tty: nil, command: "/usr/libexec/thing"),
        // A second, independent session on another terminal.
        Sample(pid: 500, ppid: 1, pcpu: 0.1, tty: "s007", command: "codex"),
    ]
    let sessions = PSAgentActivityMonitor.sessions(from: samples)
    #expect(sessions.count == 2)
    #expect(sessions[0].pid == 100)
    #expect(sessions[0].agent == "claude")
    #expect(abs(sessions[0].cpuPercent - 48.0) < 0.001) // 2 + 1 + 40 + 5
    #expect(sessions[1].pid == 500)
    #expect(sessions[1].agent == "codex")
}

@Test func sessionsSurviveAPpidCycleFromRacedPSOutput() {
    typealias Sample = PSAgentActivityMonitor.ProcessSample
    // A pid reused mid-scan can appear as its own ancestor; both walks must
    // terminate rather than loop.
    let samples: [Sample] = [
        Sample(pid: 100, ppid: 200, pcpu: 1.0, tty: "s003", command: "claude"),
        Sample(pid: 200, ppid: 100, pcpu: 2.0, tty: "s003", command: "/bin/zsh"),
    ]
    let sessions = PSAgentActivityMonitor.sessions(from: samples)
    #expect(sessions.count == 1)
    #expect(abs(sessions[0].cpuPercent - 3.0) < 0.001)
}

@Test func sessionLabelUsesTTYWithPidFallback() {
    #expect(session(pid: 812, cpu: 0).label == "claude (s003)")
    #expect(session(pid: 812, tty: nil, cpu: 0).label == "claude (pid 812)")
}

@Test func sessionLabelPrefersClassifiedOrigin() {
    // An app or IDE session is named as such even when it holds a pty.
    var app = session(pid: 13, cpu: 0)
    app.origin = .claudeApp
    #expect(app.label == "claude (Claude app)")
    var ide = session(pid: 14, cpu: 0)
    ide.origin = .ide
    #expect(ide.label == "claude (IDE)")
    // A terminal-classified session keeps the more specific tty when present.
    var cli = session(pid: 15, cpu: 0)
    cli.origin = .terminal
    #expect(cli.label == "claude (s003)")
    var detached = session(pid: 16, tty: nil, cpu: 0)
    detached.origin = .terminal
    #expect(detached.label == "claude (terminal)")
}

@Test func desktopAppTreeRootsAtTheEmbeddedCLI() {
    typealias Sample = PSAgentActivityMonitor.ProcessSample
    // The real shape of a Claude desktop app running Claude Code: the Electron
    // main and its helpers must not match, so the session roots at the
    // embedded lowercase claude and counts only that subtree's CPU.
    let samples: [Sample] = [
        Sample(pid: 10, ppid: 1, pcpu: 30.0, tty: nil, command: "/Applications/Claude.app/Contents/MacOS/Claude"),
        Sample(pid: 11, ppid: 10, pcpu: 25.0, tty: nil, command: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"),
        Sample(pid: 12, ppid: 10, pcpu: 0.1, tty: nil, command: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
        Sample(pid: 13, ppid: 12, pcpu: 4.0, tty: nil, command: "/Users/x/Library/Application Support/Claude/claude-code/2.1.209/claude.app/Contents/MacOS/claude"),
        Sample(pid: 14, ppid: 13, pcpu: 6.0, tty: nil, command: "/bin/zsh -c swift build"),
    ]
    let sessions = PSAgentActivityMonitor.sessions(from: samples)
    #expect(sessions.count == 1)
    #expect(sessions[0].pid == 13)
    #expect(sessions[0].agent == "claude")
    #expect(abs(sessions[0].cpuPercent - 10.0) < 0.001)
}

// MARK: - Transcript evidence

@Test func transcriptDirectoryNamesMatchEachAgentsEncoding() {
    #expect(PSAgentActivityMonitor.claudeProjectDirName(forCwd: "/Users/x/git/pueev_web")
            == "-Users-x-git-pueev-web")
    #expect(PSAgentActivityMonitor.claudeProjectDirName(forCwd: "/private/tmp")
            == "-private-tmp")
    // The alphanumeric class is ASCII-only upstream: an accented letter
    // flattens to "-" too, or the computed directory would never exist.
    #expect(PSAgentActivityMonitor.claudeProjectDirName(forCwd: "/Users/józsef/café")
            == "-Users-j-zsef-caf-")
    #expect(PSAgentActivityMonitor.grokSessionDirName(forCwd: "/Users/x/git/demo")
            == "%2FUsers%2Fx%2Fgit%2Fdemo")
    #expect(PSAgentActivityMonitor.grokSessionDirName(forCwd: "/Users/x/git/pueev_web")
            == "%2FUsers%2Fx%2Fgit%2Fpueev_web")
}

@Test func monitorMarksSessionsWithFreshTranscriptsAsEvidence() async throws {
    var now = Date(timeIntervalSince1970: 100_000)
    let monitor = PSAgentActivityMonitor(
        ttl: 3,
        now: { now },
        fetch: { "  100     1  0.1 ttys003  claude\n  200     1  0.1 ttys004  aider" },
        evidence: { agent, _ in
            // claude's transcript was written 5s ago; aider has none.
            agent == "claude" ? Date(timeIntervalSince1970: 100_000 - 5) : nil
        }
    )
    _ = monitor.current // kick the refresh
    try await Task.sleep(for: .milliseconds(200))
    let sessions = monitor.current.sessions
    #expect(sessions.map(\.hasFreshEvidence) == [true, false])

    // Past the freshness window the same write no longer counts.
    now = now.addingTimeInterval(60)
    _ = monitor.current
    try await Task.sleep(for: .milliseconds(200))
    #expect(monitor.current.sessions.map(\.hasFreshEvidence) == [false, false])
}

// MARK: - Working/idle smoothing

@Test func stepJudgesWorkRelativeToTheSessionsOwnBaseline() {
    // A hot-idle TUI (agy-style: animates at 6-12% while doing nothing)
    // settles as idle: its baseline is learned at its own level.
    var hot = AgentActivityTrigger.State()
    for sample in [7.1, 11.4, 7.1, 6.2, 11.7, 6.8, 8.0, 9.0, 7.5, 8.5] {
        hot = AgentActivityTrigger.step(hot, sample: sample)
    }
    #expect(hot.isWorking == false)

    // Real work lifts it clearly above its own baseline.
    for _ in 0..<6 { hot = AgentActivityTrigger.step(hot, sample: 30) }
    #expect(hot.isWorking)

    // Back to its hot idle: releases, even though it still idles above the
    // level at which a quiet agent would count as working.
    for _ in 0..<40 { hot = AgentActivityTrigger.step(hot, sample: 8) }
    #expect(hot.isWorking == false)

    // A quiet agent (grok-style, idle ~2.5%) flips on a small absolute rise
    // that a fixed global threshold would have missed.
    var quiet = AgentActivityTrigger.State()
    for _ in 0..<10 { quiet = AgentActivityTrigger.step(quiet, sample: 2.5) }
    #expect(quiet.isWorking == false)
    for _ in 0..<10 { quiet = AgentActivityTrigger.step(quiet, sample: 9) }
    #expect(quiet.isWorking)
}

@Test func stepHardFloorCatchesASessionFirstSeenMidTask() {
    // First sample arrives mid-task: the baseline is learned at the working
    // level, so the relative test can't fire, but the absolute floor does.
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(state, sample: 60)
    #expect(state.isWorking)

    // The task ends: the average decays below the floor and it releases,
    // after which the true idle level becomes the new baseline.
    for _ in 0..<20 { state = AgentActivityTrigger.step(state, sample: 1) }
    #expect(state.isWorking == false)
    #expect((state.baseline ?? 99) < 3)
}

@Test func stepAdoptsAnIdleFloorThatRoseDuringTheEpisode() {
    // Baseline learned at a quiet idle, then work starts and leaves behind a
    // hotter idle floor (a dev server or watcher the agent started, still
    // running as its child). The subtree settles flat above the off
    // dead-band, which with a frozen baseline would read "working" until the
    // agent process exits: the baseline must creep up to the new floor and
    // release.
    var state = AgentActivityTrigger.State()
    for _ in 0..<10 { state = AgentActivityTrigger.step(state, sample: 0.5) }
    for _ in 0..<10 { state = AgentActivityTrigger.step(state, sample: 30) }
    #expect(state.isWorking)

    var ticks = 0
    while state.isWorking && ticks < 600 {
        state = AgentActivityTrigger.step(state, sample: 3.5)
        ticks += 1
    }
    #expect(state.isWorking == false)
    #expect(ticks < 180) // minutes, not process-lifetime

    // And the raised floor is now the baseline, so the next real burst
    // still reads as work.
    for _ in 0..<10 { state = AgentActivityTrigger.step(state, sample: 15) }
    #expect(state.isWorking)
}

@Test func stepBurstyWorkKeepsItsHeadroomOverALongSession() {
    // On/off tool bursts for many minutes: the dips pull each episode's
    // floor back near the true idle level, so the creeping baseline never
    // adopts the working level and a late burst still reads as work.
    var state = AgentActivityTrigger.State()
    for _ in 0..<10 { state = AgentActivityTrigger.step(state, sample: 1.0) }
    for _ in 0..<30 {
        for _ in 0..<20 { state = AgentActivityTrigger.step(state, sample: 15) }
        for _ in 0..<20 { state = AgentActivityTrigger.step(state, sample: 1.0) }
    }
    for _ in 0..<10 { state = AgentActivityTrigger.step(state, sample: 15) }
    #expect(state.isWorking)
    #expect((state.baseline ?? 99) < 4)
}

@Test func stepFreshTranscriptEvidenceWinsOverQuietCPU() {
    // A long network wait: near-zero CPU, but the transcript is streaming.
    var state = AgentActivityTrigger.State()
    for _ in 0..<5 { state = AgentActivityTrigger.step(state, sample: 0.3, freshEvidence: true) }
    #expect(state.isWorking)

    // Evidence goes stale and CPU stays flat: back to idle.
    for _ in 0..<5 { state = AgentActivityTrigger.step(state, sample: 0.3, freshEvidence: false) }
    #expect(state.isWorking == false)
}

@Test func triggerIsSatisfiedWhileAnySessionWorks() {
    let monitor = FakeAgentActivity([
        session(pid: 1, cpu: 50),
        session(pid: 2, agent: "codex", tty: "s007", cpu: 0),
    ])
    let trigger = AgentActivityTrigger(monitor: monitor)
    #expect(trigger.isSatisfied() == false) // nothing ticked yet

    for _ in 0..<5 { trigger.tick() }
    #expect(trigger.isSatisfied())
    #expect(trigger.sessionStates.map(\.isWorking) == [true, false])

    // The busy session goes quiet: the trigger releases once its EMA decays.
    monitor.current = AgentSnapshot(sessions: [
        session(pid: 1, cpu: 0),
        session(pid: 2, agent: "codex", tty: "s007", cpu: 0),
    ])
    for _ in 0..<30 { trigger.tick() }
    #expect(trigger.isSatisfied() == false)
}

@Test func smoothingStateIsPrunedWhenASessionDisappears() {
    let monitor = FakeAgentActivity([session(pid: 1, cpu: 100)])
    let trigger = AgentActivityTrigger(monitor: monitor)
    for _ in 0..<5 { trigger.tick() }
    #expect(trigger.isSatisfied())

    // The session exits; a NEW session reusing the pid starts from a fresh
    // average instead of inheriting the old "working" verdict.
    monitor.current = AgentSnapshot(sessions: [])
    trigger.tick()
    #expect(trigger.isSatisfied() == false)
    monitor.current = AgentSnapshot(sessions: [session(pid: 1, cpu: 0)])
    trigger.tick()
    #expect(trigger.sessionStates.map(\.isWorking) == [false])
}

@Test func detailRowsMirrorSessionStates() {
    let monitor = FakeAgentActivity([
        session(pid: 1, cpu: 50),
        session(pid: 2, agent: "codex", tty: nil, cpu: 0),
    ])
    let trigger = AgentActivityTrigger(monitor: monitor)
    for _ in 0..<5 { trigger.tick() }
    let rows = trigger.detailRows
    #expect(rows.map(\.label) == ["claude (s003)", "codex (pid 2)"])
    #expect(rows.map(\.active) == [true, false])
}

// MARK: - Rule, factory, and gate plumbing

@Test func agentRuleLabelIncludesGraceSuffix() {
    #expect(TriggerRule.agentActivity(AgentRule(grace: 0)).label == "AI agent working")
    #expect(TriggerRule.agentActivity(AgentRule(grace: 300)).label == "AI agent working (+300s)")
    #expect(
        TriggerRule.agentActivity(AgentRule(grace: 300, countWaitingAsWorking: true)).label
            == "AI agent working (+300s, waiting counts)"
    )
    #expect(TriggerRule.agentActivity(AgentRule()).requiredPermission == nil)
}

@Test func agentRuleCodableRoundTrip() throws {
    let original = RuleSet(combine: .any, rules: [.agentActivity(AgentRule(grace: 600))])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
    #expect(decoded == original)
}

@Test func factoryWrapsAgentActivityInGraceOnlyWhenConfigured() {
    let factory = TriggerFactory(agents: FakeAgentActivity())
    let wrapped = factory.makeTrigger(for: .agentActivity(AgentRule(grace: 600)))
    #expect(wrapped is GracePeriodTrigger)
    #expect((wrapped as? GracePeriodTrigger)?.wrappedTrigger is AgentActivityTrigger)
    let bare = factory.makeTrigger(for: .agentActivity(AgentRule(grace: 0)))
    #expect(bare is AgentActivityTrigger)
}

@MainActor
@Test func gateRuleStatesSurfaceSessionDetailsThroughTheGraceWrapper() {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let monitor = FakeAgentActivity([
        session(pid: 1, cpu: 50),
        session(pid: 2, agent: "codex", tty: "s007", cpu: 0),
    ])
    let factory = TriggerFactory(agents: monitor, now: { now })
    let gate = TriggerGateController(factory: factory, now: { now })
    gate.rebuild(rules: [.agentActivity(AgentRule(grace: 60))], combine: .any, enabled: true)

    for _ in 0..<5 { gate.engine?.tick() }
    let state = gate.ruleStates()?.first
    #expect(state?.satisfied == true)
    #expect(state?.details.map(\.label) == ["claude (s003)", "codex (s007)"])
    #expect(state?.details.map(\.active) == [true, false])

    // All sessions go idle: the rule lingers in grace while the sub-rows
    // already read idle.
    monitor.current = AgentSnapshot(sessions: [
        session(pid: 1, cpu: 0),
        session(pid: 2, agent: "codex", tty: "s007", cpu: 0),
    ])
    for _ in 0..<30 { gate.engine?.tick() }
    now = now.addingTimeInterval(30) // past the state cache, inside the grace
    let lingering = gate.ruleStates()?.first
    #expect(lingering?.satisfied == true)
    #expect(lingering?.inGrace == true)
    #expect(lingering?.details.map(\.active) == [false, false])
}

// MARK: - Monitor cache

@Test func monitorServesStaleSnapshotAndRefreshesInBackground() async throws {
    var now = Date(timeIntervalSince1970: 0)
    let monitor = PSAgentActivityMonitor(ttl: 3, now: { now }, fetch: {
        "  100     1  50.0 ttys003  claude"
    })

    // First read: nothing cached yet, kicks off a refresh and returns empty.
    #expect(monitor.current.sessions.isEmpty)
    try await Task.sleep(for: .milliseconds(200))
    #expect(monitor.current.sessions.count == 1)

    // Within the TTL the cached snapshot is served without another fetch.
    now = now.addingTimeInterval(1)
    #expect(monitor.current.sessions.count == 1)
}

/// Lock-guarded scripted ps output: the monitor calls `fetch` from a detached
/// task (same pattern as ProcessListerTests' FetchStub).
private final class PSOutputStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _output: String?

    init(_ output: String?) { _output = output }

    var output: String? {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    @Sendable func fetch() -> String? { output }
}

@Test func monitorKeepsThePreviousSnapshotOnAFailedFetch() async throws {
    // A transient ps failure must not commit an empty snapshot: the trigger
    // would prune every session's smoothing state, and a mid-task session
    // would rejoin with a baseline learned at its working level. The refresh
    // latch still resets, so the next tick past the TTL retries.
    var now = Date(timeIntervalSince1970: 0)
    let ps = PSOutputStub("  100     1  50.0 ttys003  claude")
    let monitor = PSAgentActivityMonitor(ttl: 3, now: { now }, fetch: ps.fetch)

    _ = monitor.current
    try await Task.sleep(for: .milliseconds(200))
    #expect(monitor.current.sessions.count == 1)

    ps.output = nil
    now = now.addingTimeInterval(4)
    _ = monitor.current
    try await Task.sleep(for: .milliseconds(200))
    #expect(monitor.current.sessions.count == 1) // stale beats empty

    ps.output = "  100     1  50.0 ttys003  claude\n  200     1  0.1 ttys004  codex"
    now = now.addingTimeInterval(4)
    _ = monitor.current
    try await Task.sleep(for: .milliseconds(200))
    #expect(monitor.current.sessions.count == 2) // and it recovered
}

@Test func claudeTranscriptWriteSeesSubagentStreams() throws {
    // Layout: <project>/<session>.jsonl (old) and
    // <project>/<session>/subagents/agent-x.jsonl (fresh). Appends inside
    // subagents never touch the parent mtimes, so the probe must descend.
    let manager = FileManager.default
    let project = manager.temporaryDirectory
        .appendingPathComponent("keepresso-test-\(UUID().uuidString)")
    let subagents = project.appendingPathComponent("session-1/subagents")
    try manager.createDirectory(at: subagents, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: project) }

    let old = Date(timeIntervalSinceNow: -3600)
    let fresh = Date(timeIntervalSinceNow: -5)
    let main = project.appendingPathComponent("session-1.jsonl")
    try Data("x".utf8).write(to: main)
    try manager.setAttributes([.modificationDate: old], ofItemAtPath: main.path)
    let agent = subagents.appendingPathComponent("agent-abc.jsonl")
    try Data("y".utf8).write(to: agent)
    try manager.setAttributes([.modificationDate: fresh], ofItemAtPath: agent.path)
    // The session directory itself is listed too; age it so only the real
    // transcript writes decide the result.
    try manager.setAttributes([.modificationDate: old], ofItemAtPath: project.appendingPathComponent("session-1").path)

    let written = try #require(PSAgentActivityMonitor.claudeTranscriptWrite(inProjectDir: project.path))
    #expect(abs(written.timeIntervalSince(fresh)) < 1)
}

@Test func freshTranscriptOutranksAnOlderNotWorkingVerdict() async throws {
    // The main turn's Stop hook writes idle while a background subagent works
    // on: its transcript keeps streaming but it emits no hook event until its
    // next tool call. A minute later the idle nudge writes a plain `waiting`
    // record for the same still-working session. Evidence newer than the
    // record drops both verdicts; a record newer than the last write keeps
    // deciding, and a pending approval is never overridden (it already reads
    // as working, and the edge is exact).
    let base = Date(timeIntervalSince1970: 100_000)
    func monitor(
        state: AgentHooks.HookSessionState, detail: String? = nil,
        recordAge: TimeInterval, writeAge: TimeInterval
    ) -> PSAgentActivityMonitor {
        PSAgentActivityMonitor(
            ttl: 3,
            now: { base },
            fetch: { "  100     1  0.1 ttys003  claude" },
            evidence: { _, _ in base.addingTimeInterval(-writeAge) },
            hookRecords: { _ in
                [AgentHooks.HookRecord(
                    sessionId: "s", state: state, detail: detail, agentPid: 100,
                    updatedAt: base.addingTimeInterval(-recordAge))]
            }
        )
    }

    let overriddenIdle = monitor(state: .idle, recordAge: 10, writeAge: 5)
    _ = overriddenIdle.current
    try await Task.sleep(for: .milliseconds(200))
    #expect(overriddenIdle.current.sessions.map(\.hookState) == [nil])
    #expect(overriddenIdle.current.sessions.map(\.hasFreshEvidence) == [true])

    let overriddenNudge = monitor(state: .waiting, recordAge: 10, writeAge: 5)
    _ = overriddenNudge.current
    try await Task.sleep(for: .milliseconds(200))
    #expect(overriddenNudge.current.sessions.map(\.hookState) == [nil])

    let approval = monitor(
        state: .waiting, detail: "waiting-approval", recordAge: 10, writeAge: 5)
    _ = approval.current
    try await Task.sleep(for: .milliseconds(200))
    #expect(approval.current.sessions.map(\.hookState) == [.waiting])
    #expect(approval.current.sessions.map(\.hookDetail) == ["waiting-approval"])

    let respected = monitor(state: .idle, recordAge: 2, writeAge: 5)
    _ = respected.current
    try await Task.sleep(for: .milliseconds(200))
    #expect(respected.current.sessions.map(\.hookState) == [.idle])
}

@Test func monitorClassifiesSessionsByAncestry() async throws {
    // Every session is named by the ancestor walk even before any hook
    // record exists, pty or not: an app can hold a pty for its embedded
    // CLI. A terminal-classified session still shows its tty.
    let monitor = PSAgentActivityMonitor(
        ttl: 3,
        now: { Date(timeIntervalSince1970: 0) },
        fetch: { "  100     1  0.1 ??       claude\n  200     1  0.1 ttys003  claude" },
        classifyOrigin: { pid in pid == 100 ? .claudeApp : .terminal }
    )
    _ = monitor.current
    try await Task.sleep(for: .milliseconds(200))
    let sessions = monitor.current.sessions
    #expect(sessions.map(\.origin) == [.claudeApp, .terminal])
    #expect(sessions.map(\.label) == ["claude (Claude app)", "claude (s003)"])
}

// MARK: - Idle-edge latch

@Test func idleEdgeIsConsumedOnce() {
    // A hookState of .working / .idle decides outright, so the edge is exact.
    let monitor = FakeAgentActivity([
        AgentSession(pid: 1, agent: "claude", tty: "s001", cpuPercent: 0, hookState: .working),
    ])
    let trigger = AgentActivityTrigger(monitor: monitor)
    trigger.tick()
    #expect(trigger.isSatisfied())
    #expect(!trigger.consumeJustWentIdle()) // no edge yet

    monitor.current = AgentSnapshot(sessions: [
        AgentSession(pid: 1, agent: "claude", tty: "s001", cpuPercent: 0, hookState: .idle),
    ])
    trigger.tick()
    #expect(!trigger.isSatisfied())
    // The edge reports exactly once, even when ticking stops afterwards
    // (triggers paused): repeated reads must not re-fire the hook.
    #expect(trigger.consumeJustWentIdle())
    #expect(!trigger.consumeJustWentIdle())
    #expect(!trigger.justWentIdle)
}
