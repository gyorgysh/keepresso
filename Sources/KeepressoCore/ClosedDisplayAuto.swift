import Foundation
import Observation

/// Exact state of one connection-scoped sleep transaction.
public enum SleepHoldMode: Int, Codable, Sendable, Equatable {
    case released = 0
    case active = 1
    case thermallySuspended = 2
}

/// System-touching seam for the closed-display auto helper: a root loop that
/// lives as long as the app does and holds the global `pmset disablesleep`
/// setting on whenever a user-owned flag file exists.
///
/// Same privilege design as ``AWDLWatchdogLaunching``: the first activation
/// spawns the helper (ONE administrator prompt per app run); after that,
/// following the session on and off is just creating and deleting the flag
/// file, no prompts. The helper watches the app's pid, so an app crash or
/// quit restores normal sleep on its own; the manual
/// ``SleepSettingControlling`` path deliberately has no such teardown (the
/// global toggle is meant to outlive the app).
public protocol SleepWatchdogLaunching: AnyObject, Sendable {
    /// Whether the flag file that keeps `disablesleep` on is present.
    func isFlagPresent() -> Bool
    /// Create the flag (telling a running helper to disable sleep).
    /// Returns false when it couldn't be written.
    func createFlag() -> Bool
    /// Delete the flag; the helper notices within a cycle and re-enables
    /// normal sleep (only if it was the one that disabled it).
    func removeFlag()
    /// Apply and confirm an exact transaction state. Thermal suspension keeps
    /// the original sleep-setting snapshot but temporarily forces sleep back
    /// on, so recovery never has to guess whether the original value was
    /// manual, automatic, or both.
    func setMode(_ mode: SleepHoldMode) -> Bool
    /// Spawn the root helper loop. Blocking: it waits for the user to answer
    /// the administrator prompt. Called once per app run, on first activation.
    func startHelper(appPID: Int32) -> SleepSettingResult
    /// Message to surface when ``createFlag()`` fails, naming what actually
    /// failed in this backend (a file write here, an XPC call in the daemon).
    var engageFailureMessage: String { get }
}

extension SleepWatchdogLaunching {
    public var engageFailureMessage: String {
        L("Couldn't create the sleep watchdog flag file.")
    }

    public func setMode(_ mode: SleepHoldMode) -> Bool {
        switch mode {
        case .released:
            removeFlag()
            return true
        case .active:
            return createFlag()
        case .thermallySuspended:
            return false
        }
    }
}

/// Real backend: the flag lives in Application Support, and the loop is
/// spawned as root via `osascript`'s "with administrator privileges" (the same
/// admin seam ``PMSetSleepControl`` and ``OsascriptAWDLWatchdog`` use),
/// backgrounded so the prompt returns as soon as the loop is running.
public final class OsascriptSleepWatchdog: SleepWatchdogLaunching, @unchecked Sendable {
    private let flagURL: URL
    private let stateLock = NSLock()
    private var helperStarted = false
    private var helperPID: Int32?

    public init(flagURL: URL = OsascriptSleepWatchdog.defaultFlagURL) {
        self.flagURL = flagURL
    }

