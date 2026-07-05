import WidgetKit
import KeepressoCore

/// Mirrors the session state into the App Group the widget extension reads and
/// reloads the widgets (and, on macOS 26, the Control Center control). Extracted
/// from ``AppModel`` so the "write then reload" block lives in one place instead
/// of being copied between the per-second sync and the stop-on-quit write.
@MainActor
final class WidgetStateSync {
    /// The App Group defaults shared with the widget extension, or `nil` when
    /// the group entitlement isn't available (unsigned dev builds).
    private let defaults = WidgetBridge.groupDefaults()
    /// The last state written, so the per-second tick only writes on change.
    private var lastState: SharedSessionState?

    /// Write `state` and reload the widgets, but only when it actually changed:
    /// the ticker calls this every second and the no-op path is the common one.
    func write(_ state: SharedSessionState) {
        guard let defaults, state != lastState else { return }
        lastState = state
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
