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

/// System-touching seam for the watchdog loop itself: a root process that
/// keeps forcing `awdl0` down while a user-owned flag file exists.
///
/// The privilege design keeps macOS happy without a permanent daemon: starting
/// needs ONE administrator prompt (which spawns the loop as root), stopping
/// just deletes the flag file (no prompt), and the loop also watches the app's
/// pid, so an app crash or quit tears it down and restores `awdl0` on its own.
public protocol AWDLWatchdogLaunching: AnyObject, Sendable {
    /// Whether the flag file that keeps the loop alive is present.
    func isFlagPresent() -> Bool
    /// Create the flag and spawn the root loop. Blocking: it waits for the
    /// user to answer the administrator prompt.
    func start(appPID: Int32) -> AWDLWatchdogStartResult
    /// Delete the flag; the loop notices within a cycle, restores `awdl0 up`,
    /// and exits.
    func removeFlag()
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

    public func removeFlag() {
        try? FileManager.default.removeItem(at: flagURL)
    }

    public func start(appPID: Int32) -> AWDLWatchdogStartResult {
        do {
            try FileManager.default.createDirectory(
                at: flagURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: flagURL)
        } catch {
            return .failed("Couldn't create the watchdog flag file.")
        }
        let command = Self.watchdogCommand(flagPath: flagURL.path, appPID: appPID)
        let script = "do shell script \"\(Self.appleScriptEscaped(command))\" with administrator privileges"
        guard let result = runForResult("/usr/bin/osascript", ["-e", script]) else {
            removeFlag()
            return .failed("Couldn't run the watchdog command.")
        }
        if result.status == 0 { return .started }
        removeFlag()
        // osascript reports a user-cancelled auth prompt as error -128.
        if result.stderr.contains("-128") || result.stderr.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "The watchdog couldn't be started." : message)
    }

    /// The root loop, backgrounded so `do shell script` returns immediately.
    /// macOS re-raises `awdl0` after sleep/wake, Wi-Fi toggles, or any app
    /// requesting AWDL, hence the re-down every ~5 s rather than a single
    /// `down`. The loop exits (and restores the interface) when the flag
    /// disappears OR the app's pid dies, so a crash fails safe; it removes the
    /// flag itself on the pid path so no stale flag survives.
    static func watchdogCommand(flagPath: String, appPID: Int32) -> String {
        "( while [ -f \"\(flagPath)\" ] && kill -0 \(appPID) 2>/dev/null; "
            + "do /sbin/ifconfig awdl0 down; sleep 5; done; "
            + "rm -f \"\(flagPath)\"; /sbin/ifconfig awdl0 up ) </dev/null >/dev/null 2>&1 &"
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

    /// Start the watchdog, prompting for administrator rights once. Ignores a
    /// second call while the prompt is already up.
    @discardableResult
    public func start() async -> AWDLWatchdogStartResult {
        guard !isBusy else { return .cancelled }
        isBusy = true
        defer { isBusy = false }
        let launcher = self.launcher
        let pid = self.appPID
        let result = await Task.detached { launcher.start(appPID: pid) }.value
        switch result {
        case .started:
            lastError = nil
            isRunning = true
        case .cancelled:
            lastError = nil
        case .failed(let message):
            lastError = message
        }
        return result
    }

    /// Stop the watchdog: just delete the flag (no prompt); the root loop
    /// notices within a cycle, restores `awdl0 up`, and exits.
    public func stop() async {
        let launcher = self.launcher
        await Task.detached { launcher.removeFlag() }.value
        isRunning = false
        autoStarted = false
    }

    /// Auto mode's once-a-second pulse. Starts the watchdog when a gaming
    /// trigger is holding the session (one prompt; a cancel holds off until
    /// the bout ends) and stops it again when the bout is over. Only ever
    /// stops a run it started, so a manual run survives gaming ending.
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
