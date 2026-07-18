import Foundation
import Testing
@testable import KeepressoCore

private final class CallTrace: @unchecked Sendable {
    var values: [String] = []
}

private final class FakeWakeIntent: WakeKeepAliveIntentControlling, @unchecked Sendable {
    let trace: CallTrace
    var values: [Bool] = []

    init(trace: CallTrace = CallTrace()) { self.trace = trace }

    func setKeepAliveIntended(_ intended: Bool) {
        values.append(intended)
        trace.values.append("intent:\(intended)")
    }
}

private final class FakeWakeProbe: WakeReadinessProbing, @unchecked Sendable {
    let trace: CallTrace
    var snapshots: [WakeReadinessSnapshot]
    var callCount = 0

    init(_ snapshots: [WakeReadinessSnapshot], trace: CallTrace = CallTrace()) {
        self.snapshots = snapshots
        self.trace = trace
    }

    func snapshot(for requirements: WakeReadinessRequirements) -> WakeReadinessSnapshot {
        trace.values.append("probe")
        let index = min(callCount, snapshots.count - 1)
        callCount += 1
        return snapshots[index]
    }
}

private final class FakeUnattendedDiagnostics: UnattendedDiagnosticRecording, @unchecked Sendable {
    var events: [UnattendedDiagnosticEvent] = []
    func record(_ event: UnattendedDiagnosticEvent) { events.append(event) }
}

private final class FakeTaskLauncher: UnattendedTaskLaunching, @unchecked Sendable {
    var failures: [String: String] = [:]
    var scriptedStatuses: [String: [UnattendedTaskPollStatus]] = [:]
    var startedTaskIDs: [String] = []
    var cancelledTaskIDs: [String] = []

    private var taskByHandle: [UnattendedTaskHandle: String] = [:]
    private var statusIndex: [String: Int] = [:]

    func start(_ task: UnattendedTaskDefinition) -> UnattendedTaskStartResult {
        startedTaskIDs.append(task.id)
        if let failure = failures[task.id] { return .failed(failure) }
        let handle = UnattendedTaskHandle()
        taskByHandle[handle] = task.id
        return .started(handle)
    }

    func status(of handle: UnattendedTaskHandle) -> UnattendedTaskPollStatus {
        guard let taskID = taskByHandle[handle] else {
            return .failed(exitCode: nil, reason: "unknown")
        }
        let script = scriptedStatuses[taskID] ?? [.running]
        let index = statusIndex[taskID, default: 0]
        statusIndex[taskID] = index + 1
        return script[min(index, script.count - 1)]
    }

    func cancel(_ handle: UnattendedTaskHandle) {
        if let taskID = taskByHandle[handle] { cancelledTaskIDs.append(taskID) }
    }
}

private let testDate = Date(timeIntervalSince1970: 10_000)

private func readySnapshot(
    network: Bool? = true,
    provider: PowerSourceSnapshot.Provider = .ac,
    percentage: Int? = 100,
    commands: Set<String> = ["codex"],
    applications: Set<String> = ["com.openai.codex"]
) -> WakeReadinessSnapshot {
    WakeReadinessSnapshot(
        power: PowerSourceSnapshot(
            provider: provider,
            isCharging: provider == .ac,
            hasBattery: true,
            percentage: percentage
        ),
        networkReachable: network,
        availableCommands: commands,
        availableApplications: applications
    )
}

private var testRequirements: WakeReadinessRequirements {
    WakeReadinessRequirements(
        powerPolicy: WakePowerPolicy(requireExternalPower: true, minimumBatteryPercentage: 25),
        networkRequired: true,
        targets: [
            .command(executable: "codex"),
            .application(bundleIdentifier: "com.openai.codex"),
        ]
    )
}

@Test func readinessEvaluationReportsEveryBlockingPolicyIssue() {
    let snapshot = readySnapshot(
        network: false,
        provider: .battery,
        percentage: 10,
        commands: [],
        applications: []
    )
    let issues = WakeReadinessController.evaluate(snapshot, against: testRequirements)
    #expect(issues == [
        .externalPowerRequired,
        .batteryBelowMinimum(actual: 10, required: 25),
        .networkUnavailable,
        .commandUnavailable("codex"),
        .applicationUnavailable("com.openai.codex"),
    ])
}

