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

/// Outcome of ``HelperManager/verifyAndRepairIfNeeded()``.
enum HelperHealth {
    /// Not installed (or approval still pending): nothing to verify.
    case notApplicable
    /// The daemon answered the version handshake.
    case healthy
    /// The registration had gone stale; re-registering brought it back.
    case repaired
    /// The repair needs a fresh approval in System Settings.
    case needsApproval
    /// Still not responding after a repair.
    case broken
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

    /// Single-flight guard for the health check, so a launch-time check and a
    /// failure-triggered one join the same run instead of stacking repairs.
    @ObservationIgnored private var healthCheck: Task<HelperHealth, Never>?
    /// One repair per app run: registration churn must never loop.
    @ObservationIgnored private var repairAttempted = false

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

    /// Verify that an installed daemon actually responds, and repair its
    /// registration when it doesn't.
    ///
    /// macOS can lose the ability to spawn the daemon while still reporting it
    /// enabled: the Background Task Management record keeps a stale reference
    /// to the app bundle (typically after an app update followed by a reboot),
    /// launchd then fails every spawn with EX_CONFIG, and every XPC call times
    /// out. `SMAppService.status` can't see this (it stays `.enabled`), so the
    /// daemon is checked the honest way, a ping, and healed by re-submitting
    /// the registration, which rewrites the record. The approval is keyed to
    /// the app's signing identity, so the repair normally needs no new
    /// password or approval.
    @discardableResult
    func verifyAndRepairIfNeeded() async -> HelperHealth {
        if let running = healthCheck { return await running.value }
        let check = Task { await self.runHealthCheck() }
        healthCheck = check
        let health = await check.value
        healthCheck = nil
        return health
    }

    private func runHealthCheck() async -> HelperHealth {
        guard status == .enabled else { return .notApplicable }
        if await pings() { return .healthy }
        guard !repairAttempted else { return .broken }
        repairAttempted = true
        // First try re-submitting the registration in place: no approval can
        // be lost this way, and it rewrites the record's bundle reference.
        try? service.register()
        if await pings() {
            lastError = nil
            return .repaired
        }
        // Not enough: rebuild the record from scratch. Between the unregister
        // and the register the mirrored availability deliberately stays as it
        // was, so a concurrent engage still routes to the (dead) daemon and
        // fails quietly instead of falling back to a surprise password prompt.
        try? await service.unregister()
        try? service.register()
        refresh()
        if status == .requiresApproval {
            pollWhileAwaitingApproval()
            return .needsApproval
        }
        if await pings() {
            lastError = nil
            return .repaired
        }
        lastError = "The helper isn't responding. Remove it and install it again."
        return .broken
    }

    /// Whether a matching daemon answers, off the main actor (a dead daemon
    /// means waiting out the XPC timeout).
    private func pings() async -> Bool {
        let client = self.client
        return await Task.detached { client.ping() }.value
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
