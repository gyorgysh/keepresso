import Foundation

/// Persisted settings for automation wake sync: whether it's on, which
/// discovered automations the user has opted out of, and the timing of the wake
/// and the hold. Forgiving ``Codable`` like the other settings types so older or
/// newer saves round-trip.
public struct AutomationSyncConfig: Equatable, Codable, Sendable {
    /// Master switch. Off means Keepresso arms no wakes and holds for nothing.
    public var enabled: Bool
    /// ``ScheduledAutomation/id`` values the user has muted, so a specific task
    /// can be excluded without turning the whole feature off.
    public var mutedIDs: Set<String>
    /// How long to keep the Mac awake after a scheduled wake, in seconds. A
    /// scheduled agent can extend this by holding a lease; otherwise the Mac
    /// sleeps again when the window ends.
    public var holdSeconds: TimeInterval
    /// How early to wake before the run, in seconds, so the Mac is up and
    /// settled before it fires (schedulers also stagger their own starts).
    public var leadSeconds: TimeInterval

    public static let defaultHold: TimeInterval = 15 * 60
    public static let defaultLead: TimeInterval = 3 * 60

    public init(
        enabled: Bool = false,
        mutedIDs: Set<String> = [],
        holdSeconds: TimeInterval = defaultHold,
        leadSeconds: TimeInterval = defaultLead
    ) {
        self.enabled = enabled
        self.mutedIDs = mutedIDs
        self.holdSeconds = max(60, holdSeconds)
        self.leadSeconds = max(0, leadSeconds)
    }

    private enum CodingKeys: String, CodingKey { case enabled, mutedIDs, holdSeconds, leadSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mutedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .mutedIDs) ?? []
        holdSeconds = max(60, try c.decodeIfPresent(TimeInterval.self, forKey: .holdSeconds) ?? Self.defaultHold)
        leadSeconds = max(0, try c.decodeIfPresent(TimeInterval.self, forKey: .leadSeconds) ?? Self.defaultLead)
    }
}

/// Pure decisions for automation wake sync, over a discovered automation list
/// and the config. The app wires the readers and the wake/session machinery;
/// everything policy-shaped lives here so it's testable with plain values.
public enum AutomationSync {
    /// The automations Keepresso will actually wake for: the master switch is
    /// on, the source has them enabled, and the user hasn't muted them.
    public static func active(_ automations: [ScheduledAutomation], config: AutomationSyncConfig) -> [ScheduledAutomation] {
        guard config.enabled else { return [] }
        return automations.filter { $0.enabled && !config.mutedIDs.contains($0.id) }
    }

    /// Upcoming wakes across the active automations within `horizon`, sorted by
    /// wake time. Each wake is `leadSeconds` before its run.
    public static func upcomingWakes(
        _ automations: [ScheduledAutomation],
        config: AutomationSyncConfig,
        after now: Date,
        within horizon: TimeInterval,
        calendar: Calendar = .current
    ) -> [AutomationOccurrence] {
        AutomationWakePlan.upcomingOccurrences(
            active(automations, config: config), after: now, within: horizon,
            leadTime: config.leadSeconds, calendar: calendar)
    }

    /// The single next moment to wake the Mac across all active automations, or
    /// `nil` if none in the next year. This is what the armer installs.
    public static func nextWake(
        _ automations: [ScheduledAutomation],
        config: AutomationSyncConfig,
        after now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        upcomingWakes(automations, config: config, after: now, within: 366 * 86400, calendar: calendar).first?.wakeTime
    }

    /// The occurrence the Mac most likely just woke for, or `nil` if this wake
    /// wasn't ours. Used on `didWake` to decide whether to open a hold window:
    /// a run whose time sits within `tolerance` of now (allowing for the lead
    /// and the scheduler's stagger) counts as "we woke for this".
    public static func wakeMatch(
        _ automations: [ScheduledAutomation],
        config: AutomationSyncConfig,
        wokeAt now: Date,
        tolerance: TimeInterval = 5 * 60,
        calendar: Calendar = .current
    ) -> AutomationOccurrence? {
        let occurrences = AutomationWakePlan.upcomingOccurrences(
            active(automations, config: config),
            after: now.addingTimeInterval(-tolerance),
            within: config.leadSeconds + 2 * tolerance,
            leadTime: config.leadSeconds, calendar: calendar)
        return occurrences.min {
            abs($0.runTime.timeIntervalSince(now)) < abs($1.runTime.timeIntervalSince(now))
        }
    }
}
