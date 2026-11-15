import SwiftUI

/// Recovery for the persistent system setting used by earlier versions.
struct ClosedDisplayRecoveryRow: View {
    var model: AppModel

    var body: some View {
        if model.hasUnscopedSleepOverrideOnNotebook {
            VStack(alignment: .leading, spacing: 6) {
                Text("System sleep is disabled outside a Keepresso session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow system sleep") {
                    model.setClosedDisplay(false)
                }
                .disabled(model.closedDisplayBusy)
                if model.closedDisplayBusy && !model.helperInstalled {
                    AdminAuthNote(purpose: L("Allow system sleep"))
                }
                if let error = model.closedDisplayError {
                    HelperFeatureNotice(model: model, message: error)
                        .font(.caption)
                }
            }
        }
    }
}
