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
        // Discard output to the null device rather than into Pipes we never
        // read: an unread pipe that fills its ~64 KB buffer would wedge the
        // child (and this `waitUntilExit`) forever. These commands are quiet
        // today, but the null device removes the latent deadlock outright.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// How one forced-fan write went. `needsUnlock` is the M3-and-newer firmware
/// refusing manual mode (SMC result 0x82) until the `Ftst` test flag is set;
/// the engine answers it with exactly one unlock-and-retry.
public enum FanWriteResult: Equatable, Sendable {
    case ok
    case needsUnlock
    case failed
}

/// Fan override seam for the daemon (fan writes are root-only, enforced by the
/// SMC itself). ``SMCFanController`` is the real backend; tests use a fake.
public protocol FanControlling: AnyObject, Sendable {
    /// Number of fans, nil when the SMC is unreachable. 0 = fanless.
    func fanCount() -> Int?
    /// Force every fan to `percent` of its min...max RPM range. Boost only:
    /// the backend clamps each fan's target to at least its RPM when the
    /// boost first engaged, so this can never slow a fan below what the
    /// system's own control had chosen.
    func setForced(percent: Int) -> FanWriteResult
    /// Write the firmware test-mode unlock (`Ftst` = 1) that newer machines
    /// require before manual fan mode. Returns whether the write landed.
    func unlock() -> Bool
    /// Hand fan control back to the system (mode 0, unlock cleared).
    func restoreAuto() -> Bool
}

/// The do-nothing backend: the default in tests and wherever fan control
/// isn't wired.
public final class NullFanControl: FanControlling {
    public init() {}
    public func fanCount() -> Int? { nil }
    public func setForced(percent: Int) -> FanWriteResult { .failed }
    public func unlock() -> Bool { false }
    public func restoreAuto() -> Bool { false }
}

/// What the daemon still owes the system if it dies mid-hold: markers persist
/// on disk (root-owned, under `/var/db`) and are settled on the next daemon
/// launch, including the launchd `RunAtLoad` start after a reboot or crash.
public enum HelperRestoreMarker: String, CaseIterable, Sendable {
    /// We set `pmset disablesleep 1` for a hold and haven't set it back.
    case sleepDisabled = "sleep-disabled"
    /// We took `awdl0` down for a hold and haven't raised it.
    case awdlDown = "awdl-down"
    /// We forced the fans for a hold and haven't restored auto control.
    case fanForced = "fan-forced"
    /// A clear of wake schedules was requested but did not finish. Next
    /// daemon launch retries the cancel so a disable cannot leave system
    /// schedules behind after a crash. Successful schedules do not set this
    /// (they are meant to survive reboots).
    case wakeClearPending = "wake-clear-pending"
}

/// Persistence seam for the restore markers. A marker may carry a small value
/// payload (the sleep-disabled debt records the exact prior `disablesleep`
/// setting); markers that only signal presence store an empty value.
public protocol HelperRestoreStatePersisting: AnyObject, Sendable {
    func markers() -> Set<HelperRestoreMarker>
    /// The marker's stored value, or nil when the marker is absent.
    func value(for marker: HelperRestoreMarker) -> String?
    /// Store `value` for the marker (empty string is a plain presence
    /// marker); nil removes it.
    func set(_ marker: HelperRestoreMarker, value: String?)
}

public extension HelperRestoreStatePersisting {
    /// Presence-only convenience for the markers that carry no payload.
    func set(_ marker: HelperRestoreMarker, present: Bool) {
        set(marker, value: present ? "" : nil)
    }
}

