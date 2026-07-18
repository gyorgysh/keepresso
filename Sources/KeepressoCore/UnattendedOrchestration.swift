import AppKit
import Foundation
import Observation
import SystemConfiguration

// MARK: - Launch targets

/// A local action started after a scheduled wake becomes ready. Command
/// arguments are used only by the launcher and are never copied into
/// unattended diagnostics.
public enum UnattendedLaunchTarget: Equatable, Hashable, Sendable {
    case command(executable: String, arguments: [String] = [], workingDirectory: URL? = nil)
    case application(bundleIdentifier: String)
}

public struct UnattendedTaskDefinition: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var automationID: String?
    public var target: UnattendedLaunchTarget
    public var timeout: TimeInterval

    public init(
        id: String,
        name: String,
        automationID: String? = nil,
        target: UnattendedLaunchTarget,
        timeout: TimeInterval = 60 * 60
    ) {
        self.id = id
        self.name = name
        self.automationID = automationID
        self.target = target
        self.timeout = max(1, timeout)
    }
}

// MARK: - Wake readiness

public struct WakePowerPolicy: Equatable, Sendable {
    public var requireExternalPower: Bool
    public var minimumBatteryPercentage: Int?

    public init(
        requireExternalPower: Bool = false,
        minimumBatteryPercentage: Int? = nil
    ) {
        self.requireExternalPower = requireExternalPower
        self.minimumBatteryPercentage = minimumBatteryPercentage.map { min(100, max(0, $0)) }
    }
}

public struct WakeReadinessRequirements: Equatable, Sendable {
    public var powerPolicy: WakePowerPolicy
    public var networkRequired: Bool
    public var targets: [UnattendedLaunchTarget]

    public init(
        powerPolicy: WakePowerPolicy = WakePowerPolicy(),
        networkRequired: Bool = true,
        targets: [UnattendedLaunchTarget] = []
    ) {
        self.powerPolicy = powerPolicy
        self.networkRequired = networkRequired
        self.targets = targets
    }

    public init(
        tasks: [UnattendedTaskDefinition],
        powerPolicy: WakePowerPolicy = WakePowerPolicy(),
        networkRequired: Bool = true
    ) {
        self.init(
            powerPolicy: powerPolicy,
            networkRequired: networkRequired,
            targets: tasks.map(\.target)
        )
    }
}

public struct WakeReadinessSnapshot: Equatable, Sendable {
    public var power: PowerSourceSnapshot
    public var networkReachable: Bool?
    public var availableCommands: Set<String>
    public var availableApplications: Set<String>

    public init(
        power: PowerSourceSnapshot,
        networkReachable: Bool?,
        availableCommands: Set<String> = [],
        availableApplications: Set<String> = []
    ) {
        self.power = power
        self.networkReachable = networkReachable
        self.availableCommands = availableCommands
        self.availableApplications = availableApplications
    }
}

public enum WakeReadinessIssue: Codable, Equatable, Hashable, Sendable {
    case externalPowerRequired
    case powerSourceUnknown
    case batteryLevelUnknown
    case batteryBelowMinimum(actual: Int, required: Int)
    case networkUnavailable
    case networkStateUnknown
    case commandUnavailable(String)
    case applicationUnavailable(String)
}

public protocol WakeReadinessProbing: AnyObject, Sendable {
    func snapshot(for requirements: WakeReadinessRequirements) -> WakeReadinessSnapshot
}

/// Controls the keep-awake intent that must exist before any wake-time probe.
/// The app can adapt this to its normal session controller or a lease manager.
public protocol WakeKeepAliveIntentControlling: AnyObject, Sendable {
    func setKeepAliveIntended(_ intended: Bool)
}

public struct WakeReadinessPolicy: Equatable, Sendable {
    public var timeout: TimeInterval
    public var initialRetryDelay: TimeInterval
    public var retryMultiplier: Double
    public var maximumRetryDelay: TimeInterval

    public init(
        timeout: TimeInterval = 2 * 60,
        initialRetryDelay: TimeInterval = 2,
        retryMultiplier: Double = 2,
        maximumRetryDelay: TimeInterval = 15
    ) {
        self.timeout = max(0, timeout)
        self.initialRetryDelay = max(0.1, initialRetryDelay)
        self.retryMultiplier = max(1, retryMultiplier)
        self.maximumRetryDelay = max(0.1, maximumRetryDelay)
    }

