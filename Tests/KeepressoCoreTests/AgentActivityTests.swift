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
    #expect(match("CLAUDE") == "claude") // case-insensitive
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

// MARK: - Working/idle smoothing

@Test func stepTurnsOnAboveOnThresholdAndOffBelowOffThreshold() {
    var state = AgentActivityTrigger.State()
    state = AgentActivityTrigger.step(state, sample: 5.0) // below on: stays idle
    #expect(state.isWorking == false)

    // Sustained high CPU crosses the on threshold after a few samples.
    for _ in 0..<5 { state = AgentActivityTrigger.step(state, sample: 30.0) }
    #expect(state.isWorking)

    // Hovering in the dead-band (between 3 and 8) holds the verdict.
    for _ in 0..<20 { state = AgentActivityTrigger.step(state, sample: 5.0) }
    #expect(state.isWorking)

    // A clear drop below the off threshold releases it.
    for _ in 0..<20 { state = AgentActivityTrigger.step(state, sample: 0.0) }
    #expect(state.isWorking == false)

    // And hovering in the dead-band from idle stays idle (hysteresis).
    for _ in 0..<20 { state = AgentActivityTrigger.step(state, sample: 5.0) }
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
