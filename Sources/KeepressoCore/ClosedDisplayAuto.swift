import Foundation
import Observation

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
    func isFlagPresent() -> Bool
    func createFlag() -> Bool
    func removeFlag()
    func startHelper(appPID: Int32) -> SleepSettingResult
    var engageFailureMessage: String { get }
}

extension SleepWatchdogLaunching {
    public var engageFailureMessage: String {
        L("Couldn't create the sleep watchdog flag file.")
    }
}

/// Real backend: the flag lives in Application Support, and the loop is
/// spawned as root via `osascript`'s "with administrator privileges" (the same
/// admin seam ``PMSetSleepControl`` and ``OsascriptAWDLWatchdog`` use),
/// backgrounded so the prompt returns as soon as the loop is running.
public final class OsascriptSleepWatchdog: SleepWatchdogLaunching {
    private let flagURL: URL
    private let ownerPID: Int32

    public init(
        flagURL: URL = OsascriptSleepWatchdog.defaultFlagURL,
        ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.flagURL = flagURL
        self.ownerPID = ownerPID
    }

    public static var defaultFlagURL: URL {
        AppSupportFlagFile.defaultURL(named: "sleep-watchdog.flag")
    }

    private var flag: AppSupportFlagFile { AppSupportFlagFile(url: flagURL) }

    public func isFlagPresent() -> Bool { flag.isPresent }

    public func createFlag() -> Bool { flag.create(owner: ownerPID) }

    public func removeFlag() { flag.remove() }

