import Foundation

/// Everything Keepresso persists across launches.
public struct KeepressoSettings: Codable, Equatable, Sendable {
    /// What to keep awake (system / display / screen-saver yield).
    public var options: SleepPreventionOptions
    /// The duration to use when a manual session starts.
    public var defaultMode: SessionMode
    /// Whether live triggers gate the session (vs. pure manual toggle).
    public var triggersEnabled: Bool
    /// The persisted trigger configuration.
    public var ruleSet: RuleSet
    /// Fire a "still brewing" reminder after this many seconds of an active
    /// session, or `nil` (the default) to never remind.
    public var reminderAfter: TimeInterval?
    /// Whether the reminder repeats every ``reminderAfter`` (vs. firing once).
    public var reminderRepeats: Bool
    /// Whether the reminder also plays a sound.
    public var reminderSound: Bool
    /// Post a notification when a session ends on its own. Off by default.
    public var notifyOnEnd: Bool
    /// What to do to the Mac when a session ends on its own. None by default.
    public var endAction: SessionEndAction
    /// Keep a chosen disk/volume spun up, or `nil` (the default) for off.
    public var diskKeepAlive: DiskKeepAliveConfig?
    /// Experimental headless virtual display, or `nil` (the default) for off.
    public var virtualDisplay: VirtualDisplayConfig?
    /// Force-stop an active session (and hold off reactivating) once battery
    /// charge drops below this percentage, or `nil` (the default) for off.
    public var pauseBelowBatteryPercent: Int?
    /// Whether the menu-bar icon shows a live countdown for timed sessions.
    public var showCountdownInMenuBar: Bool
    /// Whether the AWDL watchdog starts and stops with a gaming trigger
    /// (see ``AWDLWatchdogController/autoWithGaming``).
    public var awdlAutoWithGaming: Bool
    /// A system-wide keyboard shortcut that toggles keep-awake, or `nil` (the
    /// default) for none.
    public var hotKey: HotKeyShortcut?
    /// Start a manual keep-awake session as soon as the app launches (when
    /// triggers aren't gating activation). Off by default.
    public var startOnLaunch: Bool
    /// Saved trigger-rule bundles a user can apply in one action. Seeded with
    /// ``Preset/builtIns`` on first launch; a user may add or remove any of them.
    public var presets: [Preset]
    /// The built-in preset ids that have already been offered to this user, so
    /// ``seedNewBuiltInPresets()`` adds a new built-in exactly once and never
    /// resurrects one the user deleted.
    public var seededPresetIDs: [String]

    public init(
        options: SleepPreventionOptions = .default,
        defaultMode: SessionMode = .indefinite,
        triggersEnabled: Bool = false,
        ruleSet: RuleSet = .empty,
        reminderAfter: TimeInterval? = nil,
        reminderRepeats: Bool = false,
        reminderSound: Bool = true,
        notifyOnEnd: Bool = false,
        endAction: SessionEndAction = .none,
        diskKeepAlive: DiskKeepAliveConfig? = nil,
        virtualDisplay: VirtualDisplayConfig? = nil,
        pauseBelowBatteryPercent: Int? = nil,
        showCountdownInMenuBar: Bool = false,
        awdlAutoWithGaming: Bool = false,
        hotKey: HotKeyShortcut? = nil,
        startOnLaunch: Bool = false,
        presets: [Preset] = Preset.builtIns,
        seededPresetIDs: [String] = Preset.builtIns.map(\.id)
    ) {
        self.options = options
        self.defaultMode = defaultMode
        self.triggersEnabled = triggersEnabled
        self.ruleSet = ruleSet
        self.reminderAfter = reminderAfter
        self.reminderRepeats = reminderRepeats
        self.reminderSound = reminderSound
        self.notifyOnEnd = notifyOnEnd
        self.endAction = endAction
        self.diskKeepAlive = diskKeepAlive
        self.virtualDisplay = virtualDisplay
        self.pauseBelowBatteryPercent = pauseBelowBatteryPercent
        self.showCountdownInMenuBar = showCountdownInMenuBar
        self.awdlAutoWithGaming = awdlAutoWithGaming
        self.hotKey = hotKey
        self.startOnLaunch = startOnLaunch
        self.presets = presets
        self.seededPresetIDs = seededPresetIDs
    }

    /// Append any built-in preset this user has never been offered. Called once
    /// at launch: new built-ins added in an update reach existing users, while
    /// ones they deleted stay gone (their ids are already recorded as seeded).
    public mutating func seedNewBuiltInPresets() {
        for preset in Preset.builtIns where !seededPresetIDs.contains(preset.id) {
            seededPresetIDs.append(preset.id)
            if !presets.contains(where: { $0.id == preset.id }) {
                presets.append(preset)
            }
        }
    }

