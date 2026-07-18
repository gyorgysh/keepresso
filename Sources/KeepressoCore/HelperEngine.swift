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

/// Read-only seam for the global `disablesleep` value. The helper snapshots
/// this before its first scoped hold so the last release restores the user's
/// actual setting instead of assuming that it was disabled.
public protocol SleepSettingReading: AnyObject, Sendable {
    func sleepIsDisabled() -> Bool?
}

/// Orders connection-scoped sleep mode requests across XPC reconnects. A
/// client keeps one random stream ID for its process lifetime and increments
/// the generation for every intent. The helper shares this registry across
/// exported connection objects, so a delayed reconnect replay cannot revive
/// an older active hold after suspension or release already won.
public final class SleepModeGenerationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var latestByStream: [String: UInt64] = [:]
    private let maximumStreams: Int

    public init(maximumStreams: Int = 1_024) {
        precondition(maximumStreams > 0)
        self.maximumStreams = maximumStreams
    }

    public func apply(
        streamID: String,
        generation: UInt64,
        operation: () -> Bool
    ) -> Bool {
        guard !streamID.isEmpty, streamID.utf8.count <= 128 else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let latest = latestByStream[streamID], generation < latest {
            return false
        }
        guard latestByStream[streamID] != nil || latestByStream.count < maximumStreams else {
            return false
        }
        // Advance before applying. Even an ambiguous operation failure must
        // fence older requests while the caller retries a newer generation.
        latestByStream[streamID] = generation
        return operation()
    }
}

/// Reads `pmset -g` without changing power settings.
public final class PMSetSleepSettingReader: SleepSettingReading {
    public init() {}

    public func sleepIsDisabled() -> Bool? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return Self.parse(text)
        } catch {
            return nil
        }
    }

    /// `pmset` accepts the command argument `disablesleep`, but current macOS
    /// prints the setting as `SleepDisabled`. Accept both spellings without
    /// case sensitivity so older output remains compatible.
    static func parse(_ text: String) -> Bool? {
        let accepted = ["sleepdisabled", "disablesleep"]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let key = fields.firstIndex(where: {
                accepted.contains($0.lowercased())
            }) else { continue }
            let valueIndex = fields.index(after: key)
            guard fields.indices.contains(valueIndex) else { continue }
            switch fields[valueIndex] {
            case "0": return false
            case "1": return true
            default: continue
            }
        }
        return nil
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

/// Persistence seam for the restore markers.
public protocol HelperRestoreStatePersisting: AnyObject, Sendable {
    func markers() -> Set<HelperRestoreMarker>
    /// Persist or clear one recovery debt. A failed journal write must be
    /// observable so callers never change privileged system state without a
    /// durable recovery path.
    @discardableResult
    func set(_ marker: HelperRestoreMarker, present: Bool) -> Bool
}

/// Optional extension used by current helpers to remember the value that a
/// scoped sleep hold must restore. Older marker stores remain compatible and
/// fall back to `false`, matching the behavior of previous releases.
public protocol HelperSleepRestoreValuePersisting: HelperRestoreStatePersisting {
    func sleepRestoreValue() -> Bool?
    @discardableResult
    func setSleepRestoreValue(_ value: Bool?) -> Bool
}

/// Real marker store: one empty file per marker in a root-owned directory.
public final class FileRestoreState: HelperSleepRestoreValuePersisting {
    private let directory: URL

    public init(directory: URL = URL(fileURLWithPath: "/var/db/sh.gyorgy.keepresso.helper")) {
        self.directory = directory
    }

    public func markers() -> Set<HelperRestoreMarker> {
        Set(HelperRestoreMarker.allCases.filter {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        })
    }

