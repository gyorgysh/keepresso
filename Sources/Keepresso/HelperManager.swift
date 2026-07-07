import Foundation
import Observation
import ServiceManagement
import KeepressoCore

/// Thread-safe "is the helper installed" flag. The Core routing seams consult
/// it from detached tasks, where the `@MainActor` ``HelperManager`` can't be
/// touched, so the manager mirrors its status into this box.
final class HelperAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func set(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }
}

/// Registration and status of the privileged helper daemon, over
/// `SMAppService`. Installing is the one-time trade the user makes to stop
/// the per-run password prompts: macOS asks for administrator credentials
/// once, when the daemon is approved in System Settings (Login Items, "Allow
/// in the Background"), and the approval survives reboots, app updates, and
/// relaunches.
@MainActor
@Observable
final class HelperManager {
    private let service = SMAppService.daemon(plistName: HelperService.plistName)
    private let client: XPCHelperClient
    /// Mirrored status for the Core routing closures (off-main readers).
    let availability = HelperAvailability()

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    /// Polls while the user is over in System Settings deciding, so the UI
    /// flips to "installed" by itself once they approve.
    @ObservationIgnored private var approvalPoll: Task<Void, Never>?

    init(client: XPCHelperClient) {
        self.client = client
        refresh()
    }

    var isInstalled: Bool { status == .enabled }
    var awaitingApproval: Bool { status == .requiresApproval }

    /// Re-read the daemon's registration status and mirror it for the seams.
    func refresh() {
        let wasInstalled = status == .enabled
        status = service.status
        availability.set(status == .enabled)
        if status == .enabled, !wasInstalled {
            // Warm the connection and, after an app update, nudge a stale
            // daemon to retire so launchd relaunches the new binary.
            let client = self.client
            Task.detached { client.retireStaleDaemon() }
        }
    }

    /// Register the daemon. First time through, macOS wants the user's
    /// one-time approval: we open the Login Items pane for them and poll until
    /// they've decided.
    func install() {
        lastError = nil
        do {
            try service.register()
        } catch {
            // register() also throws while approval is pending; that's the
            // expected flow, not an error to surface. Read the status to tell.
        }
        refresh()
        switch status {
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            pollWhileAwaitingApproval()
        case .enabled, .notRegistered:
            break
        case .notFound:
            lastError = "The helper wasn't found inside the app. Reinstall Keepresso and try again."
        @unknown default:
            break
        }
        if status == .notRegistered {
            lastError = "The helper couldn't be registered."
        }
    }

    /// Unregister the daemon. The caller (``AppModel``) releases any live
    /// holds first, so nothing is left held by a service that's going away.
    /// Note System Settings can keep a stale row under Login Items for a
    /// while after a successful unregister; the status here is authoritative.
    func uninstall() async {
        lastError = nil
        approvalPoll?.cancel()
        do {
            try await service.unregister()
        } catch {
            lastError = "The helper couldn't be removed: \(error.localizedDescription)"
        }
        refresh()
        if status == .enabled, lastError == nil {
            lastError = "macOS still reports the helper as registered. Try again, or restart the Mac."
        }
    }

    /// Open System Settings at the approval toggle again, for when the user
    /// dismissed it the first time.
    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
        pollWhileAwaitingApproval()
    }

    private func pollWhileAwaitingApproval() {
        approvalPoll?.cancel()
        approvalPoll = Task { [weak self] in
            // Up to five minutes of deciding time; each pass is one cheap
            // status read.
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
                if self.status != .requiresApproval { return }
            }
        }
    }
}
