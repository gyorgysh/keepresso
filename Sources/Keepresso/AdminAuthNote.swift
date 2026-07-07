import SwiftUI

/// Explains the macOS administrator-password prompt that a privileged toggle
/// (AWDL watchdog, lid-closed mode) triggers. The system dialog is presented by
/// SecurityAgent and attributed to "osascript" (Keepresso runs the command via
/// `osascript`), which looks alarming with no context. This note names what the
/// password is for and reassures that "osascript" is Keepresso. `purpose`
/// completes "...password to <purpose>".
struct AdminAuthNote: View {
    let purpose: String

    /// The callers insert this view the moment their controller goes busy, but
    /// busy also covers sub-second work that never shows a dialog (a helper
    /// XPC call, a command failing fast). Rendering only after a short hold
    /// keeps those from flashing a password explanation under the toggle: a
    /// real authorization dialog waits on the user, so it comfortably outlives
    /// the delay.
    @State private var dialogStillUp = false

    var body: some View {
        Group {
            if dialogStillUp {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("macOS is asking for your administrator password to \(purpose). The dialog may be titled “osascript”: that's Keepresso running the command, and nothing else is changed. To stop these prompts for good, install the administrator helper (Preferences ▸ General).")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            dialogStillUp = true
        }
    }
}
