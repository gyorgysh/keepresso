import Foundation
import Observation

/// Reads whether the `awdl0` interface (Apple Wireless Direct Link: AirDrop,
/// Handoff, Sidecar, Continuity) is currently up. AWDL periodically hops the
/// Wi-Fi radio off-channel, which is the once-a-second latency spike the
/// jitter test looks for. Mirrors the other read-only seams.
public protocol AWDLStateReading: AnyObject, Sendable {
    /// Whether `awdl0` is up. `nil` when it couldn't be read (no such
    /// interface, `ifconfig` failed).
    func isUp() -> Bool?
}

/// Real backend over `ifconfig awdl0`.
public final class IfconfigAWDLReader: AWDLStateReading {
    public init() {}

    public func isUp() -> Bool? {
        Self.parseIsUp(from: run("/sbin/ifconfig", ["awdl0"]))
    }

    /// Pure parse of `ifconfig awdl0` output: the first line carries the flag
    /// list, e.g. `awdl0: flags=8863<UP,BROADCAST,SMART,RUNNING,...> mtu 1500`.
    public static func parseIsUp(from output: String?) -> Bool? {
        guard let output,
              let first = output.split(whereSeparator: \.isNewline).first,
              let open = first.firstIndex(of: "<"),
              let close = first.firstIndex(of: ">"),
              open < close
        else { return nil }
        return first[first.index(after: open)..<close]
            .split(separator: ",")
            .contains("UP")
    }

    private func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(decoding: data, as: UTF8.self)
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}

/// Outcome of trying to start the watchdog (mirrors ``SleepSettingResult``).
public enum AWDLWatchdogStartResult: Equatable, Sendable {
    case started
    /// The user dismissed the administrator-password prompt.
    case cancelled
    case failed(String)
}

/// System-touching seam for the watchdog helper: a root loop that lives as
/// long as the app does and holds `awdl0` down whenever a user-owned flag
/// file exists.
///
/// The privilege design keeps macOS happy without a permanent daemon, and
/// asks for the password exactly once per app run: the first activation
/// spawns the helper (ONE administrator prompt); after that, toggling on and
/// off is just creating and deleting the flag file, no prompts. The helper
/// watches the app's pid, so an app crash or quit tears it down and restores
/// `awdl0` on its own.
public protocol AWDLWatchdogLaunching: AnyObject, Sendable {
    /// Whether the flag file that keeps `awdl0` down is present.
    func isFlagPresent() -> Bool
    /// Create the flag (telling a running helper to hold `awdl0` down).
    /// Returns false when it couldn't be written.
    func createFlag() -> Bool
    /// Delete the flag; the helper notices within a cycle, restores
    /// `awdl0 up`, and goes back to idling.
    func removeFlag()
    /// Spawn the root helper loop. Blocking: it waits for the user to answer
    /// the administrator prompt. Called once per app run, on first activation.
    func startHelper(appPID: Int32) -> AWDLWatchdogStartResult
}

/// Real backend: the flag lives in Application Support, and the loop is
/// spawned as root via `osascript`'s "with administrator privileges" (the same
/// admin seam ``PMSetSleepControl`` uses), backgrounded so the prompt returns
/// as soon as the loop is running.
public final class OsascriptAWDLWatchdog: AWDLWatchdogLaunching {
    private let flagURL: URL

    public init(flagURL: URL = OsascriptAWDLWatchdog.defaultFlagURL) {
        self.flagURL = flagURL
    }

    public static var defaultFlagURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Keepresso/awdl-watchdog.flag", isDirectory: false)
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

