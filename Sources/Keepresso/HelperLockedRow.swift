import SwiftUI

/// The stand-in for a helper-only control while the administrator helper is
/// missing, awaiting approval, or updating: a lock (or progress) row that
/// says why the control is absent and offers the one action that unlocks it.
/// Shown INSTEAD of the control, never next to a dead toggle: a switch that
/// silently refuses reads as broken, a lock reads as locked.
struct HelperLockedRow: View {
    @Bindable var model: AppModel

    enum Context {
        case wakeSchedule
        case gamePriority
    }
    let context: Context

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusSymbolColor)
            }
            if showsInstallButton {
                Button("Install Helper…") { model.installHelper() }
            } else if model.helper.awaitingApproval {
                Button("Open Login Items") { model.helper.openApprovalSettings() }
            }
            if let error = model.helper.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsInstallButton: Bool {
        !model.helper.awaitingApproval && !model.helper.daemonOutdated
    }

    private var statusSymbol: String {
        if model.helper.awaitingApproval { return "hourglass" }
        if model.helper.daemonOutdated { return "arrow.triangle.2.circlepath" }
        return "lock"
    }

    private var statusSymbolColor: Color {
        model.helper.awaitingApproval ? .orange : .secondary
    }

    private var statusText: String {
        if model.helper.awaitingApproval {
            switch context {
            case .wakeSchedule:
                return L("One step left: allow Keepresso under Login Items in System Settings. Scheduled wake unlocks by itself.")
            case .gamePriority:
                return L("One step left: allow Keepresso under Login Items in System Settings. The priority boost unlocks by itself.")
            }
        }
        if model.helper.daemonOutdated {
            switch context {
            case .wakeSchedule:
                return L("The helper is updating itself (no password). Scheduled wake unlocks when that finishes, usually under a minute.")
            case .gamePriority:
                return L("The helper is updating itself (no password). The priority boost unlocks when that finishes, usually under a minute.")
            }
        }
        switch context {
        case .wakeSchedule:
            return L("Scheduled wake needs the administrator helper, the same one closed-display mode and fan boost use. Install once, and macOS asks for approval in System Settings.")
        case .gamePriority:
            return L("Raising a game's priority is a root-only change, so it needs the administrator helper, the same one closed-display mode and fan boost use. Install once, and macOS asks for approval in System Settings.")
        }
    }
}
