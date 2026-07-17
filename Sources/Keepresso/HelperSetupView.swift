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
                Text("Helper installed. Closed-display mode, fan boost, and AWDL pausing work without password prompts.")
                Spacer(minLength: 8)
                Button("Remove") { model.removeHelper() }
            }
            // The helper ships inside the app, so an app update replaces it
            // on disk automatically; this shows only while the pre-update
            // service is still winding down (it can't while it holds a
            // switch, e.g. closed-display mode mid-session).
            if model.helper.daemonOutdated {
                Label(
                    L("The helper service is updating itself to this version of Keepresso in the background. No reinstall or password is needed. Features new to this version wait until it finishes, usually under a minute."),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text("Install a small helper service so closed-display mode, the thermal fan boost, and AWDL pausing work without password prompts. macOS will ask you to allow it in System Settings, once. Nothing else changes.")
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
