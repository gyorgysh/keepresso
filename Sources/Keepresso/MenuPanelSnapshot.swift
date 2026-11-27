import Foundation
import Observation
import KeepressoCore

@MainActor
@Observable
final class MenuPanelSnapshot {
    private(set) var elapsed: TimeInterval = 0
    private(set) var tick: UInt = 0
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
