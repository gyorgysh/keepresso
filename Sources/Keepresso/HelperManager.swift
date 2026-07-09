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
    /// True while a health check (and possibly a repair) is in flight, so the
    /// attention window can show progress instead of a stale verdict.
    private(set) var isChecking = false

    /// Polls while the user is over in System Settings deciding, so the UI
    /// flips to "installed" by itself once they approve.
    @ObservationIgnored private var approvalPoll: Task<Void, Never>?

    /// Single-flight guard for the health check, so a launch-time check and a
    /// failure-triggered one join the same run instead of stacking repairs.
    @ObservationIgnored private var healthCheck: Task<HelperHealth, Never>?
    /// One repair per app run: registration churn must never loop.
    @ObservationIgnored private var repairAttempted = false
    /// Whether this build may rewrite the daemon registration. BTM refuses
    /// team-less executables outright ("disallowed"), so an ad-hoc dev build
    /// could never revive the daemon by re-registering; worse, its attempt
    /// hijacks the record that belongs to the properly signed copy in
    /// /Applications. Seen live: a Debug run re-registered the record and left
    /// the real install pointing at DerivedData.
    @ObservationIgnored private let canRepair = HelperService.selfTeamIdentifier() != nil
    /// Whether this copy may talk to Background Task Management at all.
    /// Reading `SMAppService.status` is not passive: BTM repoints the app's
    /// record at whichever same-signed copy contacted it last, so a Debug
    /// build in DerivedData that merely checks the status steals the record
    /// from the installed copy, and BTM then disables the daemon when it
    /// revalidates against the wrong bundle (seen live in the unified log:
    /// `_bundleURLForAuditToken ... URL to: .../DerivedData/...`). Only the
    /// copy in an Applications folder manages the daemon; any other stays
    /// entirely hands-off, so its helper features fall back to the admin
    /// prompt path. Set the `KeepressoManageHelperAnywhere` default to test
    /// helper flows from a dev build on purpose.
    @ObservationIgnored private let managesDaemon =
        AppRelocator.runsFromApplications
        || UserDefaults.standard.bool(forKey: "KeepressoManageHelperAnywhere")
    /// Reads BTM's own records (`sfltool dumpbtm`, prompt-free). They are the
    /// only honest view: `SMAppService.status` reported `.enabled` on a live
    /// machine while the daemon record underneath sat disabled.
    @ObservationIgnored private let dumper: BTMDumpProviding
    /// Whether this is the first run after an app update, so the enabled edge
    /// retires the daemon even when the protocol still matches: launchd keeps
    /// the old binary image serving otherwise, since the file under it was
    /// swapped, not the process.
    @ObservationIgnored private let appUpdatedSinceLastRun: Bool

    init(
        client: XPCHelperClient,
        dumper: BTMDumpProviding = SFLToolBTMDumper(),
        appUpdatedSinceLastRun: Bool = false
    ) {
        self.client = client
        self.dumper = dumper
        self.appUpdatedSinceLastRun = appUpdatedSinceLastRun
        refresh()
    }

    var isInstalled: Bool { status == .enabled }
    var awaitingApproval: Bool { status == .requiresApproval }

    /// Re-read the daemon's registration status and mirror it for the seams.
    func refresh() {
        guard managesDaemon else { return }
        let wasInstalled = status == .enabled
        status = service.status
        availability.set(status == .enabled)
        if status == .enabled, !wasInstalled {
            // Warm the connection and, after an app update or a protocol
            // bump, nudge the stale daemon to retire so launchd relaunches
            // the binary now in the bundle.
            let client = self.client
            let appUpdated = self.appUpdatedSinceLastRun
            Task.detached { client.retireStaleDaemon(appUpdated: appUpdated) }
        }
    }

    /// Register the daemon. First time through, macOS wants the user's
    /// one-time approval: we open the Login Items pane for them and poll until
    /// they've decided.
    func install() {
        guard managesDaemon else {
            lastError = "This copy of Keepresso isn't in the Applications folder, so it leaves the helper alone. Install from /Applications."
            return
        }
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
        guard managesDaemon else { return }
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
        // A clean unregister often leaves a disabled tombstone in BTM's
        // records, and System Settings keeps showing the app's row off it.
        // That's cosmetic (nothing can launch), clears at the latest with a
        // restart, and nothing programmatic can remove it: BTM's records and
        // switches are deliberately user-only, root included (sfltool
        // resetbtm would reset every app's approvals). Say so, instead of
        // letting the lingering row read as a failed removal.
        if status != .enabled, lastError == nil,
           let findings = await inspectRecords(), findings.daemonState != .missing {
            lastError = "Removed. System Settings may keep showing Keepresso under App Background Activity until macOS refreshes its list; restarting the Mac clears the leftover row."
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
        isChecking = true
        let health = await check.value
        isChecking = false
        healthCheck = nil
        return health
    }

    private func runHealthCheck() async -> HelperHealth {
        guard status == .enabled else { return .notApplicable }
        if await pings() { return .healthy }
        // A dev build stays hands-off: no repair, no attention window. The
        // installed release copy owns the registration.
        guard canRepair else { return .notApplicable }
        // Ask BTM's records what is actually wrong before churning the
        // registration; two of the states no re-register can fix. An old
        // copy of the app in the Trash keeps poisoning the record (BTM's
        // bookmark resolves there and it disables the daemon on every
        // revalidation), so delete it. And a daemon whose Background
        // Activity switch is off can only be revived by the user: route to
        // the approval step instead of claiming a reinstall would help.
        let findings = await inspectRecords()
        if let findings {
            if !findings.staleCopyPaths.isEmpty {
                let paths = findings.staleCopyPaths
                await Task.detached { StaleBundleCleaner.removeTrashedCopies(at: paths) }.value
            }
            if findings.daemonState == .disabled {
                lastError = nil
                return .needsApproval
            }
        }
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
        lastError = switch findings?.daemonState {
        case .disallowed:
            "macOS is refusing the helper's registration outright. Reinstall the helper; if that doesn't take, restart the Mac and try once more."
        default:
            "The helper isn't responding. If an old copy of Keepresso is in the Trash, empty the Trash first: macOS keeps disabling the helper while one is there. Then reinstall the helper."
        }
        return .broken
    }

    /// Whether a matching daemon answers, off the main actor (a dead daemon
    /// means waiting out the XPC timeout).
    private func pings() async -> Bool {
        let client = self.client
        return await Task.detached { client.ping() }.value
    }

    /// One ping, for callers watching a recovery (the attention window's
    /// approval step, where the status alone can't signal success).
    func daemonResponds() async -> Bool {
        await pings()
    }

    /// This app's slice of BTM's records, or nil where the dump is
    /// unavailable (root-gated on some macOS versions).
    private func inspectRecords() async -> BTMFindings? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let dumper = self.dumper
        return await Task.detached {
            guard let dump = dumper.dumpBTM() else { return nil }
            return BTMInspection.findings(
                inDump: dump,
                bundleIdentifier: bundleID,
                helperLabel: HelperService.machServiceLabel
            )
        }.value
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
