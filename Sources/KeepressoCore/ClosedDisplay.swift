import Foundation
import Observation

/// Outcome of trying to change the system-wide sleep setting.
public enum SleepSettingResult: Equatable, Sendable {
    case applied
    case cancelled
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
    func isSleepDisabled() -> Bool?

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
    private let brightness: BrightnessControlling

    /// What the watchdog should do with the panel while the lid is shut.
    /// `displayOff` (the default) preserves the long-standing behavior. Set
    /// from persisted settings by the host; read on every ``tick()``.
    public var policy: ClosedLidDisplayPolicy = .displayOff
    /// Why the last ``tick()`` held off without sleeping: the
    /// brightness-unavailable fallback, for the menu to show. `nil` while the
    /// policy is working as configured (nothing worth reporting) or the mode
    /// is off. The leave-alone policy needs no reason: the picker's own
    /// caption already says what it does.
    public private(set) var lastDecisionReason: String?

    private var wantedPanelAsleep = false
    private var lastPanelSleepAt: Date?
    /// The brightness saved when the lid shut under the zero-brightness
    /// policy, restored when the lid reopens. `nil` outside that stretch.
    /// Never macOS's post-close zero (see ``noteOpenBrightnessLevel()``).
    private var savedBrightness: Double?
    /// Last panel level observed while the lid was open. The first shut tick
    /// is too late to sample: macOS has often already darkened the panel, so
    /// a live read would capture 0 and a restore would leave it dark after
    /// reopening (see GitHub #13).
    private var lastOpenBrightness: Double?
    private var lastDimAt: Date?
    private var lastRefreshedAt: Date?
    private var readGeneration = 0
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
        brightness: BrightnessControlling = NullBrightness(),
        now: @escaping () -> Date = Date.init
    ) {
        self.control = control
        self.lid = lid
        self.externalDisplay = externalDisplay
        self.displaySleeper = displaySleeper
        self.displayPower = displayPower
        self.brightness = brightness
        self.now = now
    }

    /// Enforce the lid-shut display policy while lid-closed mode is on.
    ///
    /// Under `displayOff` the edges *into* the shut state (the lid closing,
    /// and the external display being unplugged with the lid already shut)
    /// get a `displaysleepnow`, and a panel lit from outside while the lid
    /// stays shut is put back to sleep. Under `zeroBrightness` the shut edge
    /// saves the brightness and zeroes the panel (the framebuffer stays live
    /// for remote sessions), and reopening restores what was saved.
    ///
    /// With an external display attached nothing fires: `displaysleepnow`
    /// would also blank that monitor, breaking a legitimate
    /// clamshell-with-monitor setup. Safe to call every second.
    public func tick() {
        // Only reset the edge flags when the mode is actually off. A transient
        // nil lid read (AppleClamshellState occasionally returns nil) must not
        // clear them: doing so would re-fire `displaysleepnow` on the next good
        // read even though the panel is already asleep, spawning spurious pmset
        // processes during a nil-read flutter.
        guard isEnabled == true else {
            wantedPanelAsleep = false
            lastPanelSleepAt = nil
            restoreBrightness()
            lastDecisionReason = nil
            return
        }
        if policy != .zeroBrightness { restoreBrightness() }
        guard let closed = lid.isClosed() else { return }
        switch DisplayPolicyDecision.decide(
            policy: policy,
            lidClosed: closed,
            hasExternalDisplay: externalDisplay.current.hasExternalDisplay
        ) {
        case .hold:
            wantedPanelAsleep = false
            lastPanelSleepAt = nil
            if !closed { noteOpenBrightnessLevel() }
            restoreBrightness()
            lastDecisionReason = nil
        case .sleepPanel:
            lastDecisionReason = nil
            tickSleep()
        case .holdDim:
            wantedPanelAsleep = false
            lastPanelSleepAt = nil
            tickDim()
        }
    }

    private func tickSleep() {
        defer { wantedPanelAsleep = true }
        guard wantedPanelAsleep else {
            sleepPanel()
            return
        }
        guard let lastPanelSleepAt,
              now().timeIntervalSince(lastPanelSleepAt) >= Self.resleepGrace,
              displayPower.builtInIsAsleep() == false else { return }
        sleepPanel()
    }

    private func sleepPanel() {
        displaySleeper.sleepNow()
        lastPanelSleepAt = now()
    }

    private func tickDim() {
        guard brightness.isSupported else {
            lastDecisionReason = L("Brightness control is unavailable, turning the display off instead.")
            tickSleep()
            return
        }
        lastDecisionReason = nil
        if savedBrightness == nil {
            // The shut edge: zero only once a restore target exists. Prefer a
            // live lit reading, else the last open-lid sample, never macOS's
            // post-close zero. Without either, retry next tick rather than
            // zeroing a level that could never be handed back.
            guard let target = litBrightnessTarget() else { return }
            savedBrightness = target
            brightness.setBrightness(0)
            lastDimAt = now()
            return
        }
        guard let current = brightness.currentBrightness(),
              current > Self.litThreshold,
              let lastDimAt,
              now().timeIntervalSince(lastDimAt) >= Self.resleepGrace else { return }
        brightness.setBrightness(0)
        self.lastDimAt = now()
    }

    /// A level worth remembering or treating as lit. At or below this the
    /// panel reads as dark (macOS's own post-close zero included).
    private static let litThreshold = 0.02

    private func noteOpenBrightnessLevel() {
        guard let current = brightness.currentBrightness(),
              current > Self.litThreshold else { return }
        lastOpenBrightness = current
    }

    private func litBrightnessTarget() -> Double? {
        if let current = brightness.currentBrightness(), current > Self.litThreshold {
            return current
        }
        return lastOpenBrightness
    }

    private func restoreBrightness() {
        guard let saved = savedBrightness else {
            lastDimAt = nil
            return
        }
        guard let current = brightness.currentBrightness() else { return }
        savedBrightness = nil
        lastDimAt = nil
        guard current <= Self.litThreshold else { return }
        brightness.setBrightness(saved)
    }

    /// Hand back a saved brightness without ending anything, for app
    /// termination where the per-second tick won't run again. Mirrors
    /// ``SessionController/restoreDisplayBrightness``: brightness persists
    /// across exit, so quitting mid-stretch would otherwise leave the panel
    /// at zero. Idempotent and a no-op when nothing is saved.
    public func restoreDisplayBrightness() {
        restoreBrightness()
    }

    /// Re-read the current system setting. The read shells out to `pmset -g`,
    /// which must NOT run on the main thread: a synchronous `Process.waitUntilExit`
    /// spins the main run loop, and with a virtual display active a re-entrant
    /// display-driver callback can crash (EXC_BAD_ACCESS). So the read hops to a
    /// detached task and the result lands back on the main actor.
    public func refresh(force: Bool = false) async {
        guard !isBusy else { return }
        if !force,
           isEnabled != nil,
           let lastRefreshedAt,
           now().timeIntervalSince(lastRefreshedAt) < Self.refreshFreshness {
            return
        }
        let control = self.control
        let generation = readGeneration
        let value = await Task.detached { control.isSleepDisabled() }.value
        guard !isBusy, generation == readGeneration else { return }
        isEnabled = value
        lastRefreshedAt = now()
    }

    /// Blocking re-read, for the one caller that cannot await: quit-time
    /// coverage is decided inside `applicationShouldTerminate`, which must
    /// return a reply synchronously. ``isEnabled`` is otherwise only
    /// refreshed at launch and on menu open, so a lid mode switched on since
    /// then reads stale (or `nil`) and the quit modal misses it entirely.
    ///
    /// One `pmset -g` on the main thread, tens of milliseconds, paid once on
    /// the way out. Defers to an in-flight ``set(_:)`` exactly like
    /// ``refresh(force:)``: that write is the authoritative state.
    public func refreshBlocking() {
        guard !isBusy else { return }
        let generation = readGeneration
        let value = control.isSleepDisabled()
        guard !isBusy, generation == readGeneration else { return }
        isEnabled = value
        lastRefreshedAt = now()
    }

    @discardableResult
    public func set(_ enabled: Bool) async -> SleepSettingResult {
        guard !isBusy else { return .cancelled }
        isBusy = true
        readGeneration += 1
        defer { isBusy = false }
        let control = self.control
        let result = await Task.detached { control.setSleepDisabled(enabled) }.value
        switch result {
        case .applied, .cancelled:
            lastError = nil
        case .failed(let message):
            lastError = message
        }
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

    /// `pmset -g` prints a `SleepDisabled 1` line only
    /// when the flag is on; its absence means sleep is enabled (the default).
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


    private func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
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
