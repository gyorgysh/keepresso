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

    /// Also report user activity while the session runs, so software with its
    /// own idle timeout (meetings, chat, remote desktop, VDI, cloud gaming,
    /// and many others) keeps the user present. A plain power assertion does
    /// not reach those. Off by default. See ``ActivitySimulating``.
    public var simulateUserActivity: Bool

    /// How keep-active reports activity when ``simulateUserActivity`` is on.
    /// Defaults to the prompt-free power/warp path. HID methods need
    /// Accessibility, requested only when the user picks one.
    public var activitySimulationMethod: ActivitySimulationMethod

    /// Carbon virtual key code for ``ActivitySimulationMethod/specifiedKey``.
    /// Ignored for the other methods. `nil` until the user records a key,
    /// and the poke then falls back to ``ActivityPokeKind/powerWarp``.
    public var activitySimulationKeyCode: Int?

    /// Modifiers sent with ``activitySimulationKeyCode`` (stored as the
    /// ``ActivityKeyModifiers`` raw value). Empty by default. Ignored for the
    /// other methods and when the recorded key is itself a modifier.
    public var activitySimulationKeyModifiers: ActivityKeyModifiers

    /// Idle-only keep-active mode. When set, the poke only fires once the
    /// user has been idle this many minutes, and never while a game is
    /// frontmost (a game already reports them as present to everything
    /// watching). `nil` (the default) keeps the always-on behavior: poke
    /// once past the few-seconds activity threshold.
    public var activityPokeIdleMinutes: Int?

    /// Scope keep-active to running sessions (the default). Turned off, the
    /// poke also runs while nothing is brewing, so the user stays present
    /// between sessions too. Each poke counts as user activity to macOS as
    /// well, so the Mac then won't idle-sleep while the option is on. Safety
    /// pauses (battery, heat) still silence it.
    public var activityOnlyWhileBrewing: Bool

    public init(
        preventSystemSleep: Bool = true,
        preventDisplaySleep: Bool = false,
        allowScreenSaverAfter: TimeInterval? = nil,
        dimDisplayAfter: TimeInterval? = nil,
        dimFloor: Double = 0,
        simulateUserActivity: Bool = false,
        activitySimulationMethod: ActivitySimulationMethod = .powerWarp,
        activitySimulationKeyCode: Int? = nil,
        activitySimulationKeyModifiers: ActivityKeyModifiers = [],
        activityPokeIdleMinutes: Int? = nil,
        activityOnlyWhileBrewing: Bool = true
    ) {
        self.preventSystemSleep = preventSystemSleep
        self.preventDisplaySleep = preventDisplaySleep
        self.allowScreenSaverAfter = allowScreenSaverAfter
        self.dimDisplayAfter = dimDisplayAfter
        self.dimFloor = dimFloor
        self.simulateUserActivity = simulateUserActivity
        self.activitySimulationMethod = activitySimulationMethod
        self.activitySimulationKeyCode = activitySimulationKeyCode
        self.activitySimulationKeyModifiers = activitySimulationKeyModifiers
        self.activityPokeIdleMinutes = activityPokeIdleMinutes
        self.activityOnlyWhileBrewing = activityOnlyWhileBrewing
    }

    /// The poke to perform for the current method. A specified key with no
    /// recorded code falls back to the prompt-free path.
    public var activityPokeKind: ActivityPokeKind {
        switch activitySimulationMethod {
        case .powerWarp:
            return .powerWarp
        case .f15:
            return .key(ActivitySimulationMethod.f15KeyCode)
        case .shift:
            return .key(ActivitySimulationMethod.shiftKeyCode)
        case .specifiedKey:
            guard let code = activitySimulationKeyCode,
                  code >= 0, code <= Int(UInt16.max) else {
                return .powerWarp
            }
            return .key(UInt16(code), modifiers: activitySimulationEffectiveKeyModifiers)
        case .mouseMove:
            return .mouseMove
        }
    }

    /// The modifiers the specified key is actually sent with. A modifier key
    /// already carries its own flag, and adding others to it would post a
    /// chord nobody recorded, so it gets none.
    public var activitySimulationEffectiveKeyModifiers: ActivityKeyModifiers {
        guard let code = activitySimulationKeyCode,
              !ActivityKeyModifiers.isModifierKey(code) else { return [] }
        return activitySimulationKeyModifiers.intersection(.all)
    }

    /// The default "brew": keep the system awake, let the screen do its thing.
    public static let `default` = SleepPreventionOptions()

    private enum CodingKeys: String, CodingKey {
        case preventSystemSleep, preventDisplaySleep, allowScreenSaverAfter
        case dimDisplayAfter, dimFloor, simulateUserActivity
        case activitySimulationMethod, activitySimulationKeyCode, activitySimulationKeyModifiers
        case activityPokeIdleMinutes, activityOnlyWhileBrewing
    }

    /// Forgiving decoder: each field falls back to its default when absent
    /// (a blob saved by an older build) or unreadable (a wrong type, or an
    /// enum case only a newer build knows, read after a downgrade). Options
    /// sit inside the one settings blob, so a throw here would reset the
    /// user's whole configuration, not just this field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preventSystemSleep = (try? c.decodeIfPresent(Bool.self, forKey: .preventSystemSleep)) ?? true
        preventDisplaySleep = (try? c.decodeIfPresent(Bool.self, forKey: .preventDisplaySleep)) ?? false
        allowScreenSaverAfter = Self.sanitizedInterval(
            try? c.decodeIfPresent(TimeInterval.self, forKey: .allowScreenSaverAfter))
        dimDisplayAfter = Self.sanitizedInterval(
            try? c.decodeIfPresent(TimeInterval.self, forKey: .dimDisplayAfter))
        dimFloor = min(max((try? c.decodeIfPresent(Double.self, forKey: .dimFloor)) ?? 0, 0), 1)
        simulateUserActivity = (try? c.decodeIfPresent(Bool.self, forKey: .simulateUserActivity)) ?? false
        // Raw string, not the enum, so an unknown method falls back here.
        activitySimulationMethod = (try? c.decodeIfPresent(String.self, forKey: .activitySimulationMethod))
            .flatMap(ActivitySimulationMethod.init(rawValue:)) ?? .powerWarp
        activitySimulationKeyCode = try? c.decodeIfPresent(Int.self, forKey: .activitySimulationKeyCode)
        activitySimulationKeyModifiers = ((try? c.decodeIfPresent(Int.self, forKey: .activitySimulationKeyModifiers))
            .map(ActivityKeyModifiers.init(rawValue:)) ?? []).intersection(.all)
        activityPokeIdleMinutes = (try? c.decodeIfPresent(Int.self, forKey: .activityPokeIdleMinutes))
            .map { min(max($0, 0), 24 * 60) }
        activityOnlyWhileBrewing = (try? c.decodeIfPresent(Bool.self, forKey: .activityOnlyWhileBrewing)) ?? true
    }

    /// A decoded idle threshold: finite, positive, and bounded to a real
    /// session length (an imported `1e308` would otherwise trap in display
    /// conversions downstream).
    private static func sanitizedInterval(_ raw: TimeInterval?) -> TimeInterval? {
        raw.flatMap { $0.isFinite && $0 > 0 ? min($0, SessionMode.maxTimedMinutes * 60) : nil }
    }
}
