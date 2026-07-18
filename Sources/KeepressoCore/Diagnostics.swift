import Foundation
import Observation
import IOKit.pwr_mgt

// MARK: - Unattended orchestration diagnostics

/// Stable event kinds for unattended wake and task orchestration. Events carry
/// identifiers and state only. Automation prompts and command arguments are
/// deliberately absent from this API.
public enum UnattendedDiagnosticKind: String, Codable, Equatable, Sendable {
    case discoveryCompleted
    case discoveryFailed
    case wakePlanned
    case wakePreparationStarted
    case readinessRetryScheduled
    case readinessReady
    case readinessTimedOut
    case taskStarted
    case taskSucceeded
    case taskFailed
    case taskTimedOut
    case taskCancelled
    case sleepEligible
    case orchestrationCancelled
}

/// One structured diagnostic event. This is intentionally not a free-form log
/// message, which prevents sensitive task input from being copied into logs.
public struct UnattendedDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: UnattendedDiagnosticKind
    public var automationID: String?
    public var taskID: String?
    public var scheduledRun: Date?
    public var scheduledWake: Date?
    public var attempt: Int?
    public var readinessIssues: [WakeReadinessIssue]
    public var taskPhase: UnattendedTaskPhase?
    public var taskCount: Int?
    public var automationCount: Int?
    public var issueCount: Int?

    public init(
        id: UUID = UUID(),
        date: Date,
        kind: UnattendedDiagnosticKind,
        automationID: String? = nil,
        taskID: String? = nil,
        scheduledRun: Date? = nil,
        scheduledWake: Date? = nil,
        attempt: Int? = nil,
        readinessIssues: [WakeReadinessIssue] = [],
        taskPhase: UnattendedTaskPhase? = nil,
        taskCount: Int? = nil,
        automationCount: Int? = nil,
        issueCount: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.automationID = automationID
        self.taskID = taskID
        self.scheduledRun = scheduledRun
        self.scheduledWake = scheduledWake
        self.attempt = attempt
        self.readinessIssues = readinessIssues
        self.taskPhase = taskPhase
        self.taskCount = taskCount
        self.automationCount = automationCount
        self.issueCount = issueCount
    }
}

public protocol UnattendedDiagnosticRecording: AnyObject, Sendable {
    func record(_ event: UnattendedDiagnosticEvent)
}

/// Default recorder for hosts that do not surface unattended diagnostics yet.
public final class NullUnattendedDiagnosticRecorder: UnattendedDiagnosticRecording, @unchecked Sendable {
    public init() {}
    public func record(_ event: UnattendedDiagnosticEvent) {}
}

// MARK: - Decision log

/// What initiated a session start or stop, for the decision log.
public enum SessionCause: Equatable, Sendable {
    /// The menu toggle or another in-app control.
    case manual
    /// A `keepresso://` URL or a Shortcuts action.
    case command
}

/// Machine-readable kind of a session decision, for outbound event hooks and
/// anything else that must not parse the localized ``SessionEvent/reason``.
public enum SessionEventKind: String, Codable, Equatable, Sendable {
    case sessionStarted
    case sessionEnded
    case triggerFired
    case triggerReleased
    case batteryPaused
    case thermalPaused
    case startRefused
}

/// One entry in the decision log: the session began or ended, when, and why.
public struct SessionEvent: Equatable, Identifiable, Sendable {
    public var id: Int
    public var date: Date
    /// `true` when the session started, `false` when it ended.
    public var began: Bool
    /// Human-readable cause, snapshotted at event time ("Started manually",
    /// "Triggers: Camera in use", "Timed session ended").
    public var reason: String
    /// Stable kind for hooks and automation. Optional so older synthetic
    /// events in tests still decode; production always sets it.
    public var kind: SessionEventKind?
    /// Battery percent at event time when discharging, for awake stats.
    public var batteryPercent: Int?

    public init(
        id: Int,
        date: Date,
        began: Bool,
        reason: String,
        kind: SessionEventKind? = nil,
        batteryPercent: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.began = began
        self.reason = reason
        self.kind = kind
        self.batteryPercent = batteryPercent
    }
}

/// A bounded, observable log of the controller's session decisions, answering
/// "why did Keepresso turn on or off?" without digging through Console. Held
/// by ``SessionController``. The newest ``capacity`` events live in memory;
/// the host also persists them via ``DecisionLogPersister`` so Activity
/// survives a relaunch.
@MainActor
@Observable
public final class DecisionLog {
    /// Oldest entries fall off past this count in memory.
    public static let capacity = 100