    public func startHelper(appPID: Int32) -> AWDLWatchdogStartResult {
        let command = Self.watchdogCommand(flagPath: flagURL.path, appPID: appPID)
        let script = "do shell script \"\(Self.appleScriptEscaped(command))\" with administrator privileges"
        guard let result = runForResult("/usr/bin/osascript", ["-e", script]) else {
            return .failed("Couldn't run the watchdog command.")
        }
        if result.status == 0 { return .started }
        // osascript reports a user-cancelled auth prompt as error -128.
        if result.stderr.contains("-128") || result.stderr.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "The watchdog couldn't be started." : message)
    }

    /// The root helper, backgrounded so `do shell script` returns immediately.
    /// It lives as long as the app's pid does and follows the flag: while the
    /// flag exists it forces `awdl0` down every cycle (macOS re-raises the
    /// interface after sleep/wake, Wi-Fi toggles, or any app requesting AWDL),
    /// and on the flag disappearing it restores `awdl0 up` once and idles, so
    /// re-enabling needs no new prompt. On app death it restores the interface
    /// (only if it was the one holding it down) and removes any leftover flag,
    /// so a crash fails safe.
    static func watchdogCommand(flagPath: String, appPID: Int32) -> String {
        "( DOWNED=; while kill -0 \(appPID) 2>/dev/null; do "
            + "if [ -f \"\(flagPath)\" ]; then /sbin/ifconfig awdl0 down; DOWNED=1; "
            + "elif [ -n \"$DOWNED\" ]; then /sbin/ifconfig awdl0 up; DOWNED=; fi; "
            + "sleep 3; done; "
            + "rm -f \"\(flagPath)\"; "
            + "if [ -n \"$DOWNED\" ]; then /sbin/ifconfig awdl0 up; fi ) </dev/null >/dev/null 2>&1 &"
    }

    /// Escape a shell command for embedding in an AppleScript string literal.
    static func appleScriptEscaped(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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

/// Drives the AWDL watchdog toggle in the Gaming & Streaming Setup screen,
/// plus the optional "auto while a gaming trigger is brewing" mode. Owns no
/// timer: the host's ticker calls ``autoTick(gamingActive:)`` and the window
/// calls ``refresh()``. `@MainActor` like the other controllers; the blocking
/// admin prompt and shell-outs run on detached tasks.
@MainActor
@Observable
public final class AWDLWatchdogController {
    /// Live state of `awdl0`. `nil` before the first ``refresh()`` or when
    /// unreadable (e.g. a Mac without the interface).
    public private(set) var isInterfaceUp: Bool?

    /// Whether the watchdog loop is running (the flag file is present).
    public private(set) var isRunning = false

    /// Message from the last failed attempt; `nil` after a success or a user
    /// cancellation (cancelling is not an error to nag about).
    public private(set) var lastError: String?

    /// True while the admin prompt is on screen, so the UI can show progress
    /// and a second toggle can't stack another prompt.
    public private(set) var isBusy = false

    /// When on, the watchdog starts as a gaming trigger holds the session and
    /// stops when it lets go. The host persists this and mirrors it in.
    public var autoWithGaming = false

    /// Whether the current run was started by auto mode (so auto mode only
    /// stops what it started, never a manual run).
    private var autoStarted = false

    /// Set when an auto start was cancelled or failed, so the once-per-session
    /// prompt doesn't re-appear every tick; cleared when the gaming bout ends.
    private var autoHeldOff = false

    /// Whether the root helper was already spawned this app run. Once it's up,
    /// activating and deactivating is flag-file-only: no more prompts.
    private var helperStarted = false

    private let launcher: AWDLWatchdogLaunching
    private let reader: AWDLStateReading
    private let appPID: Int32

    public init(
        launcher: AWDLWatchdogLaunching = OsascriptAWDLWatchdog(),
        reader: AWDLStateReading = IfconfigAWDLReader(),
        appPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.launcher = launcher
        self.reader = reader
        self.appPID = appPID
    }

    /// Re-read the flag and the interface state (both off the main actor: the
    /// interface read shells out).
    public func refresh() async {
        let launcher = self.launcher
        let reader = self.reader
        let (flag, up) = await Task.detached { (launcher.isFlagPresent(), reader.isUp()) }.value
        isRunning = flag
        isInterfaceUp = up
    }

    /// Remove any stale flag left by a previous run (a hard kill or a reboot
    /// mid-watchdog). Called once at app launch: any loop from a previous
    /// process has already exited via its pid check, so a surviving flag is
    /// stale by definition.
    public func cleanupAtLaunch() async {
        let launcher = self.launcher
        await Task.detached { launcher.removeFlag() }.value
    }

    /// Activate the watchdog. The first activation of this app run spawns the
    /// root helper (one administrator prompt); later ones just recreate the
    /// flag, instantly and prompt-free. Ignores a second call while the
    /// prompt is already up.
    @discardableResult
    public func start() async -> AWDLWatchdogStartResult {
        guard !isBusy else { return .cancelled }
        isBusy = true
        defer { isBusy = false }
        let launcher = self.launcher
        let flagCreated = await Task.detached { launcher.createFlag() }.value
        guard flagCreated else {
            let message = "Couldn't create the watchdog flag file."
            lastError = message
            return .failed(message)
        }
        if helperStarted {
            lastError = nil
            isRunning = true
            return .started
        }
        let pid = self.appPID
        let result = await Task.detached { launcher.startHelper(appPID: pid) }.value
        switch result {
        case .started:
            lastError = nil
            isRunning = true
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

    /// Whether the root helper is already authorized and running this app run,
    /// so activating (manual or automatic) needs no further password prompt.
    public var isAuthorized: Bool { helperStarted }

    /// Pre-authorize the helper without pausing AWDL: spawn it (one prompt now,
    /// in whatever context the caller chose) then immediately drop the flag so
    /// `awdl0` stays up. After this, an automatic activation when a game comes
    /// to the front is a prompt-free flag write and never pops a password dialog
    /// over a running game. No-op (and no prompt) once already authorized.
    @discardableResult
    public func prime() async -> AWDLWatchdogStartResult {
        guard !helperStarted, !isBusy else { return .started }
        let result = await start()
        if case .started = result { await stop() }
        return result
    }

    /// Deactivate the watchdog: just delete the flag (no prompt); the helper
    /// notices within a cycle, restores `awdl0 up`, and idles for the next
    /// activation.
    public func stop() async {
        let launcher = self.launcher
        await Task.detached { launcher.removeFlag() }.value
        isRunning = false
        autoStarted = false
    }

    /// Hold auto mode off until the current game (and its grace) has fully ended,
    /// so a manual override isn't immediately re-paused by the next auto tick.
    /// ``autoTick(gamingActive:)`` clears it once it next sees no game.
    public func holdAutoOff() { autoHeldOff = true }

    /// Stop only an auto-started run; a manual run is left alone. For when auto
    /// mode is switched off mid-bout.
    public func stopIfAuto() async {
        if autoStarted { await stop() }
    }

    /// Auto mode's once-a-second pulse. Starts the watchdog while a game is
    /// running (`gamingActive`, decided by the host, one prompt; a cancel holds
    /// off until the bout ends) and stops it again when the bout is over. Only
    /// ever stops a run it started, so a manual run survives gaming ending.
    public func autoTick(gamingActive: Bool) async {
        guard autoWithGaming else { return }
        if gamingActive {
            guard !isRunning, !isBusy, !autoHeldOff else { return }
            switch await start() {
            case .started:
                autoStarted = true
            case .cancelled, .failed:
                autoHeldOff = true
            }
        } else {
            autoHeldOff = false
            if autoStarted {
                await stop()
            }
        }
    }
}
