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
    private struct StreamState {
        var generation: UInt64
        var ownerClientID: Int?
        var highestClientID: Int
    }

    private let lock = NSLock()
    private var statesByStream: [String: StreamState] = [:]
    private let maximumStreams: Int

    public init(maximumStreams: Int = 1_024) {
        precondition(maximumStreams > 0)
        self.maximumStreams = maximumStreams
    }

    public func apply(
        streamID: String,
        generation: UInt64,
        clientID: Int,
        operation: (_ previousClientID: Int?) -> Bool
    ) -> Bool {
        guard !streamID.isEmpty, streamID.utf8.count <= 128 else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let state = statesByStream[streamID] {
            guard generation >= state.generation else { return false }
            if generation == state.generation {
                // The live owner may retry its exact intent. Any takeover of
                // this generation must come from a strictly newer listener
                // connection, including after the owner disconnected.
                let isLiveOwnerRetry = state.ownerClientID == clientID
                guard isLiveOwnerRetry || clientID > state.highestClientID else {
                    return false
                }
            }
        } else {
            guard statesByStream.count < maximumStreams else { return false }
        }

        let previousState = statesByStream[streamID]
        // After disconnect, the live owner is nil but the last accepted
        // client remains the logical predecessor. Passing it lets domain
        // state such as a surrendered fan hold migrate to the new connection.
        let previousClientID = previousState?.ownerClientID
            ?? previousState?.highestClientID
        // Advance ownership before applying. The registry lock remains held
        // while the engine moves the holder, making connection migration and
        // its system reconciliation one indivisible operation to disconnect.
        statesByStream[streamID] = StreamState(
            generation: generation,
            ownerClientID: clientID,
            // A higher generation starts a new connection-order epoch. At
            // the same generation, accepted reconnect IDs only increase.
            highestClientID: generation == statesByStream[streamID]?.generation
                ? max(statesByStream[streamID]?.highestClientID ?? clientID, clientID)
                : clientID
        )
        return operation(previousClientID)
    }

    /// Compatibility form for callers that only need monotonic ordering.
    public func apply(
        streamID: String,
        generation: UInt64,
        operation: () -> Bool
    ) -> Bool {
        apply(streamID: streamID, generation: generation, clientID: 0) { _ in
            operation()
        }
    }

    /// Release this connection's domain holder only if it still owns at
    /// least one logical stream. Entries remain as generation tombstones, so
    /// a delayed pre-release replay cannot revive a hold after disconnect.
    public func clientDisconnected(
        _ clientID: Int,
        operation: () -> Void
    ) {
        lock.lock()
        let ownedStreamIDs = statesByStream.compactMap { streamID, state in
            state.ownerClientID == clientID ? streamID : nil
        }
        guard !ownedStreamIDs.isEmpty else {
            lock.unlock()
            return
        }
        for streamID in ownedStreamIDs {
            statesByStream[streamID]?.ownerClientID = nil
        }
        // `highestClientID` remains in the tombstone. The disconnected owner
        // and all older connections stay fenced, while a later connection
        // with a larger listener client ID may take over the same generation.
        // Keep the registry lock through the engine release. A reconnect
        // cannot claim the stream between the ownership check and cleanup.
        operation()
        lock.unlock()
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

/// Atomically coordinates XPC connection acceptance with daemon shutdown.
/// Once an idle exit is claimed, later connections are rejected instead of
/// being accepted in the gap between a client-count sample and `exit(0)`.
public final class HelperShutdownGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextClientID = 1
    private var liveConnections = 0
    private var terminateRequested = false
    private var consecutiveIdleChecks = 0
    private var shuttingDown = false

    public init() {}

    /// Register an accepted listener connection and return its monotonic ID.
    /// Nil means shutdown already won and the listener must reject it.
    public func acceptConnection() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !shuttingDown else { return nil }
        let clientID = nextClientID
        nextClientID += 1
        liveConnections += 1
        consecutiveIdleChecks = 0
        return clientID
    }

    public func connectionEnded() {
        lock.lock()
        liveConnections = max(0, liveConnections - 1)
        lock.unlock()
    }

    public func requestTermination() {
        lock.lock()
        terminateRequested = true
        lock.unlock()
    }

    /// Check engine idleness while connection acceptance is blocked by this
    /// gate's lock. A successful decision permanently closes the gate.
    public func claimExitIfAllowed(holdsIdle: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !shuttingDown else { return true }
        guard liveConnections == 0, holdsIdle() else {
            consecutiveIdleChecks = 0
            return false
        }
        consecutiveIdleChecks += 1
        guard terminateRequested || consecutiveIdleChecks >= 2 else {
            return false
        }
        shuttingDown = true
        return true
    }

    public var isShuttingDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shuttingDown
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
    /// Clients whose fan hold was surrendered after repeated firmware errors.
    /// This status follows reconnect ownership and survives disconnect until
    /// an explicit release, preventing same-intent replay from re-engaging it.
    private var droppedFanClients: Set<Int> = []
    /// Consecutive failed fan writes; past the cap the engine surrenders the
    /// hold instead of fighting the firmware forever.
    private var fanFailureStreak = 0
    /// How many consecutive failed writes drop the fan hold.
    static let maxFanFailures = 5
    /// Compatibility aggregate for tests and diagnostics. XPC callers query
    /// their own connection through ``fanHoldDropped(client:)``.
    public var fanHoldDropped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !droppedFanClients.isEmpty
    }

    public func fanHoldDropped(client: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return droppedFanClients.contains(client)
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
        guard let snapshot = state.snapshot() else { return }
        if snapshot.sleepRestorePending,
           let original = snapshot.sleepOriginalDisablesleep {
            let ok = applyAndConfirmSleepTargetLocked(original)
            if ok { _ = clearPersistedSleepRestore() }
            appliedSleepTarget = nil
        }
        if snapshot.awdlRestorePending {
            let ok = runner.run("/sbin/ifconfig", ["awdl0", "up"])
            if ok { _ = state.update { $0.awdlRestorePending = false } }
        }
        if snapshot.fanRestorePending {
            if fans.restoreAuto() {
                _ = state.update { $0.fanRestorePending = false }
            }
        }
        if snapshot.wakeTransaction != nil {
            _ = recoverWakeTransaction()
        }
    }

    /// The manual closed-display toggle: a plain persistent set, deliberately
    /// not connection-scoped and not marked for restore (the global toggle is
    /// meant to outlive the app; that matches the old osascript semantics).
    public func setSleepDisabled(_ disabled: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = state.snapshot() else { return false }
        if !sleepHolders.isEmpty || snapshot.sleepRestorePending {
            // A manual choice made during a scoped transaction becomes the
            // new restore baseline. The current active or suspended target
            // remains in force until the transaction closes.
            guard state.update({ value in
                value.sleepRestorePending = true
                value.sleepOriginalDisablesleep = disabled
            }) else { return false }
            return sleepHolders.isEmpty ? reconcileSleepTargetLocked() : true
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
        guard state.snapshot() != nil else { return false }
        return runner.run("/usr/bin/pmset", ["schedule", "wake", dateString])
    }

    /// Repeating wakeorpoweron. Replaces the system-wide repeating pair.
    public func scheduleRepeatingWake(days: String, time: String) -> Bool {
        guard state.snapshot() != nil else { return false }
        return runner.run("/usr/bin/pmset", ["repeat", "wakeorpoweron", days, time])
    }

    /// Cancel one-shot schedules and the repeating pair. Debt-by-success:
    /// the pending marker only clears when both cancels landed, so a partial
    /// failure (say, the repeating pair surviving a failed `repeat cancel`)
    /// is retried at the next daemon launch instead of reported as done.
    public func clearWakeSchedules() -> Bool {
        applyWakeSchedule(oneShot: nil, repeatDays: nil, repeatTime: nil)
    }

    /// Apply a full desired schedule in one step: clear previous installs,
    /// then install what remains. `nil` parts are not wanted; all `nil`
    /// clears everything. Returns whether every required step succeeded.
    /// This is the one place that owns the clear-then-install ordering; the
    /// app calls it through a single XPC verb rather than sequencing the
    /// primitives itself.
    public func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool {
        let wantsRepeat = repeatDays != nil && repeatTime != nil
        guard (repeatDays == nil) == (repeatTime == nil) else { return false }
        let transaction = HelperWakeTransaction(
            oneShot: oneShot,
            repeatDays: wantsRepeat ? repeatDays : nil,
            repeatTime: wantsRepeat ? repeatTime : nil,
            phase: .pendingApply
        )
        guard state.update({ $0.wakeTransaction = transaction }) else { return false }
        guard executeWakeTransaction(transaction) else { return false }
        guard state.update({ value in
            value.wakeTransaction?.phase = .applied
        }) else { return false }
        return state.update { $0.wakeTransaction = nil }
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

    /// Retry a wake transaction left by a failed command, crash, or journal
    /// cleanup. The daemon timer may call this repeatedly; an applied phase
    /// performs no further system mutation.
    @discardableResult
    public func recoverWakeTransaction() -> Bool {
        guard let snapshot = state.snapshot() else { return false }
        guard let transaction = snapshot.wakeTransaction else { return true }
        if transaction.phase == .applied {
            return state.update { $0.wakeTransaction = nil }
        }
        guard executeWakeTransaction(transaction) else { return false }
        guard state.update({ value in
            value.wakeTransaction?.phase = .applied
        }) else { return false }
        return state.update { $0.wakeTransaction = nil }
    }

    private func executeWakeTransaction(_ transaction: HelperWakeTransaction) -> Bool {
        // cancelall drops every one-shot; repeat cancel drops the one system
        // pair. Desired entries are installed only after both clears land.
        guard runner.run("/usr/bin/pmset", ["schedule", "cancelall"]),
              runner.run("/usr/bin/pmset", ["repeat", "cancel"])
        else { return false }
        if let oneShot = transaction.oneShot,
           !runner.run("/usr/bin/pmset", ["schedule", "wake", oneShot]) {
            return false
        }
        if let repeatDays = transaction.repeatDays,
           let repeatTime = transaction.repeatTime,
           !runner.run(
                "/usr/bin/pmset",
                ["repeat", "wakeorpoweron", repeatDays, repeatTime]
           ) {
            return false
        }
        return true
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
        setSleepHoldMode(client: client, replacing: nil, mode: mode)
    }

    /// Move one logical sleep stream from an older XPC connection to this
    /// client and apply its latest mode under one engine lock. The registry
    /// calls this while holding its own ownership lock, so invalidation of the
    /// previous connection cannot remove the migrated holder.
    public func setSleepHoldMode(
        client: Int,
        replacing previousClient: Int?,
        mode: SleepHoldMode
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let transactionWasOpen = !sleepHolders.isEmpty
        if let previousClient, previousClient != client {
            sleepHolders.removeValue(forKey: previousClient)
        }
        if mode != .released,
           !transactionWasOpen,
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
        setAWDLHold(client: client, replacing: nil, holding: holding)
    }

    /// Move one logical AWDL stream between connections without creating a
    /// second union holder or an up/down edge during reconnect.
    public func setAWDLHold(
        client: Int,
        replacing previousClient: Int?,
        holding: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyAWDLUnion {
            if let previousClient, previousClient != client {
                awdlHolders.remove(previousClient)
            }
            if holding { awdlHolders.insert(client) } else { awdlHolders.remove(client) }
        }
    }

    /// Take or release `client`'s forced-fan hold at `percent`. With several
    /// holders the hottest request wins (the max percent). Writes only when
    /// the effective target changes.
    public func setFanHold(client: Int, holding: Bool, percent: Int) -> Bool {
        setFanHold(client: client, replacing: nil, holding: holding, percent: percent)
    }

    /// Move one logical fan stream between connections while preserving the
    /// union's effective target across a reconnect retry.
    public func setFanHold(
        client: Int,
        replacing previousClient: Int?,
        holding: Bool,
        percent: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let previousClient, previousClient != client,
           droppedFanClients.remove(previousClient) != nil {
            droppedFanClients.insert(client)
        }
        if !holding {
            droppedFanClients.remove(client)
        }
        let replayingDroppedHold = holding && droppedFanClients.contains(client)
        let reconciled = applyFanUnion {
            if let previousClient, previousClient != client {
                fanHolders.removeValue(forKey: previousClient)
            }
            if holding, !replayingDroppedHold {
                fanHolders[client] = max(30, min(percent, 100))
            } else {
                fanHolders.removeValue(forKey: client)
            }
        }
        return replayingDroppedHold ? false : reconciled
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

    /// Domain-specific disconnects let stream registries guard each cleanup
    /// independently. A connection that no longer owns a migrated stream is
    /// never allowed to remove that stream's new holder.
    public func sleepClientDisconnected(_ client: Int) {
        lock.lock()
        sleepHolders.removeValue(forKey: client)
        _ = reconcileSleepTargetLocked()
        lock.unlock()
    }

    public func awdlClientDisconnected(_ client: Int) {
        lock.lock()
        _ = applyAWDLUnion { awdlHolders.remove(client) }
        lock.unlock()
    }

    public func fanClientDisconnected(_ client: Int) {
        lock.lock()
        // Keep a surrendered status as a reconnect tombstone. A later owner
        // receives this client as `replacing` and migrates the status. Only an
        // explicit release clears it.
        _ = applyFanUnion { fanHolders.removeValue(forKey: client) }
        lock.unlock()
    }

    /// Re-down `awdl0` while any hold is live: macOS re-raises the interface
    /// after sleep/wake, Wi-Fi toggles, or any app requesting AWDL, so the old
    /// loop's every-few-seconds re-assert carries over. The daemon calls this
    /// from its timer; a no-op with no holders.
    public func awdlTick() {
        lock.lock()
        let holding = !awdlHolders.isEmpty && state.snapshot() != nil
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
        guard state.snapshot() != nil,
              let target = fanHolders.values.max() else {
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
            droppedFanClients.formUnion(fanHolders.keys)
            fanHolders.removeAll()
            fanFailureStreak = 0
        }
        lock.unlock()
        if giveUp {
            // Same rule as the union edge: the marker clears only when the
            // restore actually landed, so a crash after a failed restore
            // still settles the debt at the next daemon launch.
            let ok = fans.restoreAuto()
            _ = state.update { $0.fanRestorePending = !ok }
        }
    }

    /// Whether nothing is held, so an idle daemon may exit (launchd relaunches
    /// it on demand).
    public var isIdle: Bool {
        lock.lock()
        let holdsEmpty = sleepHolders.isEmpty && awdlHolders.isEmpty && fanHolders.isEmpty
        lock.unlock()
        guard let snapshot = state.snapshot() else { return false }
        return holdsEmpty && !snapshot.hasRecoveryDebt
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
        guard let snapshot = state.snapshot() else { return false }
        if snapshot.sleepRestorePending {
            // Reuse an unsettled debt. Sampling the currently stuck value here
            // would overwrite the real original and make it permanent.
            return snapshot.sleepOriginalDisablesleep != nil
        }
        guard let original = sleepSettingReader.sleepIsDisabled() else {
            return false
        }
        guard state.update({ value in
            value.sleepOriginalDisablesleep = original
            value.sleepRestorePending = true
        }) else { return false }
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
        guard let snapshot = state.snapshot() else { return false }
        let mode = effectiveSleepModeLocked()
        if mode == .released {
            guard snapshot.sleepRestorePending else {
                appliedSleepTarget = nil
                return true
            }
            guard let original = snapshot.sleepOriginalDisablesleep else { return false }
            guard applyAndConfirmSleepTargetLocked(original) else { return false }
            guard clearPersistedSleepRestore() else { return false }
            appliedSleepTarget = nil
            return true
        }

        if !snapshot.sleepRestorePending,
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
        guard let snapshot = state.snapshot() else { return false }
        let originalHolders = awdlHolders
        let before = !awdlHolders.isEmpty
        mutate()
        let after = !awdlHolders.isEmpty
        guard before != after else { return true }
        if after,
           !state.update({ $0.awdlRestorePending = true }) {
            awdlHolders = originalHolders
            return false
        }
        if !after, !snapshot.awdlRestorePending {
            awdlHolders = originalHolders
            return false
        }
        let ok = runner.run("/sbin/ifconfig", ["awdl0", after ? "down" : "up"])
        if !after, ok {
            return state.update { $0.awdlRestorePending = false }
        }
        return ok
    }

    private func clearPersistedSleepRestore() -> Bool {
        state.update { snapshot in
            snapshot.sleepRestorePending = false
            snapshot.sleepOriginalDisablesleep = nil
        }
    }

    /// Fan version of the union edge: the effective target is the max percent
    /// across holders, and a change in that target (including to or from
    /// nothing) is what writes hardware. Engaging resets the failure streak;
    /// surrendered status is client-scoped and clears only on release.
    ///
    /// The restore marker is debt-by-attempt, not debt-by-success: a forced
    /// write can partially land (mode set on one fan, refused on the next)
    /// and `fanTick` retries a failed engage into success later, so the
    /// marker goes down on the first attempt and comes off only after a
    /// restore that actually succeeded. A spurious restore of already-auto
    /// fans is harmless, forced fans with no marker are not.
    private func applyFanUnion(_ mutate: () -> Void) -> Bool {
        guard let snapshot = state.snapshot() else { return false }
        let originalHolders = fanHolders
        let before = fanHolders.values.max()
        mutate()
        let after = fanHolders.values.max()
        guard before != after else { return true }
        if let target = after {
            fanFailureStreak = 0
            if before == nil,
               !state.update({ $0.fanRestorePending = true }) {
                fanHolders = originalHolders
                return false
            }
            return writeFanTarget(target)
        }
        guard snapshot.fanRestorePending else {
            fanHolders = originalHolders
            return false
        }
        let ok = fans.restoreAuto()
        guard ok else { return false }
        return state.update { $0.fanRestorePending = false }
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
