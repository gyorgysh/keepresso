import SwiftUI
import AppKit

/// The helper attention window: opened automatically (see `MenuBarLabelView`)
/// when the self-heal for the privileged helper gets stuck on something only
/// the user can do, either the one-time approval again or a reinstall. It
/// walks that single step, watches the live status, and flips to a success
/// state on its own the moment the daemon answers, so the user always sees
/// the loop close.
struct HelperAttentionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// What the window is showing right now, derived from the live helper
    /// state so approval progress observed by the manager's poll moves the
    /// window forward without any action here.
    private enum Stage {
        case checking
        case needsApproval
        case broken
        case allSet
    }

    private var stage: Stage {
        if model.helper.isChecking { return .checking }
        if model.helper.awaitingApproval { return .needsApproval }
        switch model.helperAttention {
        case .needsApproval: return .needsApproval
        case .broken: return .broken
        case nil: return .allSet
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            BrewingCupView(isActive: true, scale: 2.4)
                .padding(.top, 4)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.bold())
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusRow

            actions
        }
        .padding(24)
        .frame(width: 380)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        // This window exists to be seen: Keepresso is a background agent, so
        // an ordinary window would open behind whatever the user is doing.
        // Floating is deliberate here, unlike the other windows: an attention
        // dialog that landed behind something would defeat its purpose.
        .background(WindowPlacement(floating: true))
        .animation(.smooth(duration: 0.3), value: stageKey)
        // The manager polls while the user is over in System Settings; the
        // moment the approval lands, confirm the daemon really answers, which
        // flips this window to All set by itself.
        .onChange(of: model.helper.status) { _, status in
            if status == .enabled { model.verifyHelper() }
        }
    }

    /// `Stage` isn't Equatable-friendly for `animation(value:)` with derived
    /// state; a plain key is.
    private var stageKey: Int {
        switch stage {
        case .checking: 0
        case .needsApproval: 1
        case .broken: 2
        case .allSet: 3
        }
    }

    private var title: String {
        switch stage {
        case .checking: L("Checking the helper")
        case .needsApproval: L("One approval needed")
        case .broken: L("The helper needs a reinstall")
        case .allSet: L("All set")
        }
    }

    private var message: String {
        switch stage {
        case .checking:
            L("Making sure Keepresso's helper is awake and answering.")
        case .needsApproval:
            L("macOS turned the helper's background switch off, so it needs your approval again: in System Settings, under Login Items & Extensions, find Keepresso in App Background Activity and turn it on. Everything is password-free again right after.")
        case .broken:
            L("Keepresso repaired the helper's registration, but macOS keeps disabling it. An old copy of Keepresso in the Trash is the usual cause: empty the Trash, then reinstall the helper below. Nothing else about your setup changes.")
        case .allSet:
            L("The helper is back. Closed-display mode and AWDL pausing work without password prompts again.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch stage {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Contacting the helper\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case .needsApproval:
            statusBadge(icon: "hourglass", text: L("Waiting for the switch in System Settings; this updates by itself."))
        case .broken:
            if let error = model.helper.lastError {
                statusBadge(icon: "exclamationmark.triangle", text: error)
            }
        case .allSet:
            AllSetBadge()
        }
    }

    /// The success line, with a single seal bounce when it lands. One shot on
    /// appear, never a loop.
    private struct AllSetBadge: View {
        @State private var landed = false

        var body: some View {
            Label("Helper installed and responding", systemImage: "checkmark.seal.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: landed)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .onAppear { landed = true }
        }
    }

    private func statusBadge(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.keepressoBrew)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 8, tint: Color.keepressoBrew.opacity(0.14))
    }

    @ViewBuilder
    private var actions: some View {
        switch stage {
        case .checking:
            Button("Close") { closeWindow() }
        case .needsApproval:
            HStack {
                Button("Later") { closeWindow() }
                Spacer()
                Button("Open Login Items") { model.helper.openApprovalSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        case .broken:
            HStack {
                Button("Later") { closeWindow() }
                Spacer()
                Button("Reinstall Helper") { model.reinstallHelper() }
                    .keyboardShortcut(.defaultAction)
            }
        case .allSet:
            Button("Done") { closeWindow() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func closeWindow() {
        model.dismissHelperAttention()
        dismiss()
    }
}
