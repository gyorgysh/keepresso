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
    func fanCount() -> Int?
    func setForced(percent: Int) -> FanWriteResult
    /// Write the firmware test-mode unlock (`Ftst` = 1) that newer machines
    /// require before manual fan mode. Returns whether the write landed.
    func unlock() -> Bool
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
    case sleepDisabled = "sleep-disabled"
    case awdlDown = "awdl-down"
    case fanForced = "fan-forced"
    case wakeClearPending = "wake-clear-pending"
    case keyboardLock = "keyboard-lock"
    case batteryLowPower = "battery-low-power"
    case adapterLowPower = "adapter-low-power"
}

/// Persistence seam for the restore markers. A marker may carry a small value
/// payload (the sleep-disabled debt records the exact prior `disablesleep`
/// setting); markers that only signal presence store an empty value.
public protocol HelperRestoreStatePersisting: AnyObject, Sendable {
    func markers() -> Set<HelperRestoreMarker>
    func value(for marker: HelperRestoreMarker) -> String?
    func set(_ marker: HelperRestoreMarker, value: String?)
}

public extension HelperRestoreStatePersisting {
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
    private let keyboard: KeyboardRemapping

    private var sleepHolders: Set<Int> = []
    private var awdlHolders: Set<Int> = []
    private var sleepRestoreOwed = false
    private var awdlRestoreOwed = false
    private var fanRestoreOwed = false
    private var fanHolders: [Int: Int] = [:]
    private var priorityHolders: [Int: Int] = [:]
    private var keyboardHolders: Set<Int> = []
    private var lowPowerHolders: [LowPowerProfile: Set<Int>] = [:]
    private var lowPowerRestoreOwed: Set<LowPowerProfile> = []
    private let lowPower: BatteryLowPowerControlling
    private var fanFailureStreak = 0
    private var droppedFanClients: Set<Int> = []
    static let maxFanFailures = 5
    /// Set once ``fanTick()`` gave up on a hold, so the state is inspectable
    /// (and the app can tell "boost silently ended" from "still boosting").
    /// Read through ``fanHoldWasDropped()``: mutations happen under the lock,
    /// and XPC reads arrive on arbitrary queues.
    public private(set) var fanHoldDropped = false

    /// The calling connection's lost fan claim stays visible until that
    /// connection retries or disconnects. Another holder cannot clear it.
    /// A nil client preserves the aggregate inspection used by diagnostics.
    public func fanHoldWasDropped(client: Int? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return client.map { droppedFanClients.contains($0) } ?? fanHoldDropped
    }

    private let sleepDisabledReader: () -> Bool?

    public init(
        runner: HelperCommandRunning,
        state: HelperRestoreStatePersisting,
        fans: FanControlling = NullFanControl(),
        keyboard: KeyboardRemapping = HidutilKeyboardRemapper(),
        sleepDisabledReader: @escaping () -> Bool? = { nil },
        lowPower: BatteryLowPowerControlling = NullBatteryLowPowerControl()
    ) {
        self.runner = runner
        self.state = state
        self.fans = fans
        self.keyboard = keyboard
        self.sleepDisabledReader = sleepDisabledReader
        self.lowPower = lowPower
    }

