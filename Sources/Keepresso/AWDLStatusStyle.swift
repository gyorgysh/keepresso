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
            text = "Waiting for a game to come to the front"
        case .pausedManually:
            icon = "dot.radiowaves.left.and.right"
            color = .secondary
            text = "AWDL paused"
        case .pausedForGame:
            icon = "gamecontroller.fill"
            color = .green
            text = "AWDL paused for gaming"
        case .resumingAfterGame(let seconds):
            icon = "hourglass"
            color = .orange
            text = "Game closed, AWDL back in \(seconds)s"
        }
    }
}
