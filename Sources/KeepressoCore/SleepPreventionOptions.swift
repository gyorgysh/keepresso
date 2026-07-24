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
    /// will not enter idle sleep, including, on most hardware running on AC
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

    /// When set, dim the display to ``dimFloor`` after this many seconds of
    /// inactivity instead of leaving it fully lit, restoring the previous
    /// brightness on the next activity or when the session ends ("dim, don't
    /// sleep"). Unlike ``allowScreenSaverAfter`` the display assertion is kept,
    /// so the panel stays awake, just dark. `nil` means never dim. Only
    /// meaningful when ``preventDisplaySleep`` is `true`, and mutually exclusive
    /// with ``allowScreenSaverAfter`` (after idle you either let the display
    /// sleep or dim it, not both).
    public var dimDisplayAfter: TimeInterval?

    /// The brightness to dim to when ``dimDisplayAfter`` fires, in `0...1`.
    /// Defaults to `0` (the dimmest backlight; the display stays awake, just
    /// dark).
    public var dimFloor: Double

    /// Also report user activity to the OS while the session runs, defeating
    /// app-level and enterprise idle detection (remote-desktop, meeting
    /// presence, corporate idle-logout) that a plain power assertion doesn't
    /// reach. Off by default; see ``ActivitySimulating``.
    public var simulateUserActivity: Bool

    public init(
        preventSystemSleep: Bool = true,
        preventDisplaySleep: Bool = false,
        allowScreenSaverAfter: TimeInterval? = nil,
        dimDisplayAfter: TimeInterval? = nil,
        dimFloor: Double = 0,
        simulateUserActivity: Bool = false
    ) {
        self.preventSystemSleep = preventSystemSleep
        self.preventDisplaySleep = preventDisplaySleep
        self.allowScreenSaverAfter = allowScreenSaverAfter
        self.dimDisplayAfter = dimDisplayAfter
        self.dimFloor = dimFloor
        self.simulateUserActivity = simulateUserActivity
    }

    /// The default "brew": keep the system awake, let the screen do its thing.
    public static let `default` = SleepPreventionOptions()

    private enum CodingKeys: String, CodingKey {
        case preventSystemSleep, preventDisplaySleep, allowScreenSaverAfter
        case dimDisplayAfter, dimFloor, simulateUserActivity
    }

    /// Forgiving decoder: each field falls back to its default when absent, so a
    /// settings blob saved by an older build (before a field existed) still
    /// decodes instead of throwing and resetting the whole configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preventSystemSleep = try c.decodeIfPresent(Bool.self, forKey: .preventSystemSleep) ?? true
        preventDisplaySleep = try c.decodeIfPresent(Bool.self, forKey: .preventDisplaySleep) ?? false
        allowScreenSaverAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .allowScreenSaverAfter)
        dimDisplayAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .dimDisplayAfter)
        dimFloor = try c.decodeIfPresent(Double.self, forKey: .dimFloor) ?? 0
        simulateUserActivity = try c.decodeIfPresent(Bool.self, forKey: .simulateUserActivity) ?? false
    }
}
