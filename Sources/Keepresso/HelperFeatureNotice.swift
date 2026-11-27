import SwiftUI
import KeepressoCore

struct HelperFeatureNotice: View {
    @Bindable var model: AppModel
    let message: String
    var helperOnly = false

    var body: some View {
        Group {
            if let hint = model.helperRecoveryHint,
               helperOnly || HelperRecoveryPhase.isHelperConnectionError(message) {
                Label(hint, systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            } else {
                Text(message).foregroundStyle(.orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
