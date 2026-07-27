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
    /// Whether the flag file that keeps `disablesleep` on is present.
    func isFlagPresent() -> Bool
    /// Create the flag (telling a running helper to disable sleep).
    /// Returns false when it couldn't be written.
    func createFlag() -> Bool
    /// Delete the flag; the helper notices within a cycle and re-enables
    /// normal sleep (only if it was the one that disabled it).
    func removeFlag()
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
}

/// Real backend: the flag lives in Application Support, and the loop is
/// spawned as root via `osascript`'s "with administrator privileges" (the same
/// admin seam ``PMSetSleepControl`` and ``OsascriptAWDLWatchdog`` use),
/// backgrounded so the prompt returns as soon as the loop is running.
public final class OsascriptSleepWatchdog: SleepWatchdogLaunching {
    private let flagURL: URL

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
        FileManager.default.fileExists(atPath: flagURL.path)
    }

    public func createFlag() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: flagURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: flagURL)
            return true
        } catch {
            return false
        }
    }

    public func removeFlag() {
        try? FileManager.default.removeItem(at: flagURL)
    }

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

    /// The root helper, backgrounded so `do shell script` returns immediately.
    /// It lives as long as the app's pid does and follows the flag,
    /// **edge-triggered** unlike the AWDL loop: nothing else re-flips
    /// `disablesleep` behind our back, and re-asserting every cycle would fight
    /// the user's own manual toggle (``PMSetSleepControl`` writes the same
    /// setting directly). So it writes only on a flag transition, and on app
    /// death restores normal sleep only if it was the one that disabled it, so
    /// a crash or quit mid-session fails safe while a manually enabled global
    /// setting survives untouched.
    static func watchdogCommand(flagPath: String, appPID: Int32) -> String {
        // Single-quote the path so it stays one literal word to /bin/sh (the
        // command runs as root via `do shell script`). See
        // ``OsascriptAWDLWatchdog/shellSingleQuoted(_:)``.
        let flag = OsascriptAWDLWatchdog.shellSingleQuoted(flagPath)
        return "( SET=; while kill -0 \(appPID) 2>/dev/null; do "
            + "if [ -f \(flag) ]; then "
            + "if [ -z \"$SET\" ]; then /usr/bin/pmset -a disablesleep 1; SET=1; fi; "
            + "elif [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0; SET=; fi; "
            + "sleep 2; done; "
            + "rm -f \(flag); "
            + "if [ -n \"$SET\" ]; then /usr/bin/pmset -a disablesleep 0; fi ) </dev/null >/dev/null 2>&1 &"
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

    /// Set when an engage was cancelled or failed, so the prompt doesn't
    /// re-appear every tick; cleared when the current session ends.
    private var heldOff = false

    /// Whether the root helper was already spawned this app run. Once it's up,
    /// engaging and releasing is flag-file-only: no more prompts.
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

    /// Pre-authorize the helper without touching the sleep setting: spawn it
    /// (one prompt now, in whatever context the caller chose, typically the
    /// Preferences toggle) then immediately drop the flag. After this, the
    /// engage at the next session start is a prompt-free flag write. No-op
    /// (and no prompt) once already authorized.
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
    /// engage stays held off until the session ends.
    public func retryEngage() {
        heldOff = false
    }

    /// The once-a-second pulse. Engages while a session is active (one prompt
    /// on the first engage of an app run; a cancel holds off until the session
    /// ends) and releases when it stops.
    public func autoTick(brewing: Bool) async {
        guard onlyWhileBrewing else { return }
        if brewing {
            guard !isHolding, !isBusy, !heldOff else { return }
            switch await engage() {
            case .applied:
                break
            case .cancelled, .failed:
                heldOff = true
            }
        } else {
            heldOff = false
            if isHolding {
                await release()
            }
        }
    }

    /// Disable sleep via the helper. The first call of this app run spawns the
    /// root helper (one administrator prompt); later ones just recreate the
    /// flag, instantly and prompt-free.
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
        case .failed(let message):
            lastError = message
            await Task.detached { launcher.removeFlag() }.value
        }
        return result
    }

    /// Re-enable normal sleep: just delete the flag (no prompt); the helper
    /// notices within a cycle and flips `disablesleep` back off.
    private func release() async {
        let launcher = self.launcher
        await Task.detached { launcher.removeFlag() }.value
        isHolding = false
    }
}