@Test func batteryMinimumBlocksAnUnknownPowerProviderAfterWake() {
    let requirements = WakeReadinessRequirements(
        powerPolicy: WakePowerPolicy(
            requireExternalPower: false,
            minimumBatteryPercentage: 30
        ),
        networkRequired: false
    )
    let issues = WakeReadinessController.evaluate(
        readySnapshot(provider: .unknown, percentage: nil),
        against: requirements
    )
    #expect(issues == [.powerSourceUnknown])
}

@MainActor
@Test func readinessCreatesKeepAliveIntentBeforeFirstProbeAndRetries() {
    let trace = CallTrace()
    let intent = FakeWakeIntent(trace: trace)
    let probe = FakeWakeProbe([
        readySnapshot(network: false),
        readySnapshot(),
    ], trace: trace)
    let diagnostics = FakeUnattendedDiagnostics()
    let controller = WakeReadinessController(
        intent: intent,
        probe: probe,
        policy: WakeReadinessPolicy(
            timeout: 20,
            initialRetryDelay: 2,
            retryMultiplier: 2,
            maximumRetryDelay: 8
        ),
        diagnostics: diagnostics
    )

    controller.begin(requirements: testRequirements, at: testDate)
    #expect(trace.values == ["intent:true"])

    controller.tick(at: testDate)
    #expect(trace.values == ["intent:true", "probe"])
    #expect(controller.state == .waiting(
        attempt: 1,
        nextAttemptAt: testDate.addingTimeInterval(2),
        deadline: testDate.addingTimeInterval(20),
        issues: [.networkUnavailable]
    ))

    controller.tick(at: testDate.addingTimeInterval(1))
    #expect(probe.callCount == 1)
    controller.tick(at: testDate.addingTimeInterval(2))
    #expect(controller.state == .ready(at: testDate.addingTimeInterval(2)))
    #expect(intent.values == [true])

    controller.finish(at: testDate.addingTimeInterval(3))
    #expect(intent.values == [true, false])
    #expect(diagnostics.events.map(\.kind) == [
        .wakePreparationStarted,
        .readinessRetryScheduled,
        .readinessReady,
    ])
}

@MainActor
@Test func readinessBackoffStopsAtDeadlineAndReleasesIntent() {
    let intent = FakeWakeIntent()
    let probe = FakeWakeProbe([readySnapshot(network: false)])
    let diagnostics = FakeUnattendedDiagnostics()
    let controller = WakeReadinessController(
        intent: intent,
        probe: probe,
        policy: WakeReadinessPolicy(
            timeout: 5,
            initialRetryDelay: 2,
            retryMultiplier: 2,
            maximumRetryDelay: 10
        ),
        diagnostics: diagnostics
    )

    controller.begin(requirements: testRequirements, at: testDate)
    controller.tick(at: testDate)
    controller.tick(at: testDate.addingTimeInterval(2))
    #expect(controller.state == .waiting(
        attempt: 2,
        nextAttemptAt: testDate.addingTimeInterval(5),
        deadline: testDate.addingTimeInterval(5),
        issues: [.networkUnavailable]
    ))
    controller.tick(at: testDate.addingTimeInterval(5))

    #expect(controller.state == .timedOut(
        at: testDate.addingTimeInterval(5),
        issues: [.networkUnavailable]
    ))
    #expect(intent.values == [true, false])
    #expect(probe.callCount == 3)
    #expect(diagnostics.events.last?.kind == .readinessTimedOut)
}

@Test func systemReadinessProbeChecksOnlyRequiredTargets() {
    final class FakePower: PowerSourceMonitoring {
        var current = PowerSourceSnapshot(
            provider: .ac,
            isCharging: true,
            hasBattery: true,
            percentage: 80
        )
    }
    let trace = CallTrace()
    let probe = SystemWakeReadinessProbe(
        powerSource: FakePower(),
        networkReachable: { true },
        commandAvailable: {
            trace.values.append("command:\($0)")
            return $0 == "codex"
        },
        applicationAvailable: {
            trace.values.append("application:\($0)")
            return false
        }
    )
    let requirements = WakeReadinessRequirements(targets: [
        .command(executable: "codex"),
        .application(bundleIdentifier: "com.openai.codex"),
    ])
    let snapshot = probe.snapshot(for: requirements)
    #expect(trace.values == ["command:codex", "application:com.openai.codex"])
    #expect(snapshot.availableCommands == ["codex"])
    #expect(snapshot.availableApplications.isEmpty)
}

