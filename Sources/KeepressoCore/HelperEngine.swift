import Foundation

/// Shell seam for the helper daemon, so ``HelperEngine`` is testable without
/// touching `pmset` or `ifconfig`. Success is exit status 0.
public protocol HelperCommandRunning: AnyObject, Sendable {
    @discardableResult
    func run(_ path: String, _ arguments: [String]) -> Bool
}

/// Real backend over `Process`. The daemon runs as root, so these are the same
/// commands the osascript path used, minus the password prompt.
public final class ProcessCommandRunner: HelperCommandRunning {
    public init() {}

    @discardableResult
    public func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// What the daemon still owes the system if it dies mid-hold: markers persist
/// on disk (root-owned, under `/var/db`) and are settled on the next daemon
/// launch, including the launchd `RunAtLoad` start after a reboot or crash.
public enum HelperRestoreMarker: String, CaseIterable, Sendable {
    /// We set `pmset disablesleep 1` for a hold and haven't set it back.
    case sleepDisabled = "sleep-disabled"
    /// We took `awdl0` down for a hold and haven't raised it.
    case awdlDown = "awdl-down"
}

/// Persistence seam for the restore markers.
public protocol HelperRestoreStatePersisting: AnyObject, Sendable {
    func markers() -> Set<HelperRestoreMarker>
    func set(_ marker: HelperRestoreMarker, present: Bool)
}

/// Real marker store: one empty file per marker in a root-owned directory.
public final class FileRestoreState: HelperRestoreStatePersisting {
    private let directory: URL

    public init(directory: URL = URL(fileURLWithPath: "/var/db/sh.gyorgy.keepresso.helper")) {
        self.directory = directory
    }

    public func markers() -> Set<HelperRestoreMarker> {
        Set(HelperRestoreMarker.allCases.filter {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        })
    }

    public func set(_ marker: HelperRestoreMarker, present: Bool) {
        if present {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data().write(to: url(for: marker))
        } else {
            try? FileManager.default.removeItem(at: url(for: marker))
        }
    }

    private func url(for marker: HelperRestoreMarker) -> URL {
        directory.appendingPathComponent(marker.rawValue, isDirectory: false)
    }
}

/// When the helper daemon process may exit, kept pure so it's testable (the
/// daemon's timer feeds in its counters).
///
/// Two ways out, both requiring no clients and no holds:
/// - The ordinary idle exit additionally waits for two consecutive idle
///   checks, so a freshly accepted connection can't be cut off before its
///   first call. launchd relaunches the daemon on the next XPC message.
/// - Retirement, requested by the app after an update or a protocol bump,
///   skips that grace and exits at the first fully idle check: this process
///   is still the pre-update binary image, and the client releases its
///   connection between calls precisely so this moment arrives. Live *holds*
///   always block an exit; dropping a sleep hold for even a moment with the
///   lid closed could put the Mac to sleep before any re-assert lands.
public enum HelperShutdownPolicy {
    public static func shouldExit(
        clientCount: Int,
        holdsIdle: Bool,
        terminateRequested: Bool,
        consecutiveIdleChecks: Int
    ) -> Bool {
        guard clientCount == 0, holdsIdle else { return false }
        return terminateRequested || consecutiveIdleChecks >= 2
    }
}

/// The helper daemon's whole brain, kept out of the executable target so it
/// can be unit-tested (the `keepresso-helper` binary is just XPC wiring around
/// this). Tracks which client connections hold the sleep and AWDL switches,
/// writes the system only on union edges, and settles anything left over from
/// a previous life at launch.
///
/// Thread-safety: everything is funneled through one lock; XPC delivers calls
/// on arbitrary queues.
public final class HelperEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let runner: HelperCommandRunning
    private let state: HelperRestoreStatePersisting

    private var sleepHolders: Set<Int> = []
    private var awdlHolders: Set<Int> = []

    public init(runner: HelperCommandRunning, state: HelperRestoreStatePersisting) {
        self.runner = runner
        self.state = state
    }

