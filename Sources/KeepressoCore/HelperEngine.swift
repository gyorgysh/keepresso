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

/// Durable wake transaction written before the helper touches `pmset`.
/// `pendingApply` means the desired schedule still needs a full clear and
/// install. `applied` means the system commands all succeeded and only
/// journal cleanup remains, so recovery must not cancel the schedule again.
public struct HelperWakeTransaction: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case pendingApply
        case applied
    }

    public var oneShot: String?
    public var repeatDays: String?
    public var repeatTime: String?
    public var phase: Phase

    public init(
        oneShot: String?,
        repeatDays: String?,
        repeatTime: String?,
        phase: Phase = .pendingApply
    ) {
        self.oneShot = oneShot
        self.repeatDays = repeatDays
        self.repeatTime = repeatTime
        self.phase = phase
    }
}

/// Optional extension for helpers new enough to recover the full desired
/// wake schedule, including after a daemon crash between apply and cleanup.
public protocol HelperWakeTransactionPersisting: HelperRestoreStatePersisting {
    func wakeTransaction() -> HelperWakeTransaction?
    @discardableResult
    func setWakeTransaction(_ transaction: HelperWakeTransaction?) -> Bool
}

/// Real marker store: one empty file per marker in a root-owned directory.
public final class FileRestoreState:
    HelperSleepRestoreValuePersisting,
    HelperWakeTransactionPersisting
{
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
                if FileManager.default.fileExists(atPath: markerURL.path) { return true }
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

    public func wakeTransaction() -> HelperWakeTransaction? {
        guard let data = try? Data(contentsOf: wakeTransactionURL) else { return nil }
        return try? JSONDecoder().decode(HelperWakeTransaction.self, from: data)
    }

    @discardableResult
    public func setWakeTransaction(_ transaction: HelperWakeTransaction?) -> Bool {
        do {
            guard let transaction else {
                if FileManager.default.fileExists(atPath: wakeTransactionURL.path) {
                    try FileManager.default.removeItem(at: wakeTransactionURL)
                }
                return true
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(transaction)
            try data.write(to: wakeTransactionURL, options: .atomic)
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

    private var wakeTransactionURL: URL {
        directory.appendingPathComponent("wake-transaction.json", isDirectory: false)
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
    private var fanHoldDroppedValue = false

    public var fanHoldDropped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fanHoldDroppedValue
    }

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
        lock.lock()
        defer { lock.unlock() }
        appliedSleepTarget = nil
        _ = reconcileSleepTargetLocked()
        _ = reconcileAWDLLocked(reassertWhileHeld: false)
        _ = reconcileFanLocked(reassertWhileHeld: false)
        _ = retryWakeTransactionLocked()
    }

    /// The manual closed-display toggle: a plain persistent set, deliberately
    /// not connection-scoped and not marked for restore (the global toggle is
    /// meant to outlive the app; that matches the old osascript semantics).
    public func setSleepDisabled(_ disabled: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if state.markers().contains(.sleepDisabled) {
            // A manual choice made during a scoped transaction becomes the
            // new restore baseline. The current active or suspended target
            // remains in force until the transaction closes. A marker, not
            // a live holder, defines the transaction because a failed final
            // restore has no holder left but still owns the saved baseline.
            guard persistSleepRestoreValue(disabled) else { return false }
            return reconcileSleepTargetLocked()
        }
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
        lock.lock()
        defer { lock.unlock() }
        guard !state.markers().contains(.wakeClearPending) else { return false }
        return scheduleOneShotWakeLocked(at: dateString)
    }

    /// Repeating wakeorpoweron. Replaces the system-wide repeating pair.
    public func scheduleRepeatingWake(days: String, time: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !state.markers().contains(.wakeClearPending) else { return false }
        return scheduleRepeatingWakeLocked(days: days, time: time)
    }

    /// Cancel one-shot schedules and the repeating pair. Debt-by-success:
    /// the pending marker only clears when both cancels landed, so a partial
    /// failure (say, the repeating pair surviving a failed `repeat cancel`)
    /// is retried at the next daemon launch instead of reported as done.
    public func clearWakeSchedules() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let transaction = HelperWakeTransaction(
            oneShot: nil,
            repeatDays: nil,
            repeatTime: nil
        )
        guard beginWakeTransactionLocked(transaction) else { return false }
        // Once the durable intent and debt marker exist, the helper owns
        // completion. A transient pmset or cleanup failure is retried by the
        // periodic tick and must not make the app resubmit the same intent.
        _ = retryWakeTransactionLocked()
        return true
    }

    /// Apply a full desired schedule in one step: clear previous installs,
    /// then install what remains. `nil` parts are not wanted; all `nil`
    /// clears everything. Returns whether every required step succeeded.
    /// This is the one place that owns the clear-then-install ordering; the
    /// app calls it through a single XPC verb rather than sequencing the
    /// primitives itself. Returns true once the durable desired transaction
    /// is accepted; the helper may still be retrying transient pmset work.
    public func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wantsRepeat = repeatDays != nil && repeatTime != nil
        let transaction = HelperWakeTransaction(
            oneShot: oneShot,
            repeatDays: wantsRepeat ? repeatDays : nil,
            repeatTime: wantsRepeat ? repeatTime : nil
        )
        guard beginWakeTransactionLocked(transaction) else { return false }
        _ = retryWakeTransactionLocked()
        return true
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
        defer { lock.unlock() }
        _ = reconcileAWDLLocked(reassertWhileHeld: true)
    }

    /// Retry an ambiguous sleep write or restore debt. This is intentionally
    /// periodic: a failed last release has no client left to issue another
    /// request, but the daemon must keep settling the journal until it lands.
    public func sleepTick() {
        lock.lock()
        _ = reconcileSleepTargetLocked()
        lock.unlock()
    }

    /// Retry a pending wake clear. Wake scheduling calls and this tick share
    /// the engine lock, so recovery can never erase a schedule just installed
    /// by a concurrent apply operation.
    public func wakeTick() {
        lock.lock()
        defer { lock.unlock() }
        _ = retryWakeTransactionLocked()
    }

    /// Re-force the fans while any hold is live: thermalmonitord re-takes fan
    /// control on newer machines, so the target is re-written every tick, the
    /// AWDL loop's re-assert carried over to fans. Repeated failures surrender
    /// the hold (restoring auto as best as possible) rather than fighting the
    /// firmware forever; ``fanHoldDropped`` records that it happened.
    public func fanTick() {
        lock.lock()
        defer { lock.unlock() }
        _ = reconcileFanLocked(reassertWhileHeld: true)
    }

    /// Whether nothing is held, so an idle daemon may exit (launchd relaunches
    /// it on demand).
    public var isIdle: Bool {
        lock.lock()
        let holdsEmpty = sleepHolders.isEmpty && awdlHolders.isEmpty && fanHolders.isEmpty
        let debtsEmpty = state.markers().isEmpty
        lock.unlock()
        return holdsEmpty && debtsEmpty
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
        let original = awdlHolders
        let before = !awdlHolders.isEmpty
        mutate()
        let after = !awdlHolders.isEmpty
        guard before != after else { return true }
        if after, !state.set(.awdlDown, present: true) {
            awdlHolders = original
            return false
        }
        let ok = runner.run("/sbin/ifconfig", ["awdl0", after ? "down" : "up"])
        guard ok else { return false }
        if !after { return state.set(.awdlDown, present: false) }
        return true
    }

    private func reconcileAWDLLocked(reassertWhileHeld: Bool) -> Bool {
        if !awdlHolders.isEmpty {
            guard reassertWhileHeld else { return true }
            if !state.markers().contains(.awdlDown),
               !state.set(.awdlDown, present: true) {
                return false
            }
            return runner.run("/sbin/ifconfig", ["awdl0", "down"])
        }
        guard state.markers().contains(.awdlDown) else { return true }
        guard runner.run("/sbin/ifconfig", ["awdl0", "up"]) else { return false }
        return state.set(.awdlDown, present: false)
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
        let original = fanHolders
        let before = fanHolders.values.max()
        mutate()
        let after = fanHolders.values.max()
        guard before != after else { return true }
        if let target = after {
            if !state.markers().contains(.fanForced),
               !state.set(.fanForced, present: true) {
                fanHolders = original
                return false
            }
            fanFailureStreak = 0
            fanHoldDroppedValue = false
            return writeFanTarget(target)
        }
        guard fans.restoreAuto() else { return false }
        return state.set(.fanForced, present: false)
    }

    private func reconcileFanLocked(reassertWhileHeld: Bool) -> Bool {
        guard let target = fanHolders.values.max() else {
            guard state.markers().contains(.fanForced) else { return true }
            guard fans.restoreAuto() else { return false }
            return state.set(.fanForced, present: false)
        }
        guard reassertWhileHeld else { return true }
        if !state.markers().contains(.fanForced),
           !state.set(.fanForced, present: true) {
            return false
        }
        if writeFanTarget(target) {
            fanFailureStreak = 0
            return true
        }
        fanFailureStreak += 1
        guard fanFailureStreak >= Self.maxFanFailures else { return false }
        fanHolders.removeAll()
        fanFailureStreak = 0
        fanHoldDroppedValue = true
        guard fans.restoreAuto() else { return false }
        return state.set(.fanForced, present: false)
    }

    private func scheduleOneShotWakeLocked(at dateString: String) -> Bool {
        runner.run("/usr/bin/pmset", ["schedule", "wake", dateString])
    }

    private func scheduleRepeatingWakeLocked(days: String, time: String) -> Bool {
        runner.run("/usr/bin/pmset", ["repeat", "wakeorpoweron", days, time])
    }

    private func cancelWakeSchedulesLocked() -> Bool {
        // cancelall drops every one-shot (including non-Keepresso owners on
        // some OS versions); repeat cancel drops the single system pair.
        // Both commands always run so a partial failure leaves as little
        // stale state as possible, with the marker retained for another try.
        let oneShots = runner.run("/usr/bin/pmset", ["schedule", "cancelall"])
        let repeating = runner.run("/usr/bin/pmset", ["repeat", "cancel"])
        return oneShots && repeating
    }

    private func beginWakeTransactionLocked(_ transaction: HelperWakeTransaction) -> Bool {
        guard persistWakeTransactionLocked(transaction) else { return false }
        guard state.set(.wakeClearPending, present: true) else { return false }
        return true
    }

    private func retryWakeTransactionLocked() -> Bool {
        guard state.markers().contains(.wakeClearPending) else { return true }
        let persistence = state as? HelperWakeTransactionPersisting
        var transaction = persistence?.wakeTransaction() ?? HelperWakeTransaction(
            oneShot: nil,
            repeatDays: nil,
            repeatTime: nil
        )
        if transaction.phase == .pendingApply {
            guard cancelWakeSchedulesLocked() else { return false }
            var ok = true
            if let oneShot = transaction.oneShot {
                ok = scheduleOneShotWakeLocked(at: oneShot) && ok
            }
            if let repeatDays = transaction.repeatDays,
               let repeatTime = transaction.repeatTime {
                ok = scheduleRepeatingWakeLocked(days: repeatDays, time: repeatTime) && ok
            }
            guard ok else { return false }
            transaction.phase = .applied
            if let persistence {
                // Persist confirmation before marker cleanup. If unlinking
                // the marker fails, every later tick skips the pmset writes
                // and retries cleanup only, including after daemon restart.
                guard persistence.setWakeTransaction(transaction) else { return false }
            }
        }
        guard state.set(.wakeClearPending, present: false) else { return false }
        _ = persistence?.setWakeTransaction(nil)
        return true
    }

    private func persistWakeTransactionLocked(_ transaction: HelperWakeTransaction) -> Bool {
        guard let persistence = state as? HelperWakeTransactionPersisting else {
            // A legacy store can safely represent only a pending clear via
            // the marker itself. Installing a schedule without its durable
            // desired value would make crash recovery erase it permanently.
            return transaction.oneShot == nil
                && transaction.repeatDays == nil
                && transaction.repeatTime == nil
        }
        return persistence.setWakeTransaction(transaction)
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