    /// Real reader: `pmset -g` output through the same pure parser the app's
    /// closed-display toggle uses.
    public static func readSleepDisabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
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
    /// restore it now and clear the marker only when the restore actually
    /// landed. A failed restore keeps the marker so the next launch retries.
    /// Called once at daemon launch, before the listener accepts anyone.
    public func restoreAtLaunch() {
        let leftovers = state.markers()
        if leftovers.contains(.batteryLowPower) { _ = restoreLowPower(profile: .battery) }
        if leftovers.contains(.adapterLowPower) { _ = restoreLowPower(profile: .adapter) }
        if leftovers.contains(.sleepDisabled) {
            let ok = runner.run(
                "/usr/bin/pmset", ["-a", "disablesleep", recordedSleepRestoreValue()])
            if ok { state.set(.sleepDisabled, present: false) }
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
        if leftovers.contains(.keyboardLock) {
            if let original = Self.decodeKeyboardMapping(state.value(for: .keyboardLock)),
               keyboard.apply(original) {
                state.set(.keyboardLock, value: nil)
            }
        }
    }

    /// The manual closed-display toggle: a plain persistent set, deliberately
    /// not connection-scoped and not marked for restore (the global toggle is
    /// meant to outlive the app; that matches the old osascript semantics).
    /// An explicit set supersedes any pending restore debt for the same knob:
    /// the marker is re-based to the chosen value (so a later release
    /// restores the user's choice, not a stale prior) and the in-life retry
    /// flag is cleared.
    public func setSleepDisabled(_ disabled: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let ok = runner.run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
        if ok {
            if !sleepHolders.isEmpty || state.value(for: .sleepDisabled) != nil {
                state.set(.sleepDisabled, value: disabled ? "1" : "0")
            } else {
                state.set(.sleepDisabled, value: nil)
            }
            sleepRestoreOwed = false
        }
        return ok
    }

    /// Put the Mac to sleep right now. Not a hold: there is nothing to restore
    /// on disconnect, and the machine may be asleep before the caller hears
    /// the reply.
    public func sleepNow() -> Bool {
        runner.run("/usr/bin/pmset", ["sleepnow"])
    }

    /// Flush the DNS cache and bounce mDNSResponder. Not a hold: nothing to
    /// restore on disconnect. Both steps run even if the first fails, so a
    /// poisoned cache and a stuck resolver are both given a chance.
    public func flushDNS() -> Bool {
        let a = runner.run("/usr/bin/dscacheutil", ["-flushcache"])
        let b = runner.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        return a && b
    }

    /// Take or release `client`'s hold on the Keyboard Cleaner remap. Writes
    /// hidutil only on the union edge. The disable table is baked in, never
    /// supplied by the caller.
    public func setKeyboardLock(client: Int, holding: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyKeyboardUnion(client: client, holding: holding)
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
        if let oneShot, !Self.isValidOneShotStamp(oneShot) { return false }
        let hasDays = repeatDays != nil
        let hasTime = repeatTime != nil
        if hasDays != hasTime { return false }
        if let repeatDays, !Self.isValidRepeatDays(repeatDays) { return false }
        if let repeatTime, !Self.isValidRepeatTime(repeatTime) { return false }
        let wantsRepeat = hasDays && hasTime
        guard oneShot != nil || wantsRepeat else {
            return clearWakeSchedules()
        }
        _ = clearWakeSchedules()
        var ok = true
        if let oneShot {
            ok = scheduleOneShotWake(at: oneShot) && ok
        }
        if let repeatDays, let repeatTime {
            ok = scheduleRepeatingWake(days: repeatDays, time: repeatTime) && ok
        }
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

    static func isValidOneShotStamp(_ raw: String) -> Bool {
        let parts = raw.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let date = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        let time = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard date.count == 3, time.count == 3,
              date.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              time.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let month = Int(date[0]), (1...12).contains(month),
              let day = Int(date[1]), (1...31).contains(day),
              Int(date[2]) != nil,
              let hour = Int(time[0]), (0...23).contains(hour),
              let minute = Int(time[1]), (0...59).contains(minute),
              let second = Int(time[2]), (0...59).contains(second)
        else { return false }
        return true
    }

    static func isValidRepeatDays(_ raw: String) -> Bool {
        let upper = raw.uppercased()
        return !upper.isEmpty && upper.allSatisfy { "MTWRFSU".contains($0) }
    }

    static func isValidRepeatTime(_ raw: String) -> Bool {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute),
              let second = Int(parts[2]), (0...59).contains(second)
        else { return false }
        return true
    }

    /// Take or release `client`'s hold on `disablesleep`. Writes the system
    /// only when the union of holders becomes non-empty or empty.
    public func setSleepHold(client: Int, holding: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applySleepUnion(client: client, holding: holding)
    }

    public func setLowPowerHold(client: Int, holding: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyLowPowerUnion(client: client, holding: holding, profile: .battery)
    }

    public func setAdapterLowPowerHold(client: Int, holding: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyLowPowerUnion(client: client, holding: holding, profile: .adapter)
    }

    private func applyLowPowerUnion(client: Int, holding: Bool, profile: LowPowerProfile) -> Bool {
        let marker: HelperRestoreMarker = profile == .battery ? .batteryLowPower : .adapterLowPower
        if holding {
            if lowPowerHolders[profile, default: []].contains(client) { return true }
            if lowPowerHolders[profile, default: []].isEmpty {
                guard let current = lowPower.mode(for: profile), (0...2).contains(current) else { return false }
                if state.markers().contains(marker), current != 1 {
                    guard restoreLowPower(profile: profile) else { return false }
                }
                if state.value(for: marker) == nil {
                    guard !state.markers().contains(marker) else { return false }
                    state.set(marker, value: String(current))
                    guard state.value(for: marker) == String(current) else { return false }
                }
                guard let value = state.value(for: marker),
                      let prior = Int(value), (0...2).contains(prior),
                      lowPower.setMode(1, for: profile) else { return false }
            }
            lowPowerHolders[profile, default: []].insert(client)
            return true
        }
        let wasHolder = lowPowerHolders[profile]?.remove(client) != nil
        guard lowPowerHolders[profile]?.isEmpty ?? true else { return true }
        guard wasHolder || lowPowerRestoreOwed.contains(profile) else { return true }
        let ok = restoreLowPower(profile: profile)
        if ok { lowPowerRestoreOwed.remove(profile) } else { lowPowerRestoreOwed.insert(profile) }
        return ok
    }

    private func restoreLowPower(profile: LowPowerProfile) -> Bool {
        let marker: HelperRestoreMarker = profile == .battery ? .batteryLowPower : .adapterLowPower
        guard let value = state.value(for: marker) else { return !state.markers().contains(marker) }
        guard let prior = Int(value), (0...2).contains(prior) else { return false }
        guard let current = lowPower.mode(for: profile) else { return false }
        guard current != 1 || lowPower.setMode(prior, for: profile) else { return false }
        state.set(marker, value: nil)
        return !state.markers().contains(marker)
    }

    /// Take or release `client`'s hold on `awdl0 down`.
    public func setAWDLHold(client: Int, holding: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyAWDLUnion(client: client, holding: holding)
    }

    /// Take or release `client`'s forced-fan hold at `percent`. With several
    /// holders the hottest request wins (the max percent). Writes only when
    /// the effective target changes.
    public func setFanHold(client: Int, holding: Bool, percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyFanUnion {
            if holding {
                droppedFanClients.remove(client)
                fanHolders[client] = ClosedLidFanFloor.clampedPercent(percent)
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
        if holding, pid <= 1 { return false }
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
        _ = applySleepUnion(client: client, holding: false)
        _ = applyAWDLUnion(client: client, holding: false)
        _ = applyFanUnion { fanHolders.removeValue(forKey: client) }
        droppedFanClients.remove(client)
        _ = applyPriorityUnion { priorityHolders.removeValue(forKey: client) }
        _ = applyKeyboardUnion(client: client, holding: false)
        for profile in LowPowerProfile.allCases {
            _ = applyLowPowerUnion(client: client, holding: false, profile: profile)
        }
    }

    /// Re-down `awdl0` while any hold is live: macOS re-raises the interface
    /// after sleep/wake, Wi-Fi toggles, or any app requesting AWDL, so the old
    /// loop's every-few-seconds re-assert carries over. The daemon calls this
    /// from its timer; a no-op with no holders.
    public func awdlTick() {
        lock.lock()
        defer { lock.unlock() }
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
        guard let target = fanHolders.values.max() else { return }
        if writeFanTarget(target) {
            fanFailureStreak = 0
            return
        }
        fanFailureStreak += 1
        guard fanFailureStreak >= Self.maxFanFailures else { return }
        droppedFanClients.formUnion(fanHolders.keys)
        fanHolders.removeAll()
        fanFailureStreak = 0
        fanHoldDropped = true
        let ok = fans.restoreAuto()
        state.set(.fanForced, present: !ok)
        fanRestoreOwed = !ok
    }

    /// Whether nothing is held, so an idle daemon may exit (launchd relaunches
    /// it on demand).
    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sleepHolders.isEmpty && awdlHolders.isEmpty
            && fanHolders.isEmpty && priorityHolders.isEmpty
            && keyboardHolders.isEmpty && lowPowerHolders.values.allSatisfy(\.isEmpty)
    }


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
            return
        }
        try? fm.createDirectory(
            atPath: (linkPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: cliPath)
    }

    private func applySleepUnion(client: Int, holding: Bool) -> Bool {
        let before = !sleepHolders.isEmpty
        if holding { sleepHolders.insert(client) } else { sleepHolders.remove(client) }
        let after = !sleepHolders.isEmpty
        guard before != after || (!after && sleepRestoreOwed) else {
            return true
        }
        if after {
            let existingDebt = state.value(for: .sleepDisabled)
            let prior = existingDebt ?? ((sleepDisabledReader() ?? false) ? "1" : "0")
            state.set(.sleepDisabled, value: prior)
            guard state.value(for: .sleepDisabled) != nil else {
                sleepHolders.remove(client)
                return false
            }
            let ok = runner.run("/usr/bin/pmset", ["-a", "disablesleep", "1"])
            if !ok {
                sleepHolders.remove(client)
                if existingDebt == nil { state.set(.sleepDisabled, value: nil) }
            }
            return ok
        }
        let ok = runner.run("/usr/bin/pmset", ["-a", "disablesleep", recordedSleepRestoreValue()])
        if ok { state.set(.sleepDisabled, value: nil) }
        sleepRestoreOwed = !ok
        return ok
    }

    private func recordedSleepRestoreValue() -> String {
        state.value(for: .sleepDisabled) == "1" ? "1" : "0"
    }

    private func applyAWDLUnion(client: Int, holding: Bool) -> Bool {
        let before = !awdlHolders.isEmpty
        if holding { awdlHolders.insert(client) } else { awdlHolders.remove(client) }
        let after = !awdlHolders.isEmpty
        guard before != after || (!after && awdlRestoreOwed) else {
            return true
        }
        if after {
            state.set(.awdlDown, present: true)
            guard state.markers().contains(.awdlDown) else {
                awdlHolders.remove(client)
                return false
            }
            let ok = runner.run("/sbin/ifconfig", ["awdl0", "down"])
            return ok
        }
        let ok = runner.run("/sbin/ifconfig", ["awdl0", "up"])
        if ok { state.set(.awdlDown, present: false) }
        awdlRestoreOwed = !ok
        return ok
    }

    private func applyFanUnion(_ mutate: () -> Void) -> Bool {
        let before = fanHolders.values.max()
        mutate()
        let after = fanHolders.values.max()
        guard before != after || (after == nil && fanRestoreOwed) else {
            return true
        }
        if let target = after {
            fanFailureStreak = 0
            fanHoldDropped = false
            state.set(.fanForced, present: true)
            return writeFanTarget(target)
        }
        let ok = fans.restoreAuto()
        state.set(.fanForced, present: !ok)
        fanRestoreOwed = !ok
        return ok
    }

    static let priorityNice = -10

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

    private func applyKeyboardUnion(client: Int, holding: Bool) -> Bool {
        let before = !keyboardHolders.isEmpty
        if holding { keyboardHolders.insert(client) } else { keyboardHolders.remove(client) }
        let after = !keyboardHolders.isEmpty
        guard before != after else { return true }
        if after {
            guard let original = keyboard.currentMapping() else {
                keyboardHolders.remove(client)
                return false
            }
            let payload = Self.encodeKeyboardMapping(original)
            state.set(.keyboardLock, value: payload)
            guard state.value(for: .keyboardLock) != nil else {
                keyboardHolders.remove(client)
                return false
            }
            let ok = keyboard.apply(.disabledKeyboard)
            if !ok {
                keyboardHolders.remove(client)
                state.set(.keyboardLock, value: nil)
            }
            return ok
        }
        guard let original = Self.decodeKeyboardMapping(state.value(for: .keyboardLock)) else {
            keyboardHolders.insert(client)
            return false
        }
        let ok = keyboard.apply(original)
        if ok {
            state.set(.keyboardLock, value: nil)
        } else {
            keyboardHolders.insert(client)
        }
        return ok
    }

    static func encodeKeyboardMapping(_ mapping: KeyboardKeyMapping) -> String {
        guard let data = try? JSONEncoder().encode(mapping),
              let s = String(data: data, encoding: .utf8)
        else { return "{\"entries\":[]}" }
        return s
    }

    static func decodeKeyboardMapping(_ raw: String?) -> KeyboardKeyMapping? {
        guard let raw, let data = raw.data(using: .utf8),
              let mapping = try? JSONDecoder().decode(KeyboardKeyMapping.self, from: data)
        else { return nil }
        return mapping
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
