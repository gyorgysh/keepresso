import Foundation

/// What Keepresso does to the Mac the moment a keep-awake session ends on its
/// own (a timed session expires, trigger conditions drop, or a low-battery
/// pause). Never runs on a manual stop: the user already did what they wanted.
public enum SessionEndAction: String, Codable, CaseIterable, Sendable {
    /// Do nothing (the default).
    case none
    /// Put the display to sleep (`pmset displaysleepnow`).
    case sleepDisplay
    /// Start the screen saver.
    case startScreensaver

    /// A menu label for the Preferences picker.
    public var label: String {
        switch self {
        case .none:            return "Do nothing"
        case .sleepDisplay:    return "Sleep the display"
        case .startScreensaver: return "Start the screen saver"
        }
    }
}

/// Performs the ``SessionEndAction`` when a session ends. A seam like the others
/// so ``SessionController`` can be tested without touching the display or
/// launching processes.
public protocol SessionEndActing: AnyObject {
    func perform(_ action: SessionEndAction)
}

/// Real backend. Display-sleep reuses the same `pmset displaysleepnow` path as
/// closed-display mode; the screen saver is launched via `open`. Both are
/// prompt-free (no Accessibility, no admin).
public final class SystemEndActionPerformer: SessionEndActing {
    private let displaySleeper: DisplaySleepCommanding

    public init(displaySleeper: DisplaySleepCommanding = PMSetDisplaySleeper()) {
        self.displaySleeper = displaySleeper
    }

    public func perform(_ action: SessionEndAction) {
        switch action {
        case .none:
            break
        case .sleepDisplay:
            displaySleeper.sleepNow()
        case .startScreensaver:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "ScreenSaverEngine"]
            try? process.run()
        }
    }
}
