import SwiftUI
import ServiceManagement

/// Status and actions for the privileged helper, shared by Preferences
/// (General ▸ Administrator helper) and the Gaming & Streaming window. Three
/// states: not installed (offer the install), waiting for the one-time
/// approval in System Settings (point there), installed (say so, offer
/// removal).
struct HelperStatusRows: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.helper.status {
        case .enabled:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Helper installed. Closed-display mode and AWDL pausing work without password prompts.")
                Spacer(minLength: 8)
                Button("Remove") { model.removeHelper() }
            }
        case .requiresApproval:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "hourglass")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("One step left, in System Settings: under General ▸ Login Items & Extensions (\u{201C}Login Items\u{201D} on older macOS), find Keepresso in the \u{201C}Allow in the Background\u{201D} list and turn its switch ON. macOS asks for your administrator password once; this updates by itself when you're done.")
                Spacer(minLength: 8)
                Button("Open Login Items") { model.helper.openApprovalSettings() }
            }
        default:
            HStack(alignment: .top, spacing: 6) {
                Text("Install a small helper service so closed-display mode and AWDL pausing never ask for your password again. macOS will ask you to allow it in System Settings, once; nothing else changes.")
                Spacer(minLength: 8)
                Button("Install Helper…") { model.installHelper() }
            }
        }
        if let error = model.helper.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
