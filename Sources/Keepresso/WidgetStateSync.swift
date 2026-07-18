import WidgetKit
import KeepressoCore

struct UnattendedStatusMetadata: Equatable {
    var activeLeaseCount = 0
    var nextLeaseDeadline: Date?
    var phase: String?
    var closedLidProtectionReady = false
    var nextCodexRun: Date?
}

/// Mirrors the session state into the App Group the widget extension reads and
/// reloads the widgets (and, on macOS 26, the Control Center control). Extracted
/// from ``AppModel`` so the "write then reload" block lives in one place instead
/// of being copied between the per-second sync and the stop-on-quit write.
/// Also mirrors the same state into `status.json` for the `keepresso` CLI,
/// which is signed separately and cannot join the Team-ID-scoped App Group.
@MainActor
final class WidgetStateSync {
    /// The App Group defaults shared with the widget extension, or `nil` when
    /// the group entitlement isn't available (unsigned dev builds).
    private let defaults = WidgetBridge.groupDefaults()
    /// The last state written, so the per-second tick only writes on change.
    private var lastState: SharedSessionState?
    private var lastUnattendedStatus: UnattendedStatusMetadata?
    private let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// Write `state` and reload the widgets, but only when it actually changed:
    /// the ticker calls this every second and the no-op path is the common one.
    func write(
        _ state: SharedSessionState,
        unattended: UnattendedStatusMetadata = UnattendedStatusMetadata()
    ) {
        let sharedChanged = state != lastState
        let statusChanged = sharedChanged || unattended != lastUnattendedStatus
        guard statusChanged else { return }
        lastState = state
        lastUnattendedStatus = unattended
        StatusFile.write(StatusSnapshot(
            isActive: state.isActive,
            endsAt: state.endsAt,
            triggersEnabled: state.triggersEnabled,
            triggersPaused: state.triggersPaused,
            activeAgentLeaseCount: unattended.activeLeaseCount,
            nextAgentLeaseDeadline: unattended.nextLeaseDeadline,
            unattendedPhase: unattended.phase,
            closedLidProtectionReady: unattended.closedLidProtectionReady,
            nextCodexRun: unattended.nextCodexRun,
            appVersion: appVersion,
            pid: ProcessInfo.processInfo.processIdentifier,
            writtenAt: Date()
        ))
        guard sharedChanged else { return }
        guard let defaults else { return }
        WidgetBridge.writeState(state, to: defaults)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetBridge.statusWidgetKind)
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: WidgetBridge.controlKind)
        }
    }

    /// Consume a pending widget command (a Control Center / widget button press
    /// left in the App Group), or `nil` if there's none.
    func consumeCommand() -> WidgetCommand? {
        guard let defaults else { return nil }
        return WidgetBridge.consumeCommand(from: defaults)
    }
}
