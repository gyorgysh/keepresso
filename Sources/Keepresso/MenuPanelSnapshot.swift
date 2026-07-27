import Foundation
import Observation
import KeepressoCore

/// Live values the open menu panel needs each second. Owned by ``AppModel`` and
/// pulsed from the session ticker while the panel is visible, so
/// ``MenuBarContent`` does not need a second `Timer.publish` of its own.
///
/// Keep-awake / assertion / trigger paths are untouched: this is display state
/// only (elapsed caption, countdown tick token, cached external-assertion line).
@MainActor
@Observable
final class MenuPanelSnapshot {
    /// Seconds the current session has been running, mirrored for the caption.
    private(set) var elapsed: TimeInterval = 0
    /// Bumped each pulse so grace / lease countdowns re-render while open.
    private(set) var tick: UInt = 0
    /// Compact "held by…" payload, or nil when nothing external is holding.
    private(set) var heldBy: HeldByLine?

    struct HeldByLine: Equatable {
        var processName: String
        var effect: String
    }

    func pulse(elapsed: TimeInterval, external: PowerAssertionInfo?) {
        self.elapsed = elapsed
        tick &+= 1
        if let external, let effect = external.effect {
            heldBy = HeldByLine(processName: external.processName, effect: effect)
        } else {
            heldBy = nil
        }
    }
}