    public static var defaultFlagURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Keepresso/sleep-watchdog.flag", isDirectory: false)
    }

    public func isFlagPresent() -> Bool {
        guard let text = try? String(contentsOf: flagURL, encoding: .utf8) else { return false }
        return text.contains(" active") || text.contains(" thermallySuspended")
    }

    public func createFlag() -> Bool {
        setMode(.active)
    }

    public func removeFlag() {
        _ = setMode(.released)
    }

    public func setMode(_ mode: SleepHoldMode) -> Bool {
        stateLock.lock()
        let started = helperStarted
        let pid = helperPID
        stateLock.unlock()

        let fm = FileManager.default
        if mode == .released, !started {
            try? fm.removeItem(at: flagURL)
            return true
        }
        guard started, let pid else { return false }
        let ackURL = URL(fileURLWithPath: Self.ackPath(appPID: pid))

        let generation = UUID().uuidString.lowercased()
        let modeName: String
        switch mode {
        case .released: modeName = "released"
        case .active: modeName = "active"
        case .thermallySuspended: modeName = "thermallySuspended"
        }
        do {
            try fm.createDirectory(
                at: flagURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("\(generation) \(modeName)\n".utf8).write(to: flagURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: flagURL.path)
        } catch {
            return false
        }

        let expected = "\(generation) \(modeName)"
        for _ in 0..<80 {
            if let ack = try? String(contentsOf: ackURL, encoding: .utf8),
               Self.acknowledgementMatches(ack, expected: expected) {
                if mode == .released {
                    try? fm.removeItem(at: flagURL)
                }
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    static func acknowledgementMatches(_ text: String, expected: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }

    public func startHelper(appPID: Int32) -> SleepSettingResult {
        stateLock.lock()
        let alreadyStarted = helperStarted
        stateLock.unlock()
        if alreadyStarted { return .applied }
        let command = Self.watchdogCommand(
            flagPath: flagURL.path,
            ackPath: Self.ackPath(appPID: appPID),
            appPID: appPID
        )
        let script = "do shell script \"\(OsascriptAWDLWatchdog.appleScriptEscaped(command))\" with administrator privileges"
        guard let result = runForResult("/usr/bin/osascript", ["-e", script]) else {
            return .failed(L("Couldn't run the sleep watchdog command."))
        }
        if result.status == 0 {
            stateLock.lock()
            helperStarted = true
            helperPID = appPID
            stateLock.unlock()
            return .applied
        }
        // osascript reports a user-cancelled auth prompt as error -128.
        if result.stderr.contains("-128") || result.stderr.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? L("The sleep watchdog couldn't be started.") : message)
    }

    /// The root helper follows a generation-tagged control file and writes an
    /// acknowledgement only after `pmset` and its readback agree. It retains
    /// the original value throughout active and thermally suspended modes. If
    /// restore fails after the app exits, the loop keeps retrying instead of
    /// abandoning the recovery debt.
    static func ackPath(appPID: Int32) -> String {
        "/var/run/sh.gyorgy.keepresso.sleep-\(appPID).ack"
    }

    /// Quote an arbitrary path as one POSIX shell word. The fallback command
    /// runs as root, so even a path supplied by a test or future caller must
    /// never be able to introduce shell syntax.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func watchdogCommand(
        flagPath: String,
        ackPath: String? = nil,
        appPID: Int32
    ) -> String {
        let quotedFlagPath = Self.shellQuoted(flagPath)
        let quotedAckPath = Self.shellQuoted(ackPath ?? Self.ackPath(appPID: appPID))
        let readSetting = "OBS=; OUT=$(/usr/bin/pmset -g 2>/dev/null) && OBS=$(printf '%s\\n' \"$OUT\" | /usr/bin/awk 'tolower($1) == \"sleepdisabled\" || tolower($1) == \"disablesleep\" { print $2; found=1; exit } END { if (!found) exit 1 }')"
        return "( SET=; ORIG=; APPLIED=released; while :; do "
            + "if kill -0 \(appPID) 2>/dev/null; then ALIVE=1; else ALIVE=; fi; "
            + "GEN=; WANT=released; "
            + "if [ -n \"$ALIVE\" ] && [ -f \(quotedFlagPath) ]; then IFS=' ' read -r GEN WANT < \(quotedFlagPath); fi; "
            + "case \"$WANT\" in active|thermallySuspended|released) ;; *) GEN=; WANT=released ;; esac; "
            + "if [ \"$WANT\" != released ] && [ -z \"$SET\" ]; then \(readSetting); case \"$OBS\" in 0|1) ORIG=$OBS; SET=1 ;; *) ORIG= ;; esac; fi; "
            + "if [ \"$WANT\" = active ]; then TARGET=1; elif [ \"$WANT\" = thermallySuspended ]; then TARGET=0; else TARGET=$ORIG; fi; "
            + "if [ \"$WANT\" = released ]; then "
            + "if [ -n \"$SET\" ]; then if /usr/bin/pmset -a disablesleep \"$TARGET\" && \(readSetting) && [ \"$OBS\" = \"$TARGET\" ]; then SET=; ORIG=; APPLIED=released; fi; else APPLIED=released; fi; "
            + "elif [ -n \"$SET\" ]; then "
            + "if \(readSetting) && [ \"$OBS\" = \"$TARGET\" ]; then APPLIED=$WANT; "
            + "elif /usr/bin/pmset -a disablesleep \"$TARGET\" && \(readSetting) && [ \"$OBS\" = \"$TARGET\" ]; then APPLIED=$WANT; else APPLIED=; fi; fi; "
            + "if [ -n \"$GEN\" ] && [ \"$APPLIED\" = \"$WANT\" ]; then printf '%s %s\\n' \"$GEN\" \"$WANT\" > \(quotedAckPath) && chmod 644 \(quotedAckPath); fi; "
            + "if [ -z \"$ALIVE\" ] && [ -z \"$SET\" ]; then break; fi; sleep 2; done; "
            + "rm -f \(quotedFlagPath) \(quotedAckPath) ) </dev/null >/dev/null 2>&1 &"
    }

    /// Run a command and return its exit status plus stderr, or `nil` if it
    /// couldn't be launched. Mirrors ``PMSetSleepControl``'s helper.
    private func runForResult(_ path: String, _ arguments: [String]) -> (status: Int32, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }
}

/// Resolves the status exposed to Agent clients. A helper registration is a
/// sufficient capability signal while idle, but active unattended work must
/// confirm that its scoped sleep hold was accepted.
public enum ClosedLidProtectionReadiness {
    public static func resolve(
        hasUnattendedDemand: Bool,
        helperReady: Bool,
        automaticHoldActive: Bool,
        manualProtectionActive: Bool = false
    ) -> Bool {
        hasUnattendedDemand
            ? automaticHoldActive
            : (helperReady || manualProtectionActive)
    }
}

/// Drives closed-display mode's "only while brewing" automation: the global
/// `disablesleep` setting follows the keep-awake session, on when it starts
/// and off when it ends, instead of staying on until manually turned off.
///
/// Owns no timer: the host's ticker calls
/// ``autoTick(brewing:sleepAlreadyDisabled:)`` once a second with the
/// session's live state. All flips go through the root helper
/// (see ``SleepWatchdogLaunching``), never through the per-flip admin prompt
/// of ``SleepSettingControlling``, so after the one authorization the
/// automation is prompt-free. `@MainActor` like the other controllers; the
/// blocking admin prompt and file touches run on detached tasks.
@MainActor
@Observable
public final class ClosedDisplayAutoController {
    /// Last state confirmed by the selected backend. Suspended remains a
    /// scoped transaction, but it is intentionally not reported as holding
    /// the Mac awake.
    public private(set) var confirmedMode: SleepHoldMode = .released
    public var isHolding: Bool { confirmedMode == .active }
    /// Fail-closed readiness for unattended callers. A cached active mode is
    /// not sufficient while a safety transition, stale backend call, or
    /// compensating reconcile is still in flight.
    public var hasConfirmedAutomaticProtection: Bool {
        confirmedMode == .active
            && desiredMode == .active
            && !isSafetySuspended
            && !backendStateNeedsReconcile
            && reconcileTask == nil
    }
    /// True only when current automatic demand deliberately relies on a live
    /// manual global setting instead of a scoped transaction.
    public private(set) var isUsingManualProtection = false
    public var hasScopedTransaction: Bool {
        confirmedMode != .released
            || desiredMode != .released
            || backendStateNeedsReconcile
    }

    /// Message from the last failed attempt; `nil` after a success or a user
    /// cancellation (cancelling is not an error to nag about).
    public private(set) var lastError: String?

    /// True while the admin prompt is on screen, so the UI can show progress
    /// and a second toggle can't stack another prompt.
    public private(set) var isBusy = false

    /// When on, `disablesleep` follows the session. The host persists this
    /// and mirrors it in.
    public var onlyWhileBrewing = false

    /// Set when initial authorization was cancelled, so the prompt does not
    /// reappear every tick. A new demand edge clears it.
    private var heldOff = false

    /// Hard gate used while thermal protection has paused work. It is
    /// separate from the session state because asynchronous release and
    /// restore operations can overlap a session transition.
    public private(set) var isThermallySuspended = false
    /// Battery safety uses the same exact-snapshot suspended backend state.
    /// It stays latched until the backend confirms recovery, so the session
    /// cannot resume while `disablesleep` is still in the safety state.
    public private(set) var isBatterySuspended = false
    public var isSafetySuspended: Bool {
        isThermallySuspended || isBatterySuspended
    }

    private var isAuthorizedForThisRun = false
    private var automaticDemand = false
    private var sleepAlreadyDisabled: Bool?
    private var desiredMode: SleepHoldMode = .released
    /// True when a backend call may have landed after its revision became
    /// stale, or returned an ambiguous failure. Cached confirmedMode cannot
    /// close the transaction until the latest desired mode is written again.
    private var backendStateNeedsReconcile = false
    private var revision = 0
    private var thermalResumePending = false
    private var batteryResumePending = false
    private var thermalGateClosed = false
    private var batteryGateClosed = false
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?

    private let launcher: SleepWatchdogLaunching
    private let appPID: Int32

    public init(
        launcher: SleepWatchdogLaunching = OsascriptSleepWatchdog(),
        appPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.launcher = launcher
        self.appPID = appPID
    }

    /// Whether the root helper is already authorized and running this app run,
    /// so engaging needs no further password prompt.
    public var isAuthorized: Bool { isAuthorizedForThisRun }

    /// Remove any stale flag left by a previous run (a hard kill or a reboot
    /// mid-watchdog). Called once at app launch: any loop from a previous
    /// process has already exited via its pid check, so a surviving flag is
    /// stale by definition.
    public func cleanupAtLaunch() async {
        automaticDemand = false
        isUsingManualProtection = false
        thermalGateClosed = false
        batteryGateClosed = false
        thermalResumePending = false
        batteryResumePending = false
        // Invalidate any operation already in flight, even when released was
        // also its desired mode. The reconcile loop then serializes cleanup
        // with a concurrent launch session or safety transition.
        revision &+= 1
        desiredMode = .released
        backendStateNeedsReconcile = true
        scheduleReconcile()
        await waitForReconcile()
    }

    /// Pre-authorize the helper without touching the sleep setting: spawn it
    /// (one prompt now, in whatever context the caller chose, typically the
    /// Preferences toggle) then immediately drop the flag. After this, the
    /// engage at the next session start is a prompt-free flag write. No-op
    /// (and no prompt) once already authorized.
    @discardableResult
    public func prime() async -> SleepSettingResult {
        guard !isAuthorizedForThisRun, !isBusy else { return .applied }
        isBusy = true
        defer { isBusy = false }
        let launcher = self.launcher
        let pid = appPID
        let result = await Task.detached { launcher.startHelper(appPID: pid) }.value
        if case .applied = result {
            isAuthorizedForThisRun = true
        }
        return result
    }

    /// Stop holding if we are, restoring normal sleep. For when the feature is
    /// switched off mid-session.
    public func stopIfHolding() async {
        automaticDemand = false
        isUsingManualProtection = false
        thermalGateClosed = false
        batteryGateClosed = false
        thermalResumePending = false
        batteryResumePending = false
        heldOff = false
        setDesiredMode(.released)
        finishSafetyRecoveryIfConfirmed()
        scheduleReconcile()
        await waitForReconcile()
    }

    /// Let the next tick try engaging again. For after an external fix (the
    /// helper daemon's registration was repaired); without this a failed
    /// engage stays held off until the session ends.
    public func retryEngage() {
        heldOff = false
        scheduleReconcile()
    }

    /// Synchronously close the thermal gate before any asynchronous backend
    /// work starts. An in-flight active transition may still return, but its
    /// stale revision is never published and the reconcile loop immediately
    /// converges to suspended.
    public func requestThermalSuspend() {
        thermalResumePending = false
        guard !thermalGateClosed else { return }
        isThermallySuspended = true
        thermalGateClosed = true
        setDesiredMode(.thermallySuspended)
        scheduleReconcile()
    }

    /// Cooling asks for recovery but keeps the gate closed until the next
    /// post-session-reconcile demand update. That update can move directly
    /// from suspended to active or released without a release-and-reacquire
    /// window.
    public func requestThermalResume() {
        guard isThermallySuspended else { return }
        thermalResumePending = true
    }

    /// Low battery has the same priority as thermal safety. Multiple safety
    /// reasons compose: recovery cannot leave suspended mode until every gate
    /// has cleared.
    public func requestBatterySuspend() {
        batteryResumePending = false
        guard !batteryGateClosed else { return }
        isBatterySuspended = true
        batteryGateClosed = true
        setDesiredMode(.thermallySuspended)
        scheduleReconcile()
    }

    public func requestBatteryResume() {
        guard isBatterySuspended else { return }
        batteryResumePending = true
    }

    /// Feed the latest post-reconcile demand without creating one task per
    /// ticker pulse. At most one backend reconcile task exists at a time.
    public func updateAutomaticDemand(
        brewing: Bool,
        sleepAlreadyDisabled: Bool? = false
    ) {
        let demandEdge = automaticDemand != brewing
        automaticDemand = brewing
        self.sleepAlreadyDisabled = sleepAlreadyDisabled
        if !brewing || demandEdge { heldOff = false }
        if thermalResumePending {
            thermalResumePending = false
            thermalGateClosed = false
            heldOff = false
        }
        if batteryResumePending {
            batteryResumePending = false
            batteryGateClosed = false
            heldOff = false
        }
        recomputeDesiredMode()
        finishSafetyRecoveryIfConfirmed()
        scheduleReconcile()
    }

    /// Async compatibility surface for tests and explicit callers.
    public func autoTick(
        brewing: Bool,
        sleepAlreadyDisabled: Bool? = false
    ) async {
        updateAutomaticDemand(
            brewing: brewing,
            sleepAlreadyDisabled: sleepAlreadyDisabled
        )
        await waitForReconcile()
    }

    private func recomputeDesiredMode() {
        if thermalGateClosed || batteryGateClosed {
            isUsingManualProtection = false
            setDesiredMode(.thermallySuspended)
            return
        }
        guard onlyWhileBrewing, automaticDemand else {
            isUsingManualProtection = false
            setDesiredMode(.released)
            return
        }
        // Automatic demand always owns a scoped transaction, even if a manual
        // global setting is already on. The helper snapshots that manual value
        // as the restore baseline, so changing it mid-task cannot create a
        // manual-to-automatic handoff gap.
        isUsingManualProtection = false
        setDesiredMode(.active)
    }

    private func setDesiredMode(_ mode: SleepHoldMode) {
        guard desiredMode != mode else { return }
        desiredMode = mode
        revision &+= 1
    }

    private func scheduleReconcile() {
        guard reconcileTask == nil,
              (confirmedMode != desiredMode || backendStateNeedsReconcile),
              !(heldOff && desiredMode == .active)
        else { return }
        reconcileTask = Task { [weak self] in
            await self?.runReconcileLoop()
        }
    }

    private func runReconcileLoop() async {
        defer {
            reconcileTask = nil
            finishSafetyRecoveryIfConfirmed()
        }
        while confirmedMode != desiredMode || backendStateNeedsReconcile {
            let target = desiredMode
            let targetRevision = revision
            let launcher = self.launcher
            let pid = appPID
            isBusy = true

            if target != .released {
                let start = await Task.detached {
                    launcher.startHelper(appPID: pid)
                }.value
                guard targetRevision == revision else {
                    isBusy = false
                    continue
                }
                switch start {
                case .applied:
                    isAuthorizedForThisRun = true
                case .cancelled:
                    lastError = nil
                    if target == .active { heldOff = true }
                    isBusy = false
                    return
                case .failed(let message):
                    lastError = message
                    if target == .active { heldOff = true }
                    isBusy = false
                    return
                }
            }

            let applied = await Task.detached {
                launcher.setMode(target)
            }.value
            isBusy = false
            guard targetRevision == revision else {
                // The call crossed an intent change. Even a false result can
                // be ambiguous after a timeout, so force the newest target to
                // the same pinned backend before trusting cached state.
                backendStateNeedsReconcile = true
                continue
            }
            guard applied else {
                backendStateNeedsReconcile = true
                lastError = launcher.engageFailureMessage
                return
            }
            confirmedMode = target
            backendStateNeedsReconcile = false
            finishSafetyRecoveryIfConfirmed()
            lastError = nil
        }
    }

    private func finishSafetyRecoveryIfConfirmed() {
        guard !thermalGateClosed,
              !batteryGateClosed,
              confirmedMode == desiredMode,
              !backendStateNeedsReconcile,
              reconcileTask == nil
        else { return }
        isThermallySuspended = false
        isBatterySuspended = false
    }

    private func waitForReconcile() async {
        while let task = reconcileTask {
            await task.value
        }
    }
}
