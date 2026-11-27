import SwiftUI
import KeepressoCore

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
