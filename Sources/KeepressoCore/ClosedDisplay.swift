import Foundation
import Observation

/// Outcome of trying to change the system-wide sleep setting.
public enum SleepSettingResult: Equatable, Sendable {
    /// The change was applied.
    case applied
    /// The user dismissed the administrator-password prompt.
    case cancelled
    /// The command ran but failed, with a message to surface.
    case failed(String)
}

/// Controls macOS's system-wide "disable sleep" flag (`pmset disablesleep`).
///
/// This is the only lever that keeps a Mac awake with the **lid closed** and no
/// external display attached: the per-session `IOPMAssertion`s behind
/// ``PowerAsserting`` cannot override clamshell sleep. Unlike those assertions,
/// `disablesleep` is a global system setting that needs administrator rights to
/// change and is **not** scoped to AC vs battery, so it lives behind its own
/// seam. ``PMSetSleepControl`` is the real backend; tests inject a fake.
public protocol SleepSettingControlling: AnyObject, Sendable {
    /// Whether system sleep is currently disabled. `nil` if it couldn't be read
    /// (e.g. `pmset` failed to run).
    func isSleepDisabled() -> Bool?

    /// Set the global `disablesleep` flag, prompting for administrator rights.
    /// Blocking: it waits for the user to answer the prompt.
    func setSleepDisabled(_ disabled: Bool) -> SleepSettingResult
}

/// Drives the "closed-display mode" toggle. Owns no timer and no persistence:
/// the system setting itself is the source of truth, so the controller just
/// reads it live and writes through on a user toggle. `@MainActor` like the
/// other controllers; the blocking admin prompt is dispatched off the main
/// actor in ``set(_:)``.
@MainActor
@Observable
public final class ClosedDisplayController {
    /// Live state of the system setting: `true` = sleep disabled (lid-closed
    /// mode on). `nil` before the first ``refresh()`` or when unreadable.
    public private(set) var isEnabled: Bool?

    /// Message from the last failed attempt, for the UI to surface. `nil` after
    /// a success or a user cancellation (cancelling is not an error to nag about).
    public private(set) var lastError: String?

    /// True while an admin prompt is on screen, so the UI can show progress and
    /// a second toggle can't stack another prompt.
    public private(set) var isBusy = false

    private let control: SleepSettingControlling
    private let lid: LidStateReading
    private let externalDisplay: DisplayMonitoring
    private let displaySleeper: DisplaySleepCommanding

    /// Whether the lid was closed as of the last ``tick()``, so the sleep
    /// command only fires once per closed transition.
    private var lidWasClosed = false

    public init(
        control: SleepSettingControlling = PMSetSleepControl(),
        lid: LidStateReading = IORegistryLidState(),
        externalDisplay: DisplayMonitoring = CoreGraphicsDisplayMonitor(),
        displaySleeper: DisplaySleepCommanding = PMSetDisplaySleeper()
    ) {
        self.control = control
        self.lid = lid
        self.externalDisplay = externalDisplay
        self.displaySleeper = displaySleeper
    }

    /// Force the display to sleep the instant the lid closes, while
    /// lid-closed mode is on and no external display is attached (with an
    /// external display, `displaysleepnow` would also blank that monitor,
    /// breaking a legitimate clamshell-with-monitor setup). macOS auto-wakes
    /// the panel when the lid reopens, so there's nothing to do on that edge.
    /// Safe to call every second.
    public func tick() {
        guard isEnabled == true, let closed = lid.isClosed() else {
            lidWasClosed = false
            return
        }
        guard !externalDisplay.current.hasExternalDisplay else {
            lidWasClosed = closed
            return
        }
        if closed, !lidWasClosed {
            let sleeper = displaySleeper
            Task.detached { sleeper.sleepNow() } // shells out; keep off the main actor
        }
        lidWasClosed = closed
    }

    /// Re-read the current system setting. The read shells out to `pmset -g`,
    /// which must NOT run on the main thread: a synchronous `Process.waitUntilExit`
    /// spins the main run loop, and with a virtual display active a re-entrant
    /// display-driver callback can crash (EXC_BAD_ACCESS). So the read hops to a
    /// detached task and the result lands back on the main actor.
    public func refresh() async {
        let control = self.control
        isEnabled = await Task.detached { control.isSleepDisabled() }.value
    }

    /// Request the new state. Shows the administrator prompt off the main actor
    /// so the UI doesn't freeze while the user answers, then re-reads the actual
    /// resulting state.
    @discardableResult
    public func set(_ enabled: Bool) async -> SleepSettingResult {
        // Ignore a second toggle while a prompt is already up, so we never stack
        // two authorization dialogs.
        guard !isBusy else { return .cancelled }
        isBusy = true
        defer { isBusy = false }
        let control = self.control
        let result = await Task.detached { control.setSleepDisabled(enabled) }.value
        switch result {
        case .applied, .cancelled:
            lastError = nil
        case .failed(let message):
            lastError = message
        }
        // Re-read off the main thread too (same reason as ``refresh()``).
        isEnabled = await Task.detached { control.isSleepDisabled() }.value
        return result
    }
}

/// Real ``SleepSettingControlling`` backed by `pmset`. Reads state from
/// `pmset -g` and writes via `osascript`'s "with administrator privileges",
/// which shows the standard macOS authorization dialog. Not `@MainActor`: the
/// write blocks on the user's prompt, so callers run it off the main actor.
public final class PMSetSleepControl: SleepSettingControlling {
    public init() {}

    public func isSleepDisabled() -> Bool? {
        Self.parseSleepDisabled(from: run("/usr/bin/pmset", ["-g"]))
    }

    /// Pure parse of `pmset -g` output, factored out so it can be unit-tested
    /// without shelling out. `pmset -g` prints a `SleepDisabled 1` line only
    /// when the flag is on; its absence means sleep is enabled (the default).
    /// Returns `nil` only when there was no output at all to read.
    public static func parseSleepDisabled(from output: String?) -> Bool? {
        guard let output else { return nil }
        return PMSet.value(forKey: "SleepDisabled", in: output) == 1
    }

    public func setSleepDisabled(_ disabled: Bool) -> SleepSettingResult {
        // `pmset disablesleep` needs root. osascript's "with administrator
        // privileges" pops the standard auth dialog and runs the command as root.
        let command = "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
        let script = "do shell script \"\(command)\" with administrator privileges"
        let result = runForResult("/usr/bin/osascript", ["-e", script])
        guard let result else {
            return .failed("Couldn't run the sleep setting command.")
        }
        if result.status == 0 { return .applied }
        // osascript reports a user-cancelled auth prompt as error -128.
        if result.stderr.contains("-128") || result.stderr.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "The sleep setting couldn't be changed." : message)
    }

    // MARK: - Shelling out

    /// Run a command and return trimmed stdout, or `nil` on any failure. Mirrors
    /// ``ShellSystemProbe``'s helper.
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

    /// Run a command and return its exit status plus stderr, or `nil` if it
    /// couldn't be launched. Used for the write, where the failure reason matters.
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
