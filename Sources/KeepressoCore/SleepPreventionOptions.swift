import Foundation

/// What Keepresso should keep awake while a session is active.
///
/// The two flags map onto distinct IOKit power assertions:
/// - ``preventSystemSleep``  → `kIOPMAssertPreventUserIdleSystemSleep`
/// - ``preventDisplaySleep`` → `kIOPMAssertPreventUserIdleDisplaySleep`
///
/// They are independent: you can keep the machine running with the display
/// allowed to sleep (e.g. long downloads, NAS jobs), or keep the screen lit.
public struct SleepPreventionOptions: Equatable, Codable, Sendable {
    /// Keep the system awake even when otherwise idle. With this on, the Mac
    /// will not enter idle sleep — including, on most hardware running on AC
    /// power, when the lid is closed (clamshell).
    public var preventSystemSleep: Bool

    /// Keep the display awake (no dimming / display sleep).
    public var preventDisplaySleep: Bool

    /// When set, the screen saver is permitted to start after this many seconds
    /// of inactivity *even though the system stays awake*. Implemented by
    /// dropping the display-sleep assertion after the interval while keeping the
    /// system-sleep assertion. `nil` means never yield the display.
    ///
    /// Only meaningful when ``preventDisplaySleep`` is `true`.
    public var allowScreenSaverAfter: TimeInterval?

    public init(
        preventSystemSleep: Bool = true,
        preventDisplaySleep: Bool = false,
        allowScreenSaverAfter: TimeInterval? = nil
    ) {
        self.preventSystemSleep = preventSystemSleep
        self.preventDisplaySleep = preventDisplaySleep
        self.allowScreenSaverAfter = allowScreenSaverAfter
    }

    /// The default "brew": keep the system awake, let the screen do its thing.
    public static let `default` = SleepPreventionOptions()
}
