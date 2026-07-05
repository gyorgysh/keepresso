import SwiftUI

/// Explains the macOS administrator-password prompt that a privileged toggle
/// (AWDL watchdog, lid-closed mode) triggers. The system dialog is presented by
/// SecurityAgent and attributed to "osascript" (Keepresso runs the command via
/// `osascript`), which looks alarming with no context. This note names what the
/// password is for and reassures that "osascript" is Keepresso. `purpose`
/// completes "...password to <purpose>".
struct AdminAuthNote: View {
    let purpose: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("macOS is asking for your administrator password to \(purpose). The dialog may be titled “osascript”: that's Keepresso running the command, and nothing else is changed.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
