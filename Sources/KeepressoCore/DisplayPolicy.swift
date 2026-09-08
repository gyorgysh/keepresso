import Foundation

/// What the closed-display watchdog should do with the built-in panel while
/// closed-display mode holds the Mac awake with the lid shut.
///
/// Three persistent answers, always the user's choice. Remote-session yielding
/// and the virtual display arrive later and fold into ``DisplayPolicyDecision``
/// rather than growing a second watchdog.
public enum ClosedLidDisplayPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    /// Sleep the panel when the lid shuts (no external display attached) and
    /// re-sleep it when something lights it back up inside the shut lid.
    case displayOff
    /// Keep the display powered at 0% brightness: the panel looks off, but the
    /// framebuffer stays live so a remote session keeps working.
    case zeroBrightness
    /// Never touch the display: no sleep command, no brightness change.
    case leaveAlone
}

public extension ClosedLidDisplayPolicy {
    /// Menu and Preferences label for the policy picker.
    var label: String {
        switch self {
        case .displayOff: L("Turn off the display")
        case .zeroBrightness: L("Stay on at 0% brightness")
        case .leaveAlone: L("Leave the display alone")
        }
    }

    /// One-line caption under the picker naming what the choice means.
    var explanation: String {
        switch self {
        case .displayOff:
            L("The display sleeps when the lid shuts. A remote session sees a sleeping display.")
        case .zeroBrightness:
            L("The panel goes dark but stays powered, so a remote session stays live.")
        case .leaveAlone:
            L("Keepresso never touches the display.")
        }
    }
}

/// What the watchdog should do on this tick, before edge latches and grace
/// periods (those stay in the controller).
public enum DisplayPolicyAction: Equatable, Sendable {
    /// Put the panel to sleep (and re-sleep it if it wakes inside the lid).
    case sleepPanel
    /// Hold the panel at 0% brightness (and re-zero it if raised).
    case holdDim
    /// Do nothing to the display.
    case hold
}

/// Pure policy gate for ``ClosedDisplayController``. Host-driven like
/// ``SessionController``: no clock, no IOKit, no side effects, so the matrix
/// stays unit-testable with plain values.
///
/// - `lidClosed == nil`: an unreadable lid reads as "don't act on a guess",
///   matching the controller's early return on a nil read.
public enum DisplayPolicyDecision {
    public static func decide(
        policy: ClosedLidDisplayPolicy,
        lidClosed: Bool?,
        hasExternalDisplay: Bool
    ) -> DisplayPolicyAction {
        guard let lidClosed, lidClosed, !hasExternalDisplay else { return .hold }
        switch policy {
        case .displayOff: return .sleepPanel
        case .zeroBrightness: return .holdDim
        case .leaveAlone: return .hold
        }
    }
}