    fileprivate func delay(afterAttempt attempt: Int) -> TimeInterval {
        min(maximumRetryDelay, initialRetryDelay * pow(retryMultiplier, Double(max(0, attempt - 1))))
    }
}

public enum WakeReadinessState: Equatable, Sendable {
    case idle
    case waiting(attempt: Int, nextAttemptAt: Date, deadline: Date, issues: [WakeReadinessIssue])
    case ready(at: Date)
    case timedOut(at: Date, issues: [WakeReadinessIssue])
    case cancelled(at: Date)
    case finished(at: Date)
}

/// Timer-injected wake readiness state machine. `begin` establishes the
/// keep-alive intent first. The host then calls `tick(at:)` until the state is
/// ready or terminal.
@MainActor
@Observable
public final class WakeReadinessController {
    public private(set) var state: WakeReadinessState = .idle

    private let intent: any WakeKeepAliveIntentControlling
    private let probe: any WakeReadinessProbing
    private let policy: WakeReadinessPolicy
    private let diagnostics: any UnattendedDiagnosticRecording
    private var requirements = WakeReadinessRequirements()
    private var intentIsActive = false

    public init(
        intent: any WakeKeepAliveIntentControlling,
        probe: any WakeReadinessProbing,
        policy: WakeReadinessPolicy = WakeReadinessPolicy(),
        diagnostics: any UnattendedDiagnosticRecording = NullUnattendedDiagnosticRecorder()
    ) {
        self.intent = intent
        self.probe = probe
        self.policy = policy
        self.diagnostics = diagnostics
    }

    public func begin(requirements: WakeReadinessRequirements, at date: Date) {
        self.requirements = requirements
        setIntent(true)
        state = .waiting(
            attempt: 0,
            nextAttemptAt: date,
            deadline: date.addingTimeInterval(policy.timeout),
            issues: []
        )
        diagnostics.record(UnattendedDiagnosticEvent(date: date, kind: .wakePreparationStarted))
    }

    public func tick(at date: Date) {
        guard case let .waiting(previousAttempt, nextAttemptAt, deadline, _) = state,
              date >= nextAttemptAt
        else { return }

        let attempt = previousAttempt + 1
        let snapshot = probe.snapshot(for: requirements)
        let issues = Self.evaluate(snapshot, against: requirements)
        if issues.isEmpty {
            state = .ready(at: date)
            diagnostics.record(UnattendedDiagnosticEvent(
                date: date,
                kind: .readinessReady,
                attempt: attempt
            ))
            return
        }

        if date >= deadline {
            state = .timedOut(at: date, issues: issues)
            setIntent(false)
            diagnostics.record(UnattendedDiagnosticEvent(
                date: date,
                kind: .readinessTimedOut,
                attempt: attempt,
                readinessIssues: issues
            ))
            return
        }

        let next = min(deadline, date.addingTimeInterval(policy.delay(afterAttempt: attempt)))
        state = .waiting(attempt: attempt, nextAttemptAt: next, deadline: deadline, issues: issues)
        diagnostics.record(UnattendedDiagnosticEvent(
            date: date,
            kind: .readinessRetryScheduled,
            attempt: attempt,
            readinessIssues: issues
        ))
    }

    public func finish(at date: Date) {
        setIntent(false)
        state = .finished(at: date)
    }

    public func cancel(at date: Date) {
        setIntent(false)
        state = .cancelled(at: date)
        diagnostics.record(UnattendedDiagnosticEvent(date: date, kind: .orchestrationCancelled))
    }

