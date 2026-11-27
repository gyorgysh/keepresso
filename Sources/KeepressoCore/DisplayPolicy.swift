import Foundation

/// What the closed-display watchdog should do with the built-in panel while
/// closed-display mode holds the Mac awake with the lid shut.
///
/// Three persistent answers, always the user's choice. Remote-session yielding
/// and the virtual display arrive later and fold into ``DisplayPolicyDecision``
/// rather than growing a second watchdog.
public enum ClosedLidDisplayPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case displayOff
    case zeroBrightness
    case leaveAlone
}

public extension ClosedLidDisplayPolicy {
    var label: String {
        switch self {
        case .displayOff: L("Turn off the display")
        case .zeroBrightness: L("Stay on at 0% brightness")
        case .leaveAlone: L("Leave the display alone")
        }
    }

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
    case sleepPanel
    case holdDim
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
