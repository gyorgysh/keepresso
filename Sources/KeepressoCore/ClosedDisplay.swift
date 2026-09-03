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
    private let displayPower: DisplayPowerReading

    /// Whether the last ``tick()`` already wanted the panel asleep (lid closed
    /// with no external display), so the sleep command fires once per
    /// transition into that state.
    private var wantedPanelAsleep = false
    /// When the last `displaysleepnow` was issued, so a panel that gets lit
    /// again inside the closed lid is put back to sleep without firing `pmset`
    /// every second while the panel is on its way down.
    private var lastPanelSleepAt: Date?
    /// When ``isEnabled`` was last read from the system. Menu opens reuse a
    /// fresh-enough cache instead of shelling `pmset -g` every time.
    private var lastRefreshedAt: Date?
    private let now: () -> Date
    /// How long a successful read may be trusted for menu-driven refreshes.
    public static let refreshFreshness: TimeInterval = 20

    /// How long after a `displaysleepnow` a still-lit panel counts as woken
    /// rather than still on its way down. Long enough for the panel to go dark
    /// and report it, short enough that a notification's wake doesn't sit lit
    /// inside a closed lid.
    public static let resleepGrace: TimeInterval = 5

    public init(
        control: SleepSettingControlling = PMSetSleepControl(),
        lid: LidStateReading = IORegistryLidState(),
        externalDisplay: DisplayMonitoring = CoreGraphicsDisplayMonitor(),
        displaySleeper: DisplaySleepCommanding = PMSetDisplaySleeper(),
        displayPower: DisplayPowerReading = CoreGraphicsDisplayPower(),
        now: @escaping () -> Date = Date.init
    ) {
        self.control = control
        self.lid = lid
        self.externalDisplay = externalDisplay
        self.displaySleeper = displaySleeper
        self.displayPower = displayPower
        self.now = now
    }

    /// Keep the display dark for as long as the lid is shut with no external
    /// display attached, while lid-closed mode is on.
    ///
    /// Two things to do. The edges *into* that state get a `displaysleepnow`:
    /// the lid closing, and the external display being unplugged with the lid
    /// already shut (which otherwise leaves the internal panel lit inside the
    /// closed lid). After that the panel has to be held dark, because a single
    /// `displaysleepnow` does not stick: a notification, a Bluetooth keypress,
    /// or any app taking a display assertion lights the panel back up, and
    /// with sleep disabled it then stays lit on the lock screen inside the
    /// shut lid until the lid is opened. So while the state holds, a panel
    /// that reads awake is put back to sleep.
    ///
    /// With an external display attached nothing fires: `displaysleepnow`
    /// would also blank that monitor, breaking a legitimate
    /// clamshell-with-monitor setup. macOS auto-wakes the panel when the lid
    /// reopens, so there's nothing to do on that edge. Safe to call every
    /// second.
    public func tick() {
        // Only reset the edge flag when the mode is actually off. A transient
        // nil lid read (AppleClamshellState occasionally returns nil) must not
        // clear it: doing so would re-fire `displaysleepnow` on the next good
        // read even though the panel is already asleep, spawning spurious pmset
        // processes during a nil-read flutter.
        guard isEnabled == true else {
            wantedPanelAsleep = false
            lastPanelSleepAt = nil
            return
        }
        guard let closed = lid.isClosed() else { return }
        let wantsPanelAsleep = closed && !externalDisplay.current.hasExternalDisplay
        defer { wantedPanelAsleep = wantsPanelAsleep }
        guard wantsPanelAsleep else {
            lastPanelSleepAt = nil
            return
        }
        guard wantedPanelAsleep else {
            sleepPanel()
            return
        }
        // Already inside the closed-lid stretch. Re-sleep a panel that was lit
        // from outside, but only on a reading that actually says so: an
        // unreadable panel state falls back to the old fire-once behavior
        // rather than shelling out to `pmset` on a guess.
        guard let lastPanelSleepAt,
              now().timeIntervalSince(lastPanelSleepAt) >= Self.resleepGrace,
              displayPower.builtInIsAsleep() == false else { return }
        sleepPanel()
    }

    private func sleepPanel() {
        displaySleeper.sleepNow()
        lastPanelSleepAt = now()
    }

    /// Re-read the current system setting. The read shells out to `pmset -g`,
    /// which must NOT run on the main thread: a synchronous `Process.waitUntilExit`
    /// spins the main run loop, and with a virtual display active a re-entrant
    /// display-driver callback can crash (EXC_BAD_ACCESS). So the read hops to a
    /// detached task and the result lands back on the main actor.
    ///
    /// When `force` is false and a recent successful read is still fresh, this
    /// is a no-op so menu open does not pay for another `pmset -g`. Launch,
    /// post-toggle, and only-while-brewing enforcement pass `force: true` (or
    /// hit a nil cache) so correctness stays intact.
    public func refresh(force: Bool = false) async {
        // Defer to an in-flight ``set(_:)``: it writes the authoritative state
        // after its prompt. A refresh landing its (pre-write) read last would
        // otherwise briefly show the stale toggle. Checked on both sides of the
        // await, since a write can start mid-read.
        guard !isBusy else { return }
        if !force,
           isEnabled != nil,
           let lastRefreshedAt,
           now().timeIntervalSince(lastRefreshedAt) < Self.refreshFreshness {
            return
        }
        let control = self.control
        let value = await Task.detached { control.isSleepDisabled() }.value
        guard !isBusy else { return }
        isEnabled = value
        lastRefreshedAt = now()
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
        lastRefreshedAt = now()
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
            return .failed(L("Couldn't run the sleep setting command."))
        }
        if result.status == 0 { return .applied }
        // osascript reports a user-cancelled auth prompt as error -128.
        if result.stderr.contains("-128") || result.stderr.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? L("The sleep setting couldn't be changed.") : message)
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
