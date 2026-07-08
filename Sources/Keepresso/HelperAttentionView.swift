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
        .background(WindowElevator())
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
        case .checking: "Checking the helper"
        case .needsApproval: "One approval needed"
        case .broken: "The helper needs a reinstall"
        case .allSet: "All set"
        }
    }

    private var message: String {
        switch stage {
        case .checking:
            "Making sure Keepresso's helper is awake and answering."
        case .needsApproval:
            "macOS turned the helper's background switch off, so it needs your approval again: in System Settings, under Login Items & Extensions, find Keepresso in App Background Activity and turn it on. Everything is password-free again right after."
        case .broken:
            "Keepresso repaired the helper's registration, but macOS keeps disabling it. An old copy of Keepresso in the Trash is the usual cause: empty the Trash, then reinstall the helper below. Nothing else about your setup changes."
        case .allSet:
            "The helper is back. Closed-display mode and AWDL pausing work without password prompts again."
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
            statusBadge(icon: "hourglass", text: "Waiting for the switch in System Settings; this updates by itself.")
        case .broken:
            if let error = model.helper.lastError {
                statusBadge(icon: "exclamationmark.triangle", text: error)
            }
        case .allSet:
            Label("Helper installed and responding", systemImage: "checkmark.seal.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
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
        .background(Color.keepressoBrew.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

/// Lifts the hosting window to the front of everything once, when it appears:
/// centered, floating above normal windows, and ordered front even though the
/// app is a background agent that can't always become active. Floating is
/// deliberate for an attention dialog; the window is small and dismissible.
private struct WindowElevator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.center()
            window.orderFrontRegardless()
            window.makeKey()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