    /// Events oldest-first. The UI shows them reversed.
    public private(set) var events: [SessionEvent] = []
    private var nextID = 0

    /// Called after every recorded event so the host can drive outbound hooks
    /// and persistence without polling. Tests leave it nil.
    public var onRecord: ((SessionEvent) -> Void)?

    public init() {}

    /// Seed the in-memory log from disk (oldest first). Does not re-fire
    /// ``onRecord`` (would re-append to the file and re-run hooks).
    public func load(_ persisted: [PersistedSessionEvent]) {
        events = persisted.enumerated().map { index, item in
            SessionEvent(
                id: index,
                date: item.date,
                began: item.began,
                reason: item.reason,
                kind: item.kind,
                batteryPercent: item.batteryPercent
            )
        }
        nextID = events.count
    }

    public func record(
        began: Bool,
        reason: String,
        kind: SessionEventKind? = nil,
        batteryPercent: Int? = nil,
        at date: Date
    ) {
        let event = SessionEvent(
            id: nextID,
            date: date,
            began: began,
            reason: reason,
            kind: kind,
            batteryPercent: batteryPercent
        )
        events.append(event)
        nextID += 1
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
        onRecord?(event)
    }
}

// MARK: - System power assertions

/// One live power assertion held by some process, answering "why is my Mac
/// not sleeping right now?" even when it isn't Keepresso's doing.
public struct PowerAssertionInfo: Equatable, Identifiable, Sendable {
    public var id: String
    public var pid: Int32
    /// The owning process, e.g. "Google Chrome" or "coreaudiod".
    public var processName: String
    /// The raw IOPM assertion type, e.g. "PreventUserIdleDisplaySleep".
    public var type: String
    /// The assertion's own name string, the reason its creator supplied.
    public var name: String

    public init(id: String, pid: Int32, processName: String, type: String, name: String) {
        self.id = id
        self.pid = pid
        self.processName = processName
        self.type = type
        self.name = name
    }

    /// A friendly description of what this assertion does to sleep, or `nil`
    /// for bookkeeping types that don't hold the Mac awake (those are hidden
    /// by the UI).
    public var effect: String? { Self.effects[type].map(L) }

    static let effects: [String: String] = [
        "PreventUserIdleSystemSleep": "Preventing system sleep",
        "PreventUserIdleDisplaySleep": "Preventing display sleep",
        "PreventSystemSleep": "Preventing system sleep",
        "NoIdleSleepAssertion": "Preventing system sleep",
        "NoDisplaySleepAssertion": "Preventing display sleep",
        "PreventDiskIdle": "Keeping disks awake",
        "UserIsActive": "Declaring the user active",
        "BackgroundTask": "Holding off idle sleep for a background task",
    ]
}

/// Abstraction over the system-wide assertion list so the UI layer and tests
/// don't touch IOKit directly. Mirrors the other system seams.
public protocol AssertionListing: AnyObject {
    /// Every assertion currently registered with powerd, across all processes.
    func current() -> [PowerAssertionInfo]
}

/// Real backend over `IOPMCopyAssertionsByProcess`, the same data
/// `pmset -g assertions` prints. Read-only and unprivileged.
public final class IOPMAssertionLister: AssertionListing {
    public init() {}

    public func current() -> [PowerAssertionInfo] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as NSDictionary?
        else { return [] }

        var infos: [PowerAssertionInfo] = []
        for (key, value) in byProcess {
            guard let pid = (key as? NSNumber)?.int32Value,
                  let assertions = value as? [[String: Any]] else { continue }
            for (index, assertion) in assertions.enumerated() {
                let type = assertion[kIOPMAssertionTypeKey as String] as? String ?? "Unknown"
                let name = assertion[kIOPMAssertionNameKey as String] as? String ?? ""
                // "Process Name" is in the assertion details on current macOS;
                // fall back to a libproc lookup when absent.
                let process = assertion["Process Name"] as? String ?? Self.processName(for: pid)
                infos.append(PowerAssertionInfo(
                    id: "\(pid)-\(index)-\(type)",
                    pid: pid,
                    processName: process,
                    type: type,
                    name: name
                ))
            }
        }
        return infos.sorted { ($0.processName, $0.type, $0.id) < ($1.processName, $1.type, $1.id) }
    }

    static func processName(for pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }
}
