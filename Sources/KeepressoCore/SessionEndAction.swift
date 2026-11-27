import Foundation
import IOKit.pwr_mgt

/// What Keepresso does to the Mac after a keep-awake session ends on its own
/// (a timed session expires, or trigger conditions drop). Never runs on a
/// manual stop, and never on the battery or thermal safety pauses: those
/// already manage sleep themselves. Default is do nothing.
public enum SessionEndAction: String, Codable, CaseIterable, Sendable {
    case none
    case sleepDisplay
    case lockScreen
    case startScreensaver
    case sleepMac

    /// A menu label for the Preferences picker.
    public var label: String {
        switch self {
        case .none:             return L("Do nothing")
        case .sleepDisplay:     return L("Sleep the display")
        case .lockScreen:       return L("Lock the screen")
        case .startScreensaver: return L("Start the screen saver")
        case .sleepMac:         return L("Sleep the Mac")
        }
    }
}

/// Performs the ``SessionEndAction`` when a session ends. A seam like the
/// others so ``SessionController`` can be tested without touching the display
/// or launching processes.
public protocol SessionEndActing: AnyObject {
    func perform(_ action: SessionEndAction)
}

/// Puts the Mac to sleep. Prefer the privileged helper (`pmset sleepnow`) when
/// installed; fall back to IOKit, then System Events. Separated so the app can
/// inject a helper-aware backend without Core depending on XPC.
public protocol SystemSleepCommanding: Sendable {
    @discardableResult
    func sleepNow() -> Bool
}

/// Locks the screen without sleeping the Mac.
public protocol ScreenLocking: Sendable {
    func lock()
}

/// Real backend. Display sleep reuses the closed-display `pmset
/// displaysleepnow` path. Lock and screen saver are prompt-free. Full sleep
/// tries the injected system sleeper (helper-aware when the app wires one).
public final class SystemEndActionPerformer: SessionEndActing {
    private let displaySleeper: DisplaySleepCommanding
    private let systemSleeper: SystemSleepCommanding
    private let screenLocker: ScreenLocking

    public init(
        displaySleeper: DisplaySleepCommanding = PMSetDisplaySleeper(),
        systemSleeper: SystemSleepCommanding = CompositeSystemSleeper(),
        screenLocker: ScreenLocking = SystemEventsScreenLocker()
    ) {
        self.displaySleeper = displaySleeper
        self.systemSleeper = systemSleeper
        self.screenLocker = screenLocker
    }

    public func perform(_ action: SessionEndAction) {
        switch action {
        case .none:
            break
        case .sleepDisplay:
            displaySleeper.sleepNow()
        case .lockScreen:
            screenLocker.lock()
        case .startScreensaver:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "ScreenSaverEngine"]
            try? process.run()
        case .sleepMac:
            let sleeper = systemSleeper
            Task.detached { _ = sleeper.sleepNow() }
        }
    }
}

/// Tries IOKit ``IOPMSleepSystem``, then System Events AppleScript. The app
/// wraps this with a helper-first attempt when the daemon is installed.
public final class CompositeSystemSleeper: SystemSleepCommanding {
    private let preferred: (@Sendable () -> Bool)?

    public init(preferred: (@Sendable () -> Bool)? = nil) {
        self.preferred = preferred
    }

    @discardableResult
    public func sleepNow() -> Bool {
        if let preferred, preferred() { return true }
        if Self.sleepViaIOKit() { return true }
        return Self.sleepViaSystemEvents()
    }

    private static func sleepViaIOKit() -> Bool {
        let port = IOPMFindPowerManagement(mach_task_self_)
        guard port != 0 else { return false }
        defer { IOServiceClose(port) }
        return IOPMSleepSystem(port) == kIOReturnSuccess
    }

    private static func sleepViaSystemEvents() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to sleep"]
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

/// Locks via System Events `lock screen` (Monterey+). Prompt-free on a
/// console session that already trusts the app, otherwise macOS may ask for
/// Automation once.
public final class SystemEventsScreenLocker: ScreenLocking {
    public init() {}

    public func lock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to lock screen"]
        try? process.run()
    }
}
