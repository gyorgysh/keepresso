import AppIntents
import AppKit
import KeepressoCore

// The widget and Control Center intents, compiled into BOTH the app and the
// widget extension (project.yml adds this file to the appex target, the same
// sharing as BrandCupMark.swift). That dual membership is what makes
// `openAppWhenRun` work: the system runs an open-app intent in the app's own
// process, so the type must exist there; when it lived only in the appex the
// flag made `perform()` silently never run (the inert-toggle bug). With it,
// pressing a widget button or the Control Center toggle launches a quit app
// instead of writing a command nothing is listening for.
//
// `perform()` stays on the WidgetBridge seams in either process: write the
// command, ring the Darwin doorbell (the app also hears its own doorbell), and
// let `AppModel.applyPendingWidgetCommand()` act. The freshness window in
// `WidgetBridge.consumeCommand` keeps a stale command from firing days later.

/// The main app's bundle id, derived from this process's own: the appex id is
/// the app's plus a `.widget` suffix, and in the app itself it's already the
/// app's. No hardcoding, so renames and forks stay consistent.
private var mainAppBundleID: String {
    let own = Bundle.main.bundleIdentifier ?? "sh.gyorgy.keepresso"
    return own.hasSuffix(".widget")
        ? String(own.dropLast(".widget".count))
        : own
}

/// Whether the main app is running right now. The widgets use this to render
/// honestly after a crash or force quit (stored state says "Brewing", but
/// nothing holds an assertion), and readers of the stored state should treat
/// it as inactive when this is false.
func keepressoAppIsRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: mainAppBundleID).isEmpty
}

/// The session state the app last mirrored into the App Group, or `nil` when
/// the group (or any state) is unavailable.
func currentSharedState() -> SharedSessionState? {
    WidgetBridge.groupDefaults().flatMap { WidgetBridge.readState(from: $0) }
}

private func send(_ command: WidgetCommand) {
    guard let defaults = WidgetBridge.groupDefaults() else { return }
    WidgetBridge.writeCommand(command, to: defaults)
    WidgetBridge.postCommandNotification()
}

/// Start/stop from a desktop widget button.
struct ToggleKeepAwakeWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Keep Awake"
    /// Launch the app if needed; see the header comment.
    static let openAppWhenRun = true
    /// Widget plumbing, not a Shortcuts action (the app ships real Shortcuts
    /// intents separately).
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        let isActive = keepressoAppIsRunning() && currentSharedState()?.isActive == true
        send(isActive ? .stop : .start)
        return .result()
    }
}

/// Pause or resume trigger gating from the medium widget.
struct SetTriggersPausedWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Triggers"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Paused")
    var paused: Bool

    init() {}
    init(paused: Bool) {
        self.paused = paused
    }

    func perform() async throws -> some IntentResult {
        send(paused ? .pauseTriggers : .resumeTriggers)
        return .result()
    }
}

/// The Control Center toggle's intent: the exact same bridge as the desktop
/// widget buttons.
@available(macOS 26.0, *)
struct SetKeepAwakeControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Keep Awake"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Keep Awake")
    var value: Bool

    func perform() async throws -> some IntentResult {
        send(value ? .start : .stop)
        return .result()
    }
}
