import Foundation

/// Something that happened inside Keepresso that an outbound hook can react to.
public enum HookEvent: String, Codable, CaseIterable, Sendable {
    case sessionStarted
    case sessionEnded
    case triggerFired
    case triggerReleased
    case batteryPaused
    case thermalPaused
    case thermalStageChanged
    case agentWentIdle

    /// A Preferences-row label.
    public var label: String {
        switch self {
        case .sessionStarted:       return L("Session started")
        case .sessionEnded:         return L("Session ended")
        case .triggerFired:         return L("Trigger fired")
        case .triggerReleased:      return L("Trigger released")
        case .batteryPaused:        return L("Battery pause")
        case .thermalPaused:        return L("Thermal pause")
        case .thermalStageChanged:  return L("Thermal stage changed")
        case .agentWentIdle:        return L("Agent went idle")
        }
    }
}

/// What an ``EventHook`` runs when its event fires.
public enum HookAction: Codable, Equatable, Sendable {
    /// Run a Shortcut by name (`shortcuts run "Name"`).
    case runShortcut(name: String)
    /// POST an empty body to a URL (ntfy, a webhook, …).
    case webhook(url: String)
    /// Run a shell command through `/bin/sh -c`.
    case shell(command: String)

    public var label: String {
        switch self {
        case .runShortcut(let name): return L("Shortcut: %@", name)
        case .webhook(let url):      return L("Webhook: %@", url)
        case .shell(let command):    return L("Command: %@", command)
        }
    }
}

/// One user-authored "on event, do action" rule, persisted in settings.
public struct EventHook: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Whether this hook is live. Disabled hooks stay in the list for editing.
    public var enabled: Bool
    public var event: HookEvent
    public var action: HookAction

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        event: HookEvent,
        action: HookAction
    ) {
        self.id = id
        self.enabled = enabled
        self.event = event
        self.action = action
    }
}

/// Performs a ``HookAction``. Seam so tests drive synthetic events through a
/// fake without shelling out.
public protocol HookRunning: AnyObject {
    func run(_ action: HookAction)
}

/// Pure mapping from a decision-log kind to the hook events it raises. Free
/// of actor isolation so tests and the runner share it without hopping.
public enum EventHookPolicy {
    /// How long after a hook fires before the same hook may fire again.
    public static let debounce: TimeInterval = 2
    /// How long a shell or shortcut may run before being abandoned.
    public static let runTimeout: TimeInterval = 30

    /// Which hook events a decision-log kind should raise. A trigger release
    /// is also a session end; a battery pause is also a session end, so a
    /// user who only subscribed to "session ended" still hears them.
    public static func hookEvents(for kind: SessionEventKind?) -> [HookEvent] {
        switch kind {
        case .sessionStarted:
            return [.sessionStarted]
        case .sessionEnded:
            return [.sessionEnded]
        case .triggerFired:
            return [.triggerFired, .sessionStarted]
        case .triggerReleased:
            return [.triggerReleased, .sessionEnded]
        case .batteryPaused:
            return [.batteryPaused, .sessionEnded]
        case .thermalPaused:
            return [.thermalPaused, .sessionEnded]
        case .startRefused, .none:
            return []
        }
    }
}

/// Maps decision-log events (and a few app-side signals) to matching hooks,
/// with per-hook debounce. The host feeds it events; it never observes the
/// world itself. Main-actor because it is owned by ``AppModel``.
@MainActor
public final class EventHookDispatcher {
    public static let debounce = EventHookPolicy.debounce
    public static let runTimeout = EventHookPolicy.runTimeout

    public var hooks: [EventHook] = []
    /// When true, no hooks run (settings mid-edit). The host sets this around
    /// the Automation tab's add/edit sheet so a half-written command is never
    /// executed by a live event.
    public var isSuspended = false

    private let runner: HookRunning
    private let now: () -> Date
    private var lastFired: [UUID: Date] = [:]

    public init(runner: HookRunning, now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.now = now
    }

    /// Feed a decision-log entry. Maps its ``SessionEvent/kind`` onto one or
    /// more ``HookEvent``s and runs matching hooks.
    public func handle(sessionEvent event: SessionEvent) {
        for hookEvent in EventHookPolicy.hookEvents(for: event.kind) {
            fire(hookEvent)
        }
    }

    /// Fire a non-decision-log event (thermal stage change, agent idle).
    public func fire(_ event: HookEvent) {
        guard !isSuspended else { return }
        let instant = now()
        for hook in hooks where hook.enabled && hook.event == event {
            if let last = lastFired[hook.id],
               instant.timeIntervalSince(last) < EventHookPolicy.debounce {
                continue
            }
            lastFired[hook.id] = instant
            runner.run(hook.action)
        }
    }
}

/// Real runner: Shortcuts via `/usr/bin/shortcuts`, webhooks via URLSession,
/// shell via `/bin/sh -c`. User-authored commands are intentional in an
/// unsandboxed power-user app. Every path is best-effort and timed out.
public final class SystemHookRunner: HookRunning, @unchecked Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = EventHookPolicy.runTimeout) {
        self.timeout = timeout
    }

    public func run(_ action: HookAction) {
        switch action {
        case .runShortcut(let name):
            runProcess("/usr/bin/shortcuts", arguments: ["run", name])
        case .webhook(let urlString):
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            // Fire and forget: a webhook that hangs must not block the main
            // actor. URLSession's own timeout bounds the request.
            let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
            task.resume()
        case .shell(let command):
            runProcess("/bin/sh", arguments: ["-c", command])
        }
    }

    private func runProcess(_ path: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return
        }
        // Bound wait so a hung shortcut or shell can't pin a caller. The
        // process is left running if it overruns: killing user work mid-flight
        // is worse than a brief orphan, and launchd/session cleanup reaps it.
        let deadline = DispatchTime.now() + timeout
        let box = ProcessWaitBox(process)
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.wait()
            sem.signal()
        }
        _ = sem.wait(timeout: deadline)
    }
}

/// Tiny wrapper so a process can be waited on from a background queue without
/// capturing a non-Sendable Process across isolation (Process is a class).
private final class ProcessWaitBox: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func wait() { process.waitUntilExit() }
}