    /// Built-in presets not currently in ``presets``, the ones a user has
    /// deleted and could bring back with ``restoreMissingBuiltInPresets()``.
    /// Matched by id, so a built-in the user only renamed or edited still
    /// counts as present. Empty when every built-in is there.
    public var missingBuiltInPresets: [Preset] {
        Preset.builtIns.filter { built in !presets.contains { $0.id == built.id } }
    }

    /// Re-add every built-in preset the user has deleted, in built-in order,
    /// and mark them seeded so later seeding stays consistent. Unlike
    /// ``seedNewBuiltInPresets()`` this deliberately resurrects deleted
    /// built-ins: it's the manual "restore defaults" action, not the one-time
    /// launch seed. User-created presets and renamed built-ins are untouched.
    /// Returns the presets restored (empty if none were missing).
    @discardableResult
    public mutating func restoreMissingBuiltInPresets() -> [Preset] {
        let missing = missingBuiltInPresets
        for preset in missing {
            presets.append(preset)
            if !seededPresetIDs.contains(preset.id) { seededPresetIDs.append(preset.id) }
        }
        return missing
    }

    /// Forgiving decoder: every field falls back to its default when absent, so
    /// adding settings doesn't discard a user's older saved configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        options = try c.decodeIfPresent(SleepPreventionOptions.self, forKey: .options) ?? .default
        defaultMode = try c.decodeIfPresent(SessionMode.self, forKey: .defaultMode) ?? .indefinite
        triggersEnabled = try c.decodeIfPresent(Bool.self, forKey: .triggersEnabled) ?? false
        ruleSet = try c.decodeIfPresent(RuleSet.self, forKey: .ruleSet) ?? .empty
        reminderAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .reminderAfter)
        reminderRepeats = try c.decodeIfPresent(Bool.self, forKey: .reminderRepeats) ?? false
        reminderSound = try c.decodeIfPresent(Bool.self, forKey: .reminderSound) ?? true
        notifyOnEnd = try c.decodeIfPresent(Bool.self, forKey: .notifyOnEnd) ?? false
        endAction = try c.decodeIfPresent(SessionEndAction.self, forKey: .endAction) ?? .none
        diskKeepAlive = try c.decodeIfPresent(DiskKeepAliveConfig.self, forKey: .diskKeepAlive)
        virtualDisplay = try c.decodeIfPresent(VirtualDisplayConfig.self, forKey: .virtualDisplay)
        pauseBelowBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .pauseBelowBatteryPercent)
        showCountdownInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showCountdownInMenuBar) ?? false
        awdlAutoWithGaming = try c.decodeIfPresent(Bool.self, forKey: .awdlAutoWithGaming) ?? false
        hotKey = try c.decodeIfPresent(HotKeyShortcut.self, forKey: .hotKey)
        startOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .startOnLaunch) ?? false
        presets = try c.decodeIfPresent([Preset].self, forKey: .presets) ?? Preset.builtIns
        // Settings saved before seeding was tracked (1.2.x and earlier) had
        // exactly the original three built-ins seeded; assuming that set means
        // only genuinely new built-ins get appended for those users.
        seededPresetIDs = try c.decodeIfPresent([String].self, forKey: .seededPresetIDs)
            ?? Preset.preSeedTrackingBuiltInIDs
    }

    /// First-launch defaults: keep system awake, no triggers.
    public static let `default` = KeepressoSettings()
}

/// A persisted keyboard shortcut: a virtual key code plus modifier flags.
///
/// Stored in the AppKit representation (`NSEvent`'s virtual `keyCode` and the
/// device-independent `modifierFlags` raw value) so it survives round-trips
/// without pulling Carbon into `KeepressoCore`; the app converts to Carbon
/// modifiers when it registers the hotkey.
public struct HotKeyShortcut: Codable, Equatable, Sendable {
    /// The hardware-independent virtual key code (`NSEvent.keyCode`).
    public var keyCode: Int
    /// The device-independent modifier-flags raw value
    /// (`NSEvent.ModifierFlags.rawValue`), masked to command/option/control/shift.
    public var modifierFlags: Int

    public init(keyCode: Int, modifierFlags: Int) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
}

/// Persistence seam for ``KeepressoSettings``, mirrors the other system seams
/// so the app wires the real store and tests use an in-memory fake.
public protocol SettingsStore: AnyObject {
    /// Load saved settings, or ``KeepressoSettings/default`` if none/corrupt.
    func load() -> KeepressoSettings
    /// Persist settings; failures are swallowed (a lost write is non-fatal).
    func save(_ settings: KeepressoSettings)
}

/// Real store backed by `UserDefaults`, encoding settings as JSON under a single
/// versioned key.
public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "sh.gyorgy.keepresso.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> KeepressoSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(KeepressoSettings.self, from: data)
        else { return .default }
        return settings
    }

    public func save(_ settings: KeepressoSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