    public nonisolated static func evaluate(
        _ snapshot: WakeReadinessSnapshot,
        against requirements: WakeReadinessRequirements
    ) -> [WakeReadinessIssue] {
        var issues: [WakeReadinessIssue] = []
        if requirements.powerPolicy.requireExternalPower {
            switch snapshot.power.provider {
            case .ac: break
            case .battery: issues.append(.externalPowerRequired)
            case .unknown: issues.append(.powerSourceUnknown)
            }
        }
        if let minimum = requirements.powerPolicy.minimumBatteryPercentage {
            switch snapshot.power.provider {
            case .ac:
                break
            case .battery:
                if let actual = snapshot.power.percentage {
                    if actual < minimum {
                        issues.append(.batteryBelowMinimum(actual: actual, required: minimum))
                    }
                } else {
                    issues.append(.batteryLevelUnknown)
                }
            case .unknown:
                if !issues.contains(.powerSourceUnknown) {
                    issues.append(.powerSourceUnknown)
                }
            }
        }
        if requirements.networkRequired {
            switch snapshot.networkReachable {
            case true: break
            case false: issues.append(.networkUnavailable)
            case nil: issues.append(.networkStateUnknown)
            }
        }

        var seenCommands: Set<String> = []
        var seenApplications: Set<String> = []
        for target in requirements.targets {
            switch target {
            case let .command(executable, _, _):
                guard seenCommands.insert(executable).inserted else { continue }
                if !snapshot.availableCommands.contains(executable) {
                    issues.append(.commandUnavailable(executable))
                }
            case let .application(bundleIdentifier):
                guard seenApplications.insert(bundleIdentifier).inserted else { continue }
                if !snapshot.availableApplications.contains(bundleIdentifier) {
                    issues.append(.applicationUnavailable(bundleIdentifier))
                }
            }
        }
        return issues
    }

    private func setIntent(_ active: Bool) {
        guard active != intentIsActive else { return }
        intent.setKeepAliveIntended(active)
        intentIsActive = active
    }
}

/// Real readiness snapshot provider. Every system touch remains behind the
/// `WakeReadinessProbing` seam, and the individual probes are injectable for
/// focused integration tests.
public final class SystemWakeReadinessProbe: WakeReadinessProbing, @unchecked Sendable {
    private let powerSource: any PowerSourceMonitoring
    private let networkReachable: @Sendable () -> Bool?
    private let commandAvailable: @Sendable (String) -> Bool
    private let applicationAvailable: @Sendable (String) -> Bool

    public init(
        powerSource: any PowerSourceMonitoring = IOKitPowerSourceMonitor(),
        networkReachable: (@Sendable () -> Bool?)? = nil,
        commandAvailable: (@Sendable (String) -> Bool)? = nil,
        applicationAvailable: (@Sendable (String) -> Bool)? = nil
    ) {
        self.powerSource = powerSource
        self.networkReachable = networkReachable ?? { SystemWakeReadinessProbe.reachable() }
        self.commandAvailable = commandAvailable ?? { CommandLocator.resolve($0) != nil }
        self.applicationAvailable = applicationAvailable ?? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    public func snapshot(for requirements: WakeReadinessRequirements) -> WakeReadinessSnapshot {
        var commands: Set<String> = []
        var applications: Set<String> = []
        for target in requirements.targets {
            switch target {
            case let .command(executable, _, _):
                if commandAvailable(executable) { commands.insert(executable) }
            case let .application(bundleIdentifier):
                if applicationAvailable(bundleIdentifier) { applications.insert(bundleIdentifier) }
            }
        }
        return WakeReadinessSnapshot(
            power: powerSource.current,
            networkReachable: requirements.networkRequired ? networkReachable() : true,
            availableCommands: commands,
            availableApplications: applications
        )
    }

    private static func reachable() -> Bool? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let reachability = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }
        guard let reachability else { return nil }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else { return nil }
        let reachable = flags.contains(.reachable)
        let connectionRequired = flags.contains(.connectionRequired)
        return reachable && !connectionRequired
    }
}