private func task(_ id: String, timeout: TimeInterval = 60) -> UnattendedTaskDefinition {
    UnattendedTaskDefinition(
        id: id,
        name: "Task \(id)",
        automationID: "automation-\(id)",
        target: .command(executable: "codex", arguments: ["synthetic-input"]),
        timeout: timeout
    )
}

private func terminalSummary(
    _ phases: UnattendedTaskPhase...
) -> UnattendedTaskSummary {
    UnattendedTaskSummary(executions: phases.enumerated().map { index, phase in
        UnattendedTaskExecution(task: task("summary-\(index)"), phase: phase)
    })
}

@Test func successfulLaunchBatchMayAwaitAnAgentLease() {
    let summary = terminalSummary(.succeeded, .succeeded)

    #expect(UnattendedLeaseHandoffPolicy.disposition(for: summary) == .awaitLease)
}

@Test func emptyLaunchBatchMustFailPreparation() {
    let summary = terminalSummary()

    #expect(UnattendedLeaseHandoffPolicy.disposition(for: summary) == .failPreparation)
}

@Test func failedLaunchBatchMustFailPreparation() {
    let summary = terminalSummary(.failed)

    #expect(UnattendedLeaseHandoffPolicy.disposition(for: summary) == .failPreparation)
}

@Test func timedOutLaunchBatchMustFailPreparation() {
    let summary = terminalSummary(.timedOut)

    #expect(UnattendedLeaseHandoffPolicy.disposition(for: summary) == .failPreparation)
}

@Test func cancelledLaunchBatchMustFailPreparation() {
    let summary = terminalSummary(.cancelled)

    #expect(UnattendedLeaseHandoffPolicy.disposition(for: summary) == .failPreparation)
}

@Test func mixedLaunchBatchMustFailPreparation() {
    let summary = terminalSummary(.succeeded, .failed, .timedOut, .cancelled)

    #expect(UnattendedLeaseHandoffPolicy.disposition(for: summary) == .failPreparation)
}

@MainActor
@Test func concurrentTasksMustAllBecomeTerminalBeforeSleep() {
    let launcher = FakeTaskLauncher()
    launcher.scriptedStatuses = [
        "a": [.succeeded],
        "b": [.running, .failed(exitCode: 7, reason: nil)],
    ]
    let diagnostics = FakeUnattendedDiagnostics()
    let coordinator = UnattendedTaskCoordinator(launcher: launcher, diagnostics: diagnostics)

    coordinator.start([task("a"), task("b")], at: testDate)
    #expect(coordinator.sleepEligibility == .waiting(activeTaskCount: 2))
    coordinator.tick(at: testDate.addingTimeInterval(1))
    #expect(coordinator.executions.map(\.phase) == [.succeeded, .started])
    #expect(coordinator.sleepEligibility == .waiting(activeTaskCount: 1))
    coordinator.tick(at: testDate.addingTimeInterval(2))

    #expect(coordinator.executions.map(\.phase) == [.succeeded, .failed])
    #expect(coordinator.sleepEligibility == .eligible(terminalTaskCount: 2))
    #expect(diagnostics.events.filter { $0.kind == .sleepEligible }.count == 1)
    #expect(diagnostics.events.allSatisfy { event in
        event.taskID == nil || !event.taskID!.contains("synthetic-input")
    })
}

