import Foundation
import Security

/// The session state the app shares with the widget extension. Deliberately
/// tiny: the control needs on/off today; richer state (say, a countdown) can
/// extend this Codable struct without breaking older readers.
public struct SharedSessionState: Codable, Equatable, Sendable {
    public var isActive: Bool

    public init(isActive: Bool) {
        self.isActive = isActive
    }
}

/// The App Group channel between the app and the widget extension.
///
/// The widget's intent runs in the sandboxed appex process, which can't touch
/// the app's memory, so the two sides talk through the group's `UserDefaults`
/// plus a Darwin notification as the doorbell:
///
/// - App → widget: ``writeState(_:to:)`` after every session change, then the
///   app asks WidgetKit to reload the control, whose value provider calls
///   ``readState(from:)``.
/// - Widget → app: the toggle's intent calls ``writeCommand(desiredActive:at:to:)``
///   and ``postCommandNotification()``; the running app observes the Darwin
///   notification and consumes the command. The intent also opens the app, so
///   a not-yet-running app consumes it at launch instead; the freshness window
///   keeps a stale command from firing days later.
///
/// Everything takes `UserDefaults` and a clock explicitly so it's unit-tested
/// against a scratch suite. The group id is **not** hardcoded: the entitlements
/// declare `$(TeamIdentifierPrefix)sh.gyorgy.keepresso` (expanded at signing,
/// keeping the Team ID out of the repo), and each process reads the expanded
/// value back from its own code signature at runtime, so both sides agree on
/// the literal suite name whichever team signed them.
public enum WidgetBridge {
    /// The shared App Group, read from this process's own signed entitlements.
    /// `nil` in processes without the entitlement (unsigned dev builds, unit
    /// tests), where the bridge quietly stays inert.
    public static let appGroupID: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String]
        else { return nil }
        return groups.first
    }()

    /// The group's `UserDefaults`, or `nil` when the entitlement (or the
    /// container) is unavailable.
    public static func groupDefaults() -> UserDefaults? {
        appGroupID.flatMap { UserDefaults(suiteName: $0) }
    }
    /// The Control Center control's kind, for targeted reloads.
    public static let controlKind = "sh.gyorgy.keepresso.keep-awake"
    /// The Darwin notification the appex posts after writing a command.
    public static let commandNotificationName = "sh.gyorgy.keepresso.widget-command"

    /// A pending command older than this is dropped: it means the app wasn't
    /// there to hear the doorbell and the launch it triggered never happened,
    /// so acting on it much later would surprise the user.
    public static let commandFreshness: TimeInterval = 30

    static let stateKey = "widget.sessionState"
    static let commandKey = "widget.desiredActive"
    static let commandStampKey = "widget.commandStamp"

    // MARK: - App → widget (session state)

    public static func writeState(_ state: SharedSessionState, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    public static func readState(from defaults: UserDefaults) -> SharedSessionState? {
        guard let data = defaults.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(SharedSessionState.self, from: data)
    }

    // MARK: - Widget → app (toggle command)

    public static func writeCommand(
        desiredActive: Bool,
        at date: Date = Date(),
        to defaults: UserDefaults
    ) {
        defaults.set(desiredActive, forKey: commandKey)
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: commandStampKey)
    }

    /// Take the pending command, clearing it either way (a command fires at
    /// most once). Returns `nil` when there is none or it has gone stale.
    public static func consumeCommand(
        from defaults: UserDefaults,
        now: Date = Date()
    ) -> Bool? {
        defer {
            defaults.removeObject(forKey: commandKey)
            defaults.removeObject(forKey: commandStampKey)
        }
        guard defaults.object(forKey: commandKey) != nil else { return nil }
        let stamp = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: commandStampKey))
        guard now.timeIntervalSince(stamp) < commandFreshness else { return nil }
        return defaults.bool(forKey: commandKey)
    }

    /// Ring the doorbell: tell a running app a command is waiting. Darwin
    /// notifications carry no payload and cross the sandbox boundary freely.
    public static func postCommandNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(commandNotificationName as CFString),
            nil,
            nil,
            true
        )
    }
}