private enum CommandLocator {
    static func resolve(
        _ executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        files: FileManager = .default
    ) -> URL? {
        guard !executable.isEmpty else { return nil }
        if executable.contains("/") {
            return files.isExecutableFile(atPath: executable)
                ? URL(fileURLWithPath: executable)
                : nil
        }
        let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(executable, isDirectory: false)
            if files.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

// MARK: - Task launching and tracking

public struct UnattendedTaskHandle: Equatable, Hashable, Sendable {
    public var id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public enum UnattendedTaskStartResult: Equatable, Sendable {
    case started(UnattendedTaskHandle)
    case failed(String)
}

public enum UnattendedTaskPollStatus: Equatable, Sendable {
    case running
    case succeeded
    case failed(exitCode: Int32?, reason: String?)
}

public protocol UnattendedTaskLaunching: AnyObject, Sendable {
    func start(_ task: UnattendedTaskDefinition) -> UnattendedTaskStartResult
    func status(of handle: UnattendedTaskHandle) -> UnattendedTaskPollStatus
    func cancel(_ handle: UnattendedTaskHandle)
}

/// Local launcher for commands and installed applications. Output is discarded
/// and never enters diagnostics. Application tasks succeed once LaunchServices
/// confirms that the application opened.
public final class SystemUnattendedTaskLauncher: UnattendedTaskLaunching, @unchecked Sendable {
    private enum RuntimeState {
        case running(Process?)
        case succeeded
        case failed(Int32?, String?)
        case cancelled
    }

    private let commandURL: @Sendable (String) -> URL?
    private let applicationURL: @Sendable (String) -> URL?
    private let workspace: NSWorkspace
    private let lock = NSLock()
    private var records: [UnattendedTaskHandle: RuntimeState] = [:]

    public init(
        commandURL: (@Sendable (String) -> URL?)? = nil,
        applicationURL: (@Sendable (String) -> URL?)? = nil,
        workspace: NSWorkspace = .shared
    ) {
        self.commandURL = commandURL ?? { CommandLocator.resolve($0) }
        self.applicationURL = applicationURL ?? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        self.workspace = workspace
    }

    public func start(_ task: UnattendedTaskDefinition) -> UnattendedTaskStartResult {
        switch task.target {
        case let .command(executable, arguments, workingDirectory):
            guard let executableURL = commandURL(executable) else {
                return .failed("command-unavailable")
            }
            let handle = UnattendedTaskHandle()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] finished in
                self?.complete(handle, status: finished.terminationStatus)
            }
            withLock { records[handle] = .running(process) }
            do {
                try process.run()
                return .started(handle)
            } catch {
                withLock { records[handle] = .failed(nil, "launch-failed") }
                return .failed("launch-failed")
            }

        case let .application(bundleIdentifier):
            guard let url = applicationURL(bundleIdentifier) else {
                return .failed("application-unavailable")
            }
            let handle = UnattendedTaskHandle()
            withLock { records[handle] = .running(nil) }
            workspace.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { [weak self] application, error in
                self?.withLock {
                    guard case .running? = self?.records[handle] else { return }
                    self?.records[handle] = error == nil && application != nil
                        ? .succeeded
                        : .failed(nil, "application-launch-failed")
                }
            }
            return .started(handle)
        }
    }

    public func status(of handle: UnattendedTaskHandle) -> UnattendedTaskPollStatus {
        withLock {
            switch records[handle] {
            case .running: return .running
            case .succeeded: return .succeeded
            case let .failed(code, reason): return .failed(exitCode: code, reason: reason)
            case .cancelled: return .failed(exitCode: nil, reason: "cancelled")
            case nil: return .failed(exitCode: nil, reason: "unknown-handle")
            }
        }
    }

    public func cancel(_ handle: UnattendedTaskHandle) {
        let process: Process? = withLock {
            guard case let .running(active)? = records[handle] else { return nil }
            records[handle] = .cancelled
            return active
        }
        if process?.isRunning == true { process?.terminate() }
    }

    private func complete(_ handle: UnattendedTaskHandle, status: Int32) {
        withLock {
            guard case .running? = records[handle] else { return }
            records[handle] = status == 0 ? .succeeded : .failed(status, "nonzero-exit")
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

public enum UnattendedTaskPhase: String, Codable, Equatable, Sendable {
    case pending
    case started
    case succeeded
    case failed
    case timedOut
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .timedOut, .cancelled: return true
        case .pending, .started: return false
        }
    }
}

public struct UnattendedTaskExecution: Equatable, Identifiable, Sendable {
    public var task: UnattendedTaskDefinition
    public var phase: UnattendedTaskPhase
    public var startedAt: Date?
    public var finishedAt: Date?
    public var detail: String?
    public var id: String { task.id }

    fileprivate var handle: UnattendedTaskHandle?

    public init(
        task: UnattendedTaskDefinition,
        phase: UnattendedTaskPhase = .pending,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        detail: String? = nil
    ) {
        self.task = task
        self.phase = phase
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.detail = detail
    }
}

public enum UnattendedSleepEligibility: Equatable, Sendable {
    case notStarted
    case waiting(activeTaskCount: Int)
    case eligible(terminalTaskCount: Int)
}

/// Tracks every launched task independently. Sleep becomes eligible only when
/// all tasks are terminal, including failures, timeouts, and cancellations.
@MainActor
@Observable
public final class UnattendedTaskCoordinator {
    public private(set) var executions: [UnattendedTaskExecution] = []
    public private(set) var sleepEligibility: UnattendedSleepEligibility = .notStarted

    private let launcher: any UnattendedTaskLaunching
    private let diagnostics: any UnattendedDiagnosticRecording
    private var recordedSleepEligibility = false

    public init(
        launcher: any UnattendedTaskLaunching,
        diagnostics: any UnattendedDiagnosticRecording = NullUnattendedDiagnosticRecorder()
    ) {
        self.launcher = launcher
        self.diagnostics = diagnostics
    }

    public func start(_ tasks: [UnattendedTaskDefinition], at date: Date) {
        cancelActive(at: date, recordDiagnostics: true)
        executions = tasks.map { UnattendedTaskExecution(task: $0) }
        recordedSleepEligibility = false

        for index in executions.indices {
            let task = executions[index].task
            switch launcher.start(task) {
            case let .started(handle):
                executions[index].handle = handle
                executions[index].phase = .started
                executions[index].startedAt = date
                diagnostics.record(UnattendedDiagnosticEvent(
                    date: date,
                    kind: .taskStarted,
                    automationID: task.automationID,
                    taskID: task.id,
                    taskPhase: .started
                ))
            case let .failed(reason):
                executions[index].phase = .failed
                executions[index].finishedAt = date
                executions[index].detail = reason
                diagnostics.record(UnattendedDiagnosticEvent(
                    date: date,
                    kind: .taskFailed,
                    automationID: task.automationID,
                    taskID: task.id,
                    taskPhase: .failed
                ))
            }
        }
        recomputeEligibility(at: date)
    }

    public func tick(at date: Date) {
        for index in executions.indices where executions[index].phase == .started {
            guard let handle = executions[index].handle else {
                mark(index, phase: .failed, detail: "missing-handle", at: date)
                continue
            }
            switch launcher.status(of: handle) {
            case .succeeded:
                mark(index, phase: .succeeded, at: date)
            case let .failed(exitCode, reason):
                let detail = reason ?? exitCode.map { "exit-\($0)" }
                mark(index, phase: .failed, detail: detail, at: date)
            case .running:
                guard let startedAt = executions[index].startedAt,
                      date.timeIntervalSince(startedAt) >= executions[index].task.timeout
                else { continue }
                launcher.cancel(handle)
                mark(index, phase: .timedOut, at: date)
            }
        }
        recomputeEligibility(at: date)
    }

    public func cancel(taskID: String, at date: Date) {
        for index in executions.indices where executions[index].task.id == taskID {
            guard !executions[index].phase.isTerminal else { continue }
            if let handle = executions[index].handle { launcher.cancel(handle) }
            mark(index, phase: .cancelled, at: date)
        }
        recomputeEligibility(at: date)
    }

    public func cancelAll(at date: Date) {
        cancelActive(at: date, recordDiagnostics: true)
        recomputeEligibility(at: date)
    }

    private func cancelActive(at date: Date, recordDiagnostics: Bool) {
        for index in executions.indices where !executions[index].phase.isTerminal {
            if let handle = executions[index].handle { launcher.cancel(handle) }
            executions[index].phase = .cancelled
            executions[index].finishedAt = date
            if recordDiagnostics {
                let task = executions[index].task
                diagnostics.record(UnattendedDiagnosticEvent(
                    date: date,
                    kind: .taskCancelled,
                    automationID: task.automationID,
                    taskID: task.id,
                    taskPhase: .cancelled
                ))
            }
        }
    }

    private func mark(
        _ index: Int,
        phase: UnattendedTaskPhase,
        detail: String? = nil,
        at date: Date
    ) {
        executions[index].phase = phase
        executions[index].finishedAt = date
        executions[index].detail = detail
        let task = executions[index].task
        let kind: UnattendedDiagnosticKind
        switch phase {
        case .succeeded: kind = .taskSucceeded
        case .failed: kind = .taskFailed
        case .timedOut: kind = .taskTimedOut
        case .cancelled: kind = .taskCancelled
        case .pending, .started: return
        }
        diagnostics.record(UnattendedDiagnosticEvent(
            date: date,
            kind: kind,
            automationID: task.automationID,
            taskID: task.id,
            taskPhase: phase
        ))
    }

    private func recomputeEligibility(at date: Date) {
        let active = executions.filter { !$0.phase.isTerminal }.count
        if active > 0 {
            sleepEligibility = .waiting(activeTaskCount: active)
            return
        }
        sleepEligibility = .eligible(terminalTaskCount: executions.count)
        guard !recordedSleepEligibility else { return }
        recordedSleepEligibility = true
        diagnostics.record(UnattendedDiagnosticEvent(
            date: date,
            kind: .sleepEligible,
            taskCount: executions.count
        ))
    }
}

// MARK: - Combined orchestration

public struct UnattendedTaskSummary: Equatable, Sendable {
    public var succeeded: Int
    public var failed: Int
    public var timedOut: Int
    public var cancelled: Int

    public init(executions: [UnattendedTaskExecution]) {
        succeeded = executions.filter { $0.phase == .succeeded }.count
        failed = executions.filter { $0.phase == .failed }.count
        timedOut = executions.filter { $0.phase == .timedOut }.count
        cancelled = executions.filter { $0.phase == .cancelled }.count
    }
}

public enum UnattendedLeaseHandoffDisposition: Equatable, Sendable {
    case awaitLease
    case failPreparation
}

public enum UnattendedLeaseHandoffPolicy {
    /// A launch batch may hand off to an explicit agent lease only when every
    /// terminal task succeeded. Empty, failed, timed-out, cancelled, or mixed
    /// batches must release scheduled demand instead of extending wakefulness.
    public static func disposition(
        for summary: UnattendedTaskSummary
    ) -> UnattendedLeaseHandoffDisposition {
        guard summary.succeeded > 0,
              summary.failed == 0,
              summary.timedOut == 0,
              summary.cancelled == 0
        else { return .failPreparation }
        return .awaitLease
    }
}

public enum UnattendedOrchestrationState: Equatable, Sendable {
    case idle
    case preparing
    case running
    case completed(UnattendedTaskSummary)
    case readinessFailed([WakeReadinessIssue])
    case cancelled

    public var isSleepEligible: Bool {
        switch self {
        case .completed, .readinessFailed, .cancelled: return true
        case .idle, .preparing, .running: return false
        }
    }
}

/// Connects readiness to concurrent task tracking. It holds the keep-awake
/// intent continuously from `begin` until every task is terminal.
@MainActor
@Observable
public final class UnattendedOrchestrationController {
    public private(set) var state: UnattendedOrchestrationState = .idle
    public let readiness: WakeReadinessController
    public let tasks: UnattendedTaskCoordinator

    private var queuedTasks: [UnattendedTaskDefinition] = []

    public init(
        intent: any WakeKeepAliveIntentControlling,
        probe: any WakeReadinessProbing,
        launcher: any UnattendedTaskLaunching,
        readinessPolicy: WakeReadinessPolicy = WakeReadinessPolicy(),
        diagnostics: any UnattendedDiagnosticRecording = NullUnattendedDiagnosticRecorder()
    ) {
        readiness = WakeReadinessController(
            intent: intent,
            probe: probe,
            policy: readinessPolicy,
            diagnostics: diagnostics
        )
        tasks = UnattendedTaskCoordinator(launcher: launcher, diagnostics: diagnostics)
    }

    public func begin(
        tasks queuedTasks: [UnattendedTaskDefinition],
        requirements: WakeReadinessRequirements? = nil,
        at date: Date
    ) {
        if state == .running {
            tasks.cancelAll(at: date)
        }
        self.queuedTasks = queuedTasks
        state = .preparing
        readiness.begin(
            requirements: requirements ?? WakeReadinessRequirements(tasks: queuedTasks),
            at: date
        )
    }

    public func tick(at date: Date) {
        if state == .preparing {
            readiness.tick(at: date)
            switch readiness.state {
            case .ready:
                tasks.start(queuedTasks, at: date)
                state = .running
            case let .timedOut(_, issues):
                state = .readinessFailed(issues)
                return
            default:
                return
            }
        }

        guard state == .running else { return }
        tasks.tick(at: date)
        if case .eligible = tasks.sleepEligibility {
            readiness.finish(at: date)
            state = .completed(UnattendedTaskSummary(executions: tasks.executions))
        }
    }

    public func cancel(at date: Date) {
        tasks.cancelAll(at: date)
        readiness.cancel(at: date)
        state = .cancelled
    }
}