@MainActor
@Test func runningTaskTimesOutAndIsCancelled() {
    let launcher = FakeTaskLauncher()
    launcher.scriptedStatuses["slow"] = [.running]
    let diagnostics = FakeUnattendedDiagnostics()
    let coordinator = UnattendedTaskCoordinator(launcher: launcher, diagnostics: diagnostics)

    coordinator.start([task("slow", timeout: 5)], at: testDate)
    coordinator.tick(at: testDate.addingTimeInterval(4))
    #expect(coordinator.sleepEligibility == .waiting(activeTaskCount: 1))
    coordinator.tick(at: testDate.addingTimeInterval(5))

    #expect(coordinator.executions[0].phase == .timedOut)
    #expect(launcher.cancelledTaskIDs == ["slow"])
    #expect(coordinator.sleepEligibility == .eligible(terminalTaskCount: 1))
    #expect(diagnostics.events.map(\.kind).contains(.taskTimedOut))
}

@MainActor
@Test func cancellationMarksEveryActiveTaskTerminal() {
    let launcher = FakeTaskLauncher()
    let diagnostics = FakeUnattendedDiagnostics()
    let coordinator = UnattendedTaskCoordinator(launcher: launcher, diagnostics: diagnostics)

    coordinator.start([task("a"), task("b")], at: testDate)
    coordinator.cancelAll(at: testDate.addingTimeInterval(1))

    #expect(coordinator.executions.map(\.phase) == [.cancelled, .cancelled])
    #expect(Set(launcher.cancelledTaskIDs) == ["a", "b"])
    #expect(coordinator.sleepEligibility == .eligible(terminalTaskCount: 2))
    #expect(diagnostics.events.filter { $0.kind == .taskCancelled }.count == 2)
}

@MainActor
@Test func launchFailureIsTerminalButDoesNotHideOtherActiveTasks() {
    let launcher = FakeTaskLauncher()
    launcher.failures["broken"] = "launch-failed"
    launcher.scriptedStatuses["working"] = [.running, .succeeded]
    let coordinator = UnattendedTaskCoordinator(launcher: launcher)

    coordinator.start([task("broken"), task("working")], at: testDate)
    #expect(coordinator.executions.map(\.phase) == [.failed, .started])
    #expect(coordinator.sleepEligibility == .waiting(activeTaskCount: 1))
    coordinator.tick(at: testDate.addingTimeInterval(1))
    #expect(coordinator.sleepEligibility == .waiting(activeTaskCount: 1))
    coordinator.tick(at: testDate.addingTimeInterval(2))
    #expect(coordinator.sleepEligibility == .eligible(terminalTaskCount: 2))
}

@MainActor
@Test func combinedControllerHoldsIntentUntilEveryTaskFinishes() {
    let intent = FakeWakeIntent()
    let probe = FakeWakeProbe([readySnapshot()])
    let launcher = FakeTaskLauncher()
    launcher.scriptedStatuses = [
        "first": [.succeeded],
        "second": [.running, .succeeded],
    ]
    let diagnostics = FakeUnattendedDiagnostics()
    let controller = UnattendedOrchestrationController(
        intent: intent,
        probe: probe,
        launcher: launcher,
        diagnostics: diagnostics
    )

    controller.begin(tasks: [task("first"), task("second")], at: testDate)
    #expect(intent.values == [true])
    controller.tick(at: testDate)
    #expect(controller.state == .running)
    #expect(controller.tasks.executions.map(\.phase) == [.succeeded, .started])
    #expect(intent.values == [true])

    controller.tick(at: testDate.addingTimeInterval(1))
    #expect(controller.state == .completed(UnattendedTaskSummary(
        executions: controller.tasks.executions
    )))
    #expect(controller.state.isSleepEligible)
    #expect(intent.values == [true, false])
    #expect(diagnostics.events.map(\.kind).contains(.sleepEligible))
}

@MainActor
@Test func combinedControllerMakesReadinessFailureSleepEligible() {
    let intent = FakeWakeIntent()
    let probe = FakeWakeProbe([readySnapshot(network: false)])
    let launcher = FakeTaskLauncher()
    let controller = UnattendedOrchestrationController(
        intent: intent,
        probe: probe,
        launcher: launcher,
        readinessPolicy: WakeReadinessPolicy(timeout: 0)
    )

    controller.begin(tasks: [task("never-started")], at: testDate)
    controller.tick(at: testDate)

    #expect(controller.state == .readinessFailed([.networkUnavailable]))
    #expect(controller.state.isSleepEligible)
    #expect(launcher.startedTaskIDs.isEmpty)
    #expect(intent.values == [true, false])
}