    /// Settle debts from a previous daemon life (crash, kill, reboot
    /// mid-hold): a leftover marker means the system was never restored, so
    /// restore it now and clear the marker. Called once at daemon launch,
    /// before the listener accepts anyone.
    public func restoreAtLaunch() {
        let leftovers = state.markers()
        if leftovers.contains(.sleepDisabled) {
            runner.run("/usr/bin/pmset", ["-a", "disablesleep", "0"])
            state.set(.sleepDisabled, present: false)
        }
        if leftovers.contains(.awdlDown) {
            runner.run("/sbin/ifconfig", ["awdl0", "up"])
            state.set(.awdlDown, present: false)
        }
    }

    /// The manual closed-display toggle: a plain persistent set, deliberately
    /// not connection-scoped and not marked for restore (the global toggle is
    /// meant to outlive the app; that matches the old osascript semantics).
    public func setSleepDisabled(_ disabled: Bool) -> Bool {
        runner.run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    /// Take or release `client`'s hold on `disablesleep`. Writes the system
    /// only when the union of holders becomes non-empty or empty.
    public func setSleepHold(client: Int, holding: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applySleepUnion {
            if holding { sleepHolders.insert(client) } else { sleepHolders.remove(client) }
        }
    }

    /// Take or release `client`'s hold on `awdl0 down`.
    public func setAWDLHold(client: Int, holding: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyAWDLUnion {
            if holding { awdlHolders.insert(client) } else { awdlHolders.remove(client) }
        }
    }

    /// A client connection died (app quit or crashed): release everything it
    /// held, restoring the system defaults if it was the last holder. This is
    /// the daemon-era version of the old loops' pid watch.
    public func clientDisconnected(_ client: Int) {
        lock.lock()
        defer { lock.unlock() }
        _ = applySleepUnion { sleepHolders.remove(client) }
        _ = applyAWDLUnion { awdlHolders.remove(client) }
    }

    /// Re-down `awdl0` while any hold is live: macOS re-raises the interface
    /// after sleep/wake, Wi-Fi toggles, or any app requesting AWDL, so the old
    /// loop's every-few-seconds re-assert carries over. The daemon calls this
    /// from its timer; a no-op with no holders.
    public func awdlTick() {
        lock.lock()
        let holding = !awdlHolders.isEmpty
        lock.unlock()
        if holding {
            runner.run("/sbin/ifconfig", ["awdl0", "down"])
        }
    }

    /// Whether nothing is held, so an idle daemon may exit (launchd relaunches
    /// it on demand).
    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sleepHolders.isEmpty && awdlHolders.isEmpty
    }

    // MARK: - CLI symlink

    /// Put the bundled `keepresso` CLI on PATH for DMG installs: the Homebrew
    /// cask links it via its `binary` stanza, but a drag-installed copy has no
    /// such step, and `/usr/local/bin` needs root to write, which is exactly
    /// what this daemon has. Called on every daemon start, so the link also
    /// self-heals after the app moves or updates.
    ///
    /// Deliberately conservative: it creates the link only when nothing is at
    /// `linkPath`, or replaces it only when what's there is a symlink into a
    /// Keepresso bundle (ours to manage, possibly stale). A user's own file or
    /// an unrelated symlink is never touched. Best-effort; failures are not
    /// the daemon's problem to surface.
    public func ensureCLILink(cliPath: String, linkPath: String = "/usr/local/bin/keepresso") {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cliPath) else { return }
        if let destination = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
            guard destination != cliPath, destination.contains("Keepresso.app") else { return }
            try? fm.removeItem(atPath: linkPath)
        } else if fm.fileExists(atPath: linkPath) {
            return // a real file someone else put there; leave it alone
        }
        try? fm.createDirectory(
            atPath: (linkPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: cliPath)
    }

    // MARK: - Union edges (call with the lock held)

    private func applySleepUnion(_ mutate: () -> Void) -> Bool {
        let before = !sleepHolders.isEmpty
        mutate()
        let after = !sleepHolders.isEmpty
        guard before != after else { return true }
        let ok = runner.run("/usr/bin/pmset", ["-a", "disablesleep", after ? "1" : "0"])
        state.set(.sleepDisabled, present: after && ok)
        return ok
    }

    private func applyAWDLUnion(_ mutate: () -> Void) -> Bool {
        let before = !awdlHolders.isEmpty
        mutate()
        let after = !awdlHolders.isEmpty
        guard before != after else { return true }
        let ok = runner.run("/sbin/ifconfig", ["awdl0", after ? "down" : "up"])
        state.set(.awdlDown, present: after && ok)
        return ok
    }
}
