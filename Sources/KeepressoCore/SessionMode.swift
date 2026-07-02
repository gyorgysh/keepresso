import Foundation

/// How long a keep-awake session should run.
public enum SessionMode: Hashable, Codable, Sendable {
    /// Stay awake until the user explicitly stops (or a trigger turns off).
    case indefinite

    /// Stay awake for a fixed duration, then stop automatically.
    case timed(duration: TimeInterval)

    /// The wall-clock interval after which a timed session should end, or `nil`
    /// for indefinite sessions.
    public var duration: TimeInterval? {
        switch self {
        case .indefinite: return nil
        case .timed(let duration): return duration
        }
    }

    /// A timed mode that runs until the next occurrence of a wall-clock time:
    /// later today if the time is still ahead, otherwise tomorrow ("until
    /// 18:00"). The duration is fixed at the moment this is computed, so
    /// compute it when the session starts, not ahead of time. `nil` for an
    /// out-of-range hour or minute.
    public static func until(
        hour: Int,
        minute: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SessionMode? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        guard let next = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: hour, minute: minute),
            matchingPolicy: .nextTime
        ) else { return nil }
        return .timed(duration: next.timeIntervalSince(now))
    }
}
