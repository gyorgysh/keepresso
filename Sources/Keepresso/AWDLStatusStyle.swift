import SwiftUI
import KeepressoCore

/// Presentation for ``AppModel/AWDLStatus``, shared by the menu dropdown and the
/// Gaming & Streaming window so the readout matches wherever the user looks.
/// `nil` when the watchdog isn't running (nothing to show).
struct AWDLStatusStyle {
    let icon: String
    let color: Color
    let text: String

    init?(_ status: AppModel.AWDLStatus) {
        switch status {
        case .off:
            return nil
        case .watchingForGame:
            icon = "binoculars"
            color = .secondary
            text = L("Waiting for a game to come to the front")
        case .pausedManually:
            icon = "dot.radiowaves.left.and.right"
            color = .secondary
            text = L("AWDL paused")
        case .pausedForGame:
            icon = "gamecontroller.fill"
            color = .green
            text = L("AWDL paused for gaming")
        case .resumingAfterGame(let seconds):
            icon = "hourglass"
            color = .orange
            text = L("Game closed, AWDL back in %ds", seconds)
        }
    }
}
