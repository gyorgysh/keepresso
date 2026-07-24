import Foundation

/// Persisted settings for automation wake sync: whether it's on, which
/// discovered automations the user has opted out of, and the timing of the wake
/// and the hold. Forgiving ``Codable`` like the other settings types so older or
/// newer saves round-trip.
public struct AutomationSyncConfig: Equatable, Codable, Sendable {
    /// Master switch. Off means Keepresso arms no wakes and holds for nothing.
    public var enabled: Bool
    /// Which sources Keepresso actually wakes for. A discovered source is always
    /// shown, but until the user turns it on here it is never woken for, so no
    /// platform is forced on and a tool the user does not use never plans wakes.
    /// Empty by default (opt in per platform).
    public var enabledSources: Set<ScheduledAutomation.Source>
    /// ``ScheduledAutomation/id`` values the user has muted, so a specific task
    /// can be excluded even while its source is on.
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
        enabledSources: Set<ScheduledAutomation.Source> = [],
        mutedIDs: Set<String> = [],
        holdSeconds: TimeInterval = defaultHold,
        leadSeconds: TimeInterval = defaultLead
    ) {
        self.enabled = enabled
        self.enabledSources = enabledSources
        self.mutedIDs = mutedIDs
        self.holdSeconds = max(60, holdSeconds)
        self.leadSeconds = max(0, leadSeconds)
    }

    private enum CodingKeys: String, CodingKey { case enabled, enabledSources, mutedIDs, holdSeconds, leadSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        enabledSources = try c.decodeIfPresent(Set<ScheduledAutomation.Source>.self, forKey: .enabledSources) ?? []
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
    /// on, the run's source is turned on, the source has the run enabled, and the
    /// user hasn't muted it.
    public static func active(_ automations: [ScheduledAutomation], config: AutomationSyncConfig) -> [ScheduledAutomation] {
        guard config.enabled else { return [] }
        return automations.filter {
            $0.enabled
                && config.enabledSources.contains($0.source)
                && !config.mutedIDs.contains($0.id)
        }
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

    /// The one-shot wake to actually install into the single system slot: the
    /// earlier of a still-future manual wake and the next automation wake, or
    /// `nil` if neither applies. A past manual wake is treated as absent (pmset
    /// can't install it), so once it fires, the automation wake it was masking
    /// becomes the effective one and the caller re-arms it.
    public static func effectiveOneShot(manual: Date?, automationWake: Date?, now: Date) -> Date? {
        let manualFuture = manual.flatMap { $0 > now ? $0 : nil }
        guard let auto = automationWake, auto > now else { return manualFuture }
        return manualFuture.map { min($0, auto) } ?? auto
    }

    /// Whether to keep the last-known automations rather than adopt a new, empty
    /// discovery result. Discovery reads small files a scheduler may be
    /// mid-rewrite, so a one-off empty read must not drop armed wakes or make a
    /// wake handler miss its hold. A genuinely emptied source still takes effect
    /// once `maxEmptyStreak` consecutive empty reads have gone by.
    public static func shouldKeepLastKnown(
        newIsEmpty: Bool, hadAutomations: Bool, emptyStreak: Int, maxEmptyStreak: Int
    ) -> Bool {
        newIsEmpty && hadAutomations && emptyStreak < maxEmptyStreak
    }
}