    @discardableResult
    public func set(_ marker: HelperRestoreMarker, present: Bool) -> Bool {
        let markerURL = url(for: marker)
        do {
            if present {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data().write(to: markerURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: markerURL.path) {
                try FileManager.default.removeItem(at: markerURL)
            }
            return true
        } catch {
            return false
        }
    }

    public func sleepRestoreValue() -> Bool? {
        guard let data = try? Data(contentsOf: sleepRestoreURL),
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    @discardableResult
    public func setSleepRestoreValue(_ value: Bool?) -> Bool {
        do {
            guard let value else {
                if FileManager.default.fileExists(atPath: sleepRestoreURL.path) {
                    try FileManager.default.removeItem(at: sleepRestoreURL)
                }
                return true
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((value ? "1" : "0").utf8).write(to: sleepRestoreURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func url(for marker: HelperRestoreMarker) -> URL {
        directory.appendingPathComponent(marker.rawValue, isDirectory: false)
    }

    private var sleepRestoreURL: URL {
        directory.appendingPathComponent("sleep-restore-value", isDirectory: false)
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
    private let sleepSettingReader: SleepSettingReading

    private var sleepHolders: [Int: SleepHoldMode] = [:]
    /// Last target this daemon confirmed. Nil means a persisted recovery debt
    /// predates this process or the latest write had an ambiguous failure.
    private var appliedSleepTarget: Bool?
    private var awdlHolders: Set<Int> = []
    /// Client → wanted fan boost percent; the effective target is the max.
    private var fanHolders: [Int: Int] = [:]
    /// Consecutive failed fan writes; past the cap the engine surrenders the
    /// hold instead of fighting the firmware forever.
    private var fanFailureStreak = 0
    /// How many consecutive failed writes drop the fan hold.
    static let maxFanFailures = 5
    /// Set once ``fanTick()`` gave up on a hold, so the state is inspectable
    /// (and the app can tell "boost silently ended" from "still boosting").
    public private(set) var fanHoldDropped = false

    public init(
        runner: HelperCommandRunning,
        state: HelperRestoreStatePersisting,
        fans: FanControlling = NullFanControl(),
        sleepSettingReader: SleepSettingReading = PMSetSleepSettingReader()
    ) {
        self.runner = runner
        self.state = state
        self.fans = fans
        self.sleepSettingReader = sleepSettingReader
    }

    /// Settle debts from a previous daemon life (crash, kill, reboot
    /// mid-hold): a leftover marker means the system was never restored, so
    /// restore it now and clear the marker. Called once at daemon launch,
    /// before the listener accepts anyone.
    public func restoreAtLaunch() {
        let leftovers = state.markers()
        if leftovers.contains(.sleepDisabled) {
            let original = persistedSleepRestoreValue() ?? false
            let ok = applyAndConfirmSleepTargetLocked(original)
            if ok { _ = clearPersistedSleepRestore() }
            appliedSleepTarget = nil
        }
        if leftovers.contains(.awdlDown) {
            let ok = runner.run("/sbin/ifconfig", ["awdl0", "up"])
            if ok { state.set(.awdlDown, present: false) }
        }
        if leftovers.contains(.fanForced) {
            if fans.restoreAuto() { state.set(.fanForced, present: false) }
        }
        if leftovers.contains(.wakeClearPending) {
            _ = clearWakeSchedules()
        }
    }

    /// The manual closed-display toggle: a plain persistent set, deliberately
    /// not connection-scoped and not marked for restore (the global toggle is
    /// meant to outlive the app; that matches the old osascript semantics).
    public func setSleepDisabled(_ disabled: Bool) -> Bool {
        lock.lock()
        if !sleepHolders.isEmpty {
            // A manual choice made during a scoped transaction becomes the
            // new restore baseline. The current active or suspended target
            // remains in force until the transaction closes.
            let saved = persistSleepRestoreValue(disabled)
            lock.unlock()
            return saved
        }
        lock.unlock()
        return runner.run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
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
        setSleepHoldMode(client: client, mode: holding ? .active : .released)
    }

    /// Apply one client's exact mode. Active wins over suspended when several
    /// clients coexist. The first non-released mode opens one journaled
    /// transaction; only the last release restores and clears its snapshot.
    public func setSleepHoldMode(client: Int, mode: SleepHoldMode) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if mode != .released,
           sleepHolders.isEmpty,
           !beginSleepTransactionLocked() {
            return false
        }
        if mode == .released {
            sleepHolders.removeValue(forKey: client)
        } else {
            sleepHolders[client] = mode
        }
        return reconcileSleepTargetLocked()
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

    /// A client connection died (app quit or crashed): release everything it
    /// held, restoring the system defaults if it was the last holder. This is
    /// the daemon-era version of the old loops' pid watch.
    public func clientDisconnected(_ client: Int) {
        lock.lock()
        defer { lock.unlock() }
        sleepHolders.removeValue(forKey: client)
        _ = reconcileSleepTargetLocked()
        _ = applyAWDLUnion { awdlHolders.remove(client) }
        _ = applyFanUnion { fanHolders.removeValue(forKey: client) }
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

    /// Retry an ambiguous sleep write or restore debt. This is intentionally
    /// periodic: a failed last release has no client left to issue another
    /// request, but the daemon must keep settling the journal until it lands.
    public func sleepTick() {
        lock.lock()
        _ = reconcileSleepTargetLocked()
        lock.unlock()
    }

    /// Re-force the fans while any hold is live: thermalmonitord re-takes fan
    /// control on newer machines, so the target is re-written every tick, the
    /// AWDL loop's re-assert carried over to fans. Repeated failures surrender
    /// the hold (restoring auto as best as possible) rather than fighting the
    /// firmware forever; ``fanHoldDropped`` records that it happened.
    public func fanTick() {
        lock.lock()
        guard let target = fanHolders.values.max() else {
            lock.unlock()
            return
        }
        let failures = fanFailureStreak
        lock.unlock()

        if writeFanTarget(target) {
            lock.lock()
            fanFailureStreak = 0
            lock.unlock()
            return
        }
        lock.lock()
        fanFailureStreak = failures + 1
        let giveUp = fanFailureStreak >= Self.maxFanFailures
        if giveUp {
            fanHolders.removeAll()
            fanFailureStreak = 0
            fanHoldDropped = true
        }
        lock.unlock()
        if giveUp {
            // Same rule as the union edge: the marker clears only when the
            // restore actually landed, so a crash after a failed restore
            // still settles the debt at the next daemon launch.
            let ok = fans.restoreAuto()
            state.set(.fanForced, present: !ok)
        }
    }

    /// Whether nothing is held, so an idle daemon may exit (launchd relaunches
    /// it on demand).
    public var isIdle: Bool {
        lock.lock()
        let holdsEmpty = sleepHolders.isEmpty && awdlHolders.isEmpty && fanHolders.isEmpty
        lock.unlock()
        return holdsEmpty && !state.markers().contains(.sleepDisabled)
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

    private func beginSleepTransactionLocked() -> Bool {
        if state.markers().contains(.sleepDisabled) {
            // Reuse an unsettled debt. Sampling the currently stuck value here
            // would overwrite the real original and make it permanent.
            return true
        }
        guard let original = sleepSettingReader.sleepIsDisabled() else {
            return false
        }
        guard persistSleepRestoreValue(original) else { return false }
        guard state.set(.sleepDisabled, present: true) else {
            if state.set(.sleepDisabled, present: false) {
                _ = (state as? HelperSleepRestoreValuePersisting)?.setSleepRestoreValue(nil)
            }
            return false
        }
        appliedSleepTarget = original
        return true
    }

    private func effectiveSleepModeLocked() -> SleepHoldMode {
        if sleepHolders.values.contains(.active) { return .active }
        if sleepHolders.values.contains(.thermallySuspended) {
            return .thermallySuspended
        }
        return .released
    }

    private func reconcileSleepTargetLocked() -> Bool {
        let mode = effectiveSleepModeLocked()
        if mode == .released {
            guard state.markers().contains(.sleepDisabled) else {
                appliedSleepTarget = nil
                return true
            }
            let original = persistedSleepRestoreValue() ?? false
            guard applyAndConfirmSleepTargetLocked(original) else { return false }
            guard clearPersistedSleepRestore() else { return false }
            appliedSleepTarget = nil
            return true
        }

        if !state.markers().contains(.sleepDisabled),
           !beginSleepTransactionLocked() {
            return false
        }
        let target = mode == .active
        return applyAndConfirmSleepTargetLocked(target)
    }

    /// A successful `pmset` exit is not confirmation that the global setting
    /// actually changed. Read before skipping a known target, and read again
    /// after every write. Unknown or mismatched state keeps the journal debt
    /// and makes the daemon retry on its periodic sleep tick.
    private func applyAndConfirmSleepTargetLocked(_ target: Bool) -> Bool {
        if appliedSleepTarget == target,
           sleepSettingReader.sleepIsDisabled() == target {
            return true
        }
        appliedSleepTarget = nil
        guard runner.run(
            "/usr/bin/pmset",
            ["-a", "disablesleep", target ? "1" : "0"]
        ) else {
            return false
        }
        guard sleepSettingReader.sleepIsDisabled() == target else {
            return false
        }
        appliedSleepTarget = target
        return true
    }

    private func applyAWDLUnion(_ mutate: () -> Void) -> Bool {
        let before = !awdlHolders.isEmpty
        mutate()
        let after = !awdlHolders.isEmpty
        guard before != after else { return true }
        if after { state.set(.awdlDown, present: true) }
        let ok = runner.run("/sbin/ifconfig", ["awdl0", after ? "down" : "up"])
        if !after, ok { state.set(.awdlDown, present: false) }
        return ok
    }

    private func persistedSleepRestoreValue() -> Bool? {
        (state as? HelperSleepRestoreValuePersisting)?.sleepRestoreValue()
    }

    private func persistSleepRestoreValue(_ value: Bool) -> Bool {
        guard let persistence = state as? HelperSleepRestoreValuePersisting else {
            // Legacy stores can safely restore the historical default only.
            return value == false
        }
        return persistence.setSleepRestoreValue(value)
    }

    private func clearPersistedSleepRestore() -> Bool {
        // Keep the exact snapshot until the marker itself is gone. A crash
        // between these operations then still has enough information to retry.
        guard state.set(.sleepDisabled, present: false) else { return false }
        return (state as? HelperSleepRestoreValuePersisting)?.setSleepRestoreValue(nil) ?? true
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