/// Real marker store: one file per marker in a root-owned directory, the
/// marker's value as the file's contents (empty for presence-only markers,
/// which also keeps pre-1.17 marker files readable).
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

    public func value(for marker: HelperRestoreMarker) -> String? {
        try? String(contentsOf: url(for: marker), encoding: .utf8)
    }

    public func set(_ marker: HelperRestoreMarker, value: String?) {
        if let value {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomic like every other store: a daemon crash mid-write must
            // not leave a torn value (a lost sleep-disabled payload would
            // restore 0 over the user's own setting).
            try? Data(value.utf8).write(to: url(for: marker), options: .atomic)
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
    private let fans: FanControlling

    private var sleepHolders: Set<Int> = []
    private var awdlHolders: Set<Int> = []
    /// Client → wanted fan boost percent; the effective target is the max.
    private var fanHolders: [Int: Int] = [:]
    /// Client → pid whose CPU priority is raised while a game plays. The
    /// effective set is the union of held pids.
    private var priorityHolders: [Int: Int] = [:]
    /// Consecutive failed fan writes; past the cap the engine surrenders the
    /// hold instead of fighting the firmware forever.
    private var fanFailureStreak = 0
    /// How many consecutive failed writes drop the fan hold.
    static let maxFanFailures = 5
    /// Set once ``fanTick()`` gave up on a hold, so the state is inspectable
    /// (and the app can tell "boost silently ended" from "still boosting").
    public private(set) var fanHoldDropped = false

    /// Reads the current global `disablesleep` value. A separate seam because
    /// ``HelperCommandRunning`` only reports exit status; the sleep hold needs
    /// the prior value so releasing restores it instead of assuming 0.
    private let sleepDisabledReader: () -> Bool?

    public init(
        runner: HelperCommandRunning,
        state: HelperRestoreStatePersisting,
        fans: FanControlling = NullFanControl(),
        sleepDisabledReader: @escaping () -> Bool? = { nil }
    ) {
        self.runner = runner
        self.state = state
        self.fans = fans
        self.sleepDisabledReader = sleepDisabledReader
    }

    /// Real reader: `pmset -g` output through the same pure parser the app's
    /// closed-display toggle uses.
    public static func readSleepDisabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return PMSetSleepControl.parseSleepDisabled(from: String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    /// Settle debts from a previous daemon life (crash, kill, reboot
    /// mid-hold): a leftover marker means the system was never restored, so
    /// restore it now and clear the marker. Called once at daemon launch,
    /// before the listener accepts anyone.
    public func restoreAtLaunch() {
        let leftovers = state.markers()
        if leftovers.contains(.sleepDisabled) {
            runner.run("/usr/bin/pmset", ["-a", "disablesleep", recordedSleepRestoreValue()])
            state.set(.sleepDisabled, present: false)
        }
        if leftovers.contains(.awdlDown) {
            runner.run("/sbin/ifconfig", ["awdl0", "up"])
            state.set(.awdlDown, present: false)
        }
        if leftovers.contains(.fanForced) {
            _ = fans.restoreAuto()
            state.set(.fanForced, present: false)
        }
        if leftovers.contains(.wakeClearPending) {
            _ = clearWakeSchedules()
        }
    }

    /// The manual closed-display toggle: a plain persistent set, deliberately
    /// not connection-scoped and not marked for restore (the global toggle is
    /// meant to outlive the app; that matches the old osascript semantics).
    public func setSleepDisabled(_ disabled: Bool) -> Bool {
        runner.run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    /// Put the Mac to sleep right now. Not a hold: there is nothing to restore
    /// on disconnect, and the machine may be asleep before the caller hears
    /// the reply.
    public func sleepNow() -> Bool {
        runner.run("/usr/bin/pmset", ["sleepnow"])
    }

    /// One-shot wake. Schedules persist across reboots by design.
    public func scheduleOneShotWake(at dateString: String) -> Bool {
        runner.run("/usr/bin/pmset", ["schedule", "wake", dateString])
    }

    /// Repeating wakeorpoweron. Replaces the system-wide repeating pair.
    public func scheduleRepeatingWake(days: String, time: String) -> Bool {
        runner.run("/usr/bin/pmset", ["repeat", "wakeorpoweron", days, time])
    }

    /// Cancel one-shot schedules and the repeating pair. Debt-by-success:
    /// the pending marker only clears when both cancels landed, so a partial
    /// failure (say, the repeating pair surviving a failed `repeat cancel`)
    /// is retried at the next daemon launch instead of reported as done.
    public func clearWakeSchedules() -> Bool {
        // cancelall drops every one-shot (including non-Keepresso owners on
        // some OS versions); repeat cancel drops the single system pair.
        // Acceptable: wake schedules are a power-user feature and the UI
        // re-applies the desired config on every save.
        state.set(.wakeClearPending, present: true)
        let a = runner.run("/usr/bin/pmset", ["schedule", "cancelall"])
        let b = runner.run("/usr/bin/pmset", ["repeat", "cancel"])
        let ok = a && b
        if ok { state.set(.wakeClearPending, present: false) }
        return ok
    }

    /// Apply a full desired schedule in one step: clear previous installs,
    /// then install what remains. `nil` parts are not wanted; all `nil`
    /// clears everything. Returns whether every required step succeeded.
    /// This is the one place that owns the clear-then-install ordering; the
    /// app calls it through a single XPC verb rather than sequencing the
    /// primitives itself.
    public func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool {
        let wantsRepeat = repeatDays != nil && repeatTime != nil
        guard oneShot != nil || wantsRepeat else {
            return clearWakeSchedules()
        }
        // Clear previous Keepresso installs so we don't stack one-shots. The
        // install proceeds even when the clear failed; the marker handling
        // below settles the debt either way.
        _ = clearWakeSchedules()
        var ok = true
        if let oneShot {
            ok = scheduleOneShotWake(at: oneShot) && ok
        }
        if let repeatDays, let repeatTime {
            ok = scheduleRepeatingWake(days: repeatDays, time: repeatTime) && ok
        }
        // Once the install landed, the desired state is "schedules present":
        // a leftover clear debt from the step above would make the next
        // daemon launch wipe what was just installed. On failure any existing
        // debt stays, and the app re-applies the config at its next launch.
        if ok { state.set(.wakeClearPending, present: false) }
        return ok
    }

    /// Convenience over the primitive form for a full config.
    public func applyWakeSchedule(_ config: WakeScheduleConfig) -> Bool {
        let parts = config.pmsetArguments
        return applyWakeSchedule(
            oneShot: parts.oneShot,
            repeatDays: parts.repeatDays,
            repeatTime: parts.repeatTime
        )
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

    /// Take or release `client`'s forced-fan hold at `percent`. With several
    /// holders the hottest request wins (the max percent). Writes only when
    /// the effective target changes.
    public func setFanHold(client: Int, holding: Bool, percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyFanUnion {
            if holding {
                fanHolders[client] = max(30, min(percent, 100))
            } else {
                fanHolders.removeValue(forKey: client)
            }
        }
    }

    /// Take or release `client`'s CPU-priority hold on `pid` (the frontmost
    /// game or streaming client). Raising priority needs root, which is why
    /// this lives in the daemon at all. Deliberately no on-disk restore
    /// marker, unlike the sleep and fan debts: priority dies with the target
    /// process, and after a crash or reboot the recorded pid could belong to
    /// an innocent newcomer, so restoring it would be worse than the leak.
    public func setPriorityHold(client: Int, holding: Bool, pid: Int) -> Bool {
        guard pid > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        return applyPriorityUnion {
            if holding {
                priorityHolders[client] = pid
            } else {
                priorityHolders.removeValue(forKey: client)
            }
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
        _ = applyFanUnion { fanHolders.removeValue(forKey: client) }
        _ = applyPriorityUnion { priorityHolders.removeValue(forKey: client) }
    }

    /// Re-down `awdl0` while any hold is live: macOS re-raises the interface
    /// after sleep/wake, Wi-Fi toggles, or any app requesting AWDL, so the old
    /// loop's every-few-seconds re-assert carries over. The daemon calls this
    /// from its timer; a no-op with no holders.
    public func awdlTick() {
        lock.lock()
        defer { lock.unlock() }
        // Hold the lock across the write. Releasing it first let a concurrent
        // `clientDisconnected` bring `awdl0` back up and clear the marker in
        // between, after which this tick re-downed it with no holder left.
        if !awdlHolders.isEmpty {
            runner.run("/sbin/ifconfig", ["awdl0", "down"])
        }
    }

    /// Re-force the fans while any hold is live: thermalmonitord re-takes fan
    /// control on newer machines, so the target is re-written every tick, the
    /// AWDL loop's re-assert carried over to fans. Repeated failures surrender
    /// the hold (restoring auto as best as possible) rather than fighting the
    /// firmware forever; ``fanHoldDropped`` records that it happened.
    public func fanTick() {
        lock.lock()
        defer { lock.unlock() }
        // Hold the lock across the whole tick, including the SMC write. The old
        // read-then-unlock-then-write let a concurrent `clientDisconnected`
        // release the last holder and restore auto in between, after which this
        // re-forced the fans with the `.fanForced` marker already cleared, so
        // nothing (not even the next launch's recovery, which keys off the
        // marker) would put them back. `writeFanTarget`/`restoreAuto`/`state.set`
        // all run under this same lock on the union edges, so there's no
        // reentrancy.
        guard let target = fanHolders.values.max() else { return }
        if writeFanTarget(target) {
            fanFailureStreak = 0
            return
        }
        fanFailureStreak += 1
        guard fanFailureStreak >= Self.maxFanFailures else { return }
        fanHolders.removeAll()
        fanFailureStreak = 0
        fanHoldDropped = true
        // The marker clears only when the restore actually landed, so a crash
        // after a failed restore still settles the debt at the next launch.
        let ok = fans.restoreAuto()
        state.set(.fanForced, present: !ok)
    }

    /// Whether nothing is held, so an idle daemon may exit (launchd relaunches
    /// it on demand).
    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sleepHolders.isEmpty && awdlHolders.isEmpty
            && fanHolders.isEmpty && priorityHolders.isEmpty
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
        if after {
            // Snapshot the prior value before forcing 1, so the release edge
            // restores what was really there (the user's own persistent
            // toggle, another tool's setting) instead of assuming 0. A failed
            // read records "0", which matches the pre-value behavior.
            let prior = sleepDisabledReader() ?? false
            let ok = runner.run("/usr/bin/pmset", ["-a", "disablesleep", "1"])
            state.set(.sleepDisabled, value: ok ? (prior ? "1" : "0") : nil)
            return ok
        }
        let ok = runner.run("/usr/bin/pmset", ["-a", "disablesleep", recordedSleepRestoreValue()])
        // Debt-by-success: a failed restore keeps the marker (and its value)
        // for the next daemon launch to settle.
        if ok { state.set(.sleepDisabled, value: nil) }
        return ok
    }

    /// The value the sleep-disabled debt should restore. Only a recorded "1"
    /// restores 1; an empty marker written by a pre-1.17 daemon, or anything
    /// unreadable, restores 0 exactly as those daemons would have.
    private func recordedSleepRestoreValue() -> String {
        state.value(for: .sleepDisabled) == "1" ? "1" : "0"
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

    /// Fan version of the union edge: the effective target is the max percent
    /// across holders, and a change in that target (including to or from
    /// nothing) is what writes hardware. Engaging resets the failure streak
    /// and the dropped flag: a fresh hold gets a fresh chance.
    ///
    /// The restore marker is debt-by-attempt, not debt-by-success: a forced
    /// write can partially land (mode set on one fan, refused on the next)
    /// and `fanTick` retries a failed engage into success later, so the
    /// marker goes down on the first attempt and comes off only after a
    /// restore that actually succeeded. A spurious restore of already-auto
    /// fans is harmless, forced fans with no marker are not.
    private func applyFanUnion(_ mutate: () -> Void) -> Bool {
        let before = fanHolders.values.max()
        mutate()
        let after = fanHolders.values.max()
        guard before != after else { return true }
        if let target = after {
            fanFailureStreak = 0
            fanHoldDropped = false
            state.set(.fanForced, present: true)
            return writeFanTarget(target)
        }
        let ok = fans.restoreAuto()
        state.set(.fanForced, present: !ok)
        return ok
    }

    /// The boost every held pid gets. Modest on purpose: enough to win
    /// scheduling against background work, not enough to starve the system.
    static let priorityNice = -10

    /// Priority version of the union edge: renice newly held pids down (a
    /// negative nice needs root) and restore departures to 0. Restores are
    /// best-effort, the game may have quit already, which is also why there
    /// is no re-assert tick: nice sticks for the life of the process.
    private func applyPriorityUnion(_ mutate: () -> Void) -> Bool {
        let before = Set(priorityHolders.values)
        mutate()
        let after = Set(priorityHolders.values)
        guard before != after else { return true }
        var ok = true
        for pid in after.subtracting(before) {
            ok = runner.run("/usr/bin/renice", [String(Self.priorityNice), "-p", String(pid)]) && ok
        }
        for pid in before.subtracting(after) {
            _ = runner.run("/usr/bin/renice", ["0", "-p", String(pid)])
        }
        return ok
    }

    /// One forced write, with the single unlock-and-retry newer firmware
    /// needs (SMC 0x82 until `Ftst` is set).
    private func writeFanTarget(_ percent: Int) -> Bool {
        switch fans.setForced(percent: percent) {
        case .ok:
            return true
        case .failed:
            return false
        case .needsUnlock:
            guard fans.unlock() else { return false }
            return fans.setForced(percent: percent) == .ok
        }
    }
}