    public func startHelper(appPID: Int32) -> SleepSettingResult {
        let command = Self.watchdogCommand(flagPath: flagURL.path, appPID: appPID)
        let script = "do shell script \"\(OsascriptAWDLWatchdog.appleScriptEscaped(command))\" with administrator privileges"
        guard let result = runForResult("/usr/bin/osascript", ["-e", script]) else {
            return .failed(L("Couldn't run the sleep watchdog command."))
        }
        if result.status == 0 { return .applied }
        // osascript reports a user-cancelled auth prompt as error -128.
        if result.stderr.contains("-128") || result.stderr.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? L("The sleep watchdog couldn't be started.") : message)
    }

    static func watchdogCommand(flagPath: String, appPID: Int32) -> String {
        let flag = OsascriptAWDLWatchdog.shellSingleQuoted(flagPath)
        return "( SET=; while kill -0 \(appPID) 2>/dev/null; do "
            + "if [ -f \(flag) ]; then "
            + "if [ -z \"$SET\" ]; then /usr/bin/pmset -a disablesleep 1; SET=1; fi; "
            + "elif [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0; SET=; fi; "
            + "sleep 2; done; "
            + OsascriptAWDLWatchdog.removeOwnedFlagClause(flag: flag, appPID: appPID)
            + "if [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0; fi ) </dev/null >/dev/null 2>&1 &"
    }

    private func runForResult(_ path: String, _ arguments: [String]) -> (status: Int32, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
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

/// Decides when the "only while brewing" automation has to clear a
/// closed-display hold it doesn't own.
///
/// While the feature is on it is authoritative: the sleep setting follows the
/// session, whatever anyone else did to it. A hold taken outside the
/// automation (the manual toggle, `pmset` by hand, another tool) would
/// otherwise sit there forever, because a release only ever gives back what
/// the automation itself took. Idle-only on purpose: during a session a
/// foreign hold is doing the same job the automation wants done, and clearing
/// it there could drop the Mac's clamshell protection mid-brew. The next idle
/// tick clears it instead.
///
/// `canApply` is the host's answer to "is there a way to write the setting
/// right now": silent through the helper daemon, or a password prompt the host
/// is willing to show (announced, and at most once per app run).
public enum ClosedDisplayAuthority {
    public static func shouldClearForeignHold(
        onlyWhileBrewing: Bool,
        brewing: Bool,
        automationHolding: Bool,
        settingIsOn: Bool,
        canApply: Bool
    ) -> Bool {
        guard onlyWhileBrewing, settingIsOn, canApply else { return false }
        return !brewing && !automationHolding
    }
}

/// Decides when a battery safety pause should lift (and later restore) sticky
/// closed-display mode.
///
/// Pause-on-low-battery only stops the keep-awake session. Sticky
/// `pmset disablesleep` outlives that stop, so a lid-closed Mac can keep
/// running and drain past the cutoff. "Only while brewing" already releases
/// with the session, so this path covers the sticky case alone. Mirrors the
/// thermal emergency's closed-display lift in the app host.
public enum BatteryPauseClosedDisplay {
    public enum Decision: Equatable, Sendable {
        case idle
        case lift
        case skipLiftNeedsHelper
        case restore
    }

    public static func decide(
        paused: Bool,
        onlyWhileBrewing: Bool,
        settingIsOn: Bool,
        alreadyLifted: Bool,
        helperInstalled: Bool
    ) -> Decision {
        guard !onlyWhileBrewing else { return .idle }
        if paused {
            guard settingIsOn else { return .idle }
            if helperInstalled { return .lift }
            return alreadyLifted ? .idle : .skipLiftNeedsHelper
        }
        return alreadyLifted ? .restore : .idle
    }
}

/// What the quit modal should cover, decided from live state. Pure so the
/// matrix is unit-testable; the host gathers the inputs.
///
/// `overrideLive` means the sleep override is on *and* quitting would orphan
/// it: a persistent latch, whichever run set it. A scoped hold never counts,
/// because both backends self-clean when the app dies (the fallback loop
/// restores on exit, the daemon releases on teardown), so there is no
/// orphaned decision to ask about. The host reads that distinction from
/// ``ClosedDisplayAutoController/isHolding``, not from who flipped the
/// switch: a setting left on days ago is precisely what gets forgotten.
public enum QuitSleepCheck {
    public enum Coverage: Equatable, Sendable {
        case none
        case session
        case overrideLive
        case sessionAndOverride
    }

    public static func coverage(brewing: Bool, overrideLive: Bool) -> Coverage {
        switch (brewing, overrideLive) {
        case (true, true): return .sessionAndOverride
        case (true, false): return .session
        case (false, true): return .overrideLive
        case (false, false): return .none
        }
    }
}

/// Drives closed-display mode's "only while brewing" automation: the global
/// `disablesleep` setting follows the keep-awake session, on when it starts
/// and off when it ends, instead of staying on until manually turned off.
///
/// Owns no timer: the host's ticker calls ``autoTick(brewing:)`` once a
/// second with the session's live state. All flips go through the root helper
/// (see ``SleepWatchdogLaunching``), never through the per-flip admin prompt
/// of ``SleepSettingControlling``, so after the one authorization the
/// automation is prompt-free. `@MainActor` like the other controllers; the
/// blocking admin prompt and file touches run on detached tasks.
@MainActor
@Observable
public final class ClosedDisplayAutoController {
    /// Whether the helper is currently holding sleep disabled (the flag file
    /// is present).
    public private(set) var isHolding = false

    /// Message from the last failed attempt; `nil` after a success or a user
    /// cancellation (cancelling is not an error to nag about).
    public private(set) var lastError: String?

    /// True while the admin prompt is on screen, so the UI can show progress
    /// and a second toggle can't stack another prompt.
    public private(set) var isBusy = false

    /// When on, `disablesleep` follows the session. The host persists this
    /// and mirrors it in.
    public var onlyWhileBrewing = false

    private enum HoldOff {
        case none
        case failure
        case user
    }
    private var holdOff: HoldOff = .none

    private var helperStarted = false

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
    public var isAuthorized: Bool { helperStarted }

    /// Remove any stale flag left by a previous run (a hard kill or a reboot
    /// mid-watchdog). Called once at app launch: any loop from a previous
    /// process has already exited via its pid check, so a surviving flag is
    /// stale by definition.
    public func cleanupAtLaunch() async {
        let launcher = self.launcher
        await Task.detached { launcher.removeFlag() }.value
    }

    @discardableResult
    public func prime() async -> SleepSettingResult {
        guard !helperStarted, !isBusy else { return .applied }
        let result = await engage()
        if case .applied = result { await release() }
        return result
    }

    /// Stop holding if we are, restoring normal sleep. For when the feature is
    /// switched off mid-session.
    public func stopIfHolding() async {
        if isHolding { await release() }
    }

    /// Let the next tick try engaging again. For after an external fix (the
    /// helper daemon's registration was repaired); without this a failed
    /// engage stays held off until the session ends. A cancelled prompt is
    /// left alone: recovering the helper is not permission to ask again.
    public func retryEngage() {
        if holdOff == .failure { holdOff = .none }
    }

    /// The once-a-second pulse. Engages while a session is active (one prompt
    /// on the first engage of an app run; a cancel holds off until the session
    /// ends) and releases when it stops.
    public func autoTick(brewing: Bool) async {
        guard onlyWhileBrewing else { return }
        if brewing {
            if isHolding, !isBusy, !launcher.isFlagPresent() { isHolding = false }
            guard !isHolding, !isBusy, holdOff == .none else { return }
            switch await engage() {
            case .applied:
                break
            case .cancelled:
                holdOff = .user
            case .failed:
                holdOff = .failure
            }
        } else {
            holdOff = .none
            if isHolding {
                await release()
            }
        }
    }

    @discardableResult
    private func engage() async -> SleepSettingResult {
        guard !isBusy else { return .cancelled }
        isBusy = true
        defer { isBusy = false }
        let launcher = self.launcher
        let flagCreated = await Task.detached { launcher.createFlag() }.value
        guard flagCreated else {
            let message = launcher.engageFailureMessage
            lastError = message
            return .failed(message)
        }
        if helperStarted {
            lastError = nil
            isHolding = true
            return .applied
        }
        let pid = self.appPID
        let result = await Task.detached { launcher.startHelper(appPID: pid) }.value
        switch result {
        case .applied:
            lastError = nil
            isHolding = true
            helperStarted = true
        case .cancelled:
            lastError = nil
            await Task.detached { launcher.removeFlag() }.value
            isHolding = launcher.isFlagPresent()
        case .failed(let message):
            lastError = message
            await Task.detached { launcher.removeFlag() }.value
            isHolding = launcher.isFlagPresent()
        }
        return result
    }

    private func release() async {
        let launcher = self.launcher
        await Task.detached { launcher.removeFlag() }.value
        isHolding = launcher.isFlagPresent()
    }
}
