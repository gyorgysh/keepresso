import Foundation
import EventKit

/// One event's occupied span, reduced to what the trigger needs. All-day
/// events are carried but never treated as "in progress": a birthday must not
/// keep the Mac awake for 24 hours.
public struct CalendarEventWindow: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var isAllDay: Bool

    public init(start: Date, end: Date, isAllDay: Bool = false) {
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

/// Abstraction over "is a calendar event in progress?" so the calendar trigger
/// can be tested without EventKit. Mirrors the other monitor seams.
public protocol CalendarMonitoring: AnyObject {
    var isEventInProgress: Bool { get }
}

/// Real backend over EventKit.
///
/// Querying the event store is TCC-gated (full calendar access) and not free,
/// while calendars change slowly, so this reuses ``SCUtilVPNMonitor``'s
/// stale-while-revalidate shape with a generous TTL: return a verdict computed
/// from the cached event windows immediately and refresh on a detached task
/// once the fetch goes stale. The verdict itself stays per-tick accurate
/// because containment is evaluated against the cached windows at read time;
/// the fetch looks slightly past the TTL so an event starting between
/// refreshes is already in the cache when its start arrives. Without the
/// access grant the fetch yields nothing and the trigger simply never fires;
/// the app surfaces the missing grant in Setup.
public final class EventKitCalendarMonitor: CalendarMonitoring {
    /// How far past the TTL each fetch looks, so events that begin before the
    /// next refresh are already cached.
    static let fetchHorizon: TimeInterval = 120

    private let ttl: TimeInterval
    private let now: () -> Date
    /// Produces the event windows around the current moment (`nil` when
    /// calendar access is missing). Injectable so the cache and the
    /// in-progress predicate can be unit-tested.
    private let fetch: @Sendable () -> [CalendarEventWindow]?
    private let lock = NSLock()
    private var cachedWindows: [CalendarEventWindow] = []
    private var lastFetch: Date?
    private var isRefreshing = false

    public init(
        ttl: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping @Sendable () -> [CalendarEventWindow]? = EventKitCalendarMonitor.fetchSystem
    ) {
        self.ttl = ttl
        self.now = now
        self.fetch = fetch
    }

    public var isEventInProgress: Bool {
        let (windows, shouldRefresh) = withLock { () -> ([CalendarEventWindow], Bool) in
            let isStale = lastFetch.map { now().timeIntervalSince($0) >= ttl } ?? true
            let shouldRefresh = isStale && !isRefreshing
            if shouldRefresh { isRefreshing = true }
            return (cachedWindows, shouldRefresh)
        }

        if shouldRefresh {
            Task.detached { [weak self] in
                guard let self else { return }
                let windows = self.fetch() ?? []
                self.withLock {
                    self.cachedWindows = windows
                    self.lastFetch = self.now()
                    self.isRefreshing = false
                }
            }
        }
        return Self.hasTimedEvent(in: windows, at: now())
    }

    /// Wraps ``lock`` in a synchronous call so the lock/unlock pair is never
    /// invoked directly from an async context (`NSLock` is `noasync`).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Pure predicate: a timed (non-all-day) event spans this moment. Start is
    /// inclusive, end exclusive, so back-to-back events hand over cleanly.
    static func hasTimedEvent(in windows: [CalendarEventWindow], at date: Date) -> Bool {
        windows.contains { !$0.isAllDay && $0.start <= date && date < $0.end }
    }

    /// The real fetch: events overlapping now through the fetch horizon, from
    /// every calendar. Returns `nil` without full calendar access (EventKit
    /// would silently return no events; the explicit `nil` keeps "no access"
    /// distinguishable from "free slot" for future use).
    @Sendable public static func fetchSystem() -> [CalendarEventWindow]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let start = Date()
        let predicate = store.predicateForEvents(
            withStart: start,
            end: start.addingTimeInterval(fetchHorizon),
            calendars: nil
        )
        return store.events(matching: predicate).map {
            CalendarEventWindow(start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay)
        }
    }
}

/// Fires while a timed calendar event is in progress: a scheduled session is
/// under way, so the Mac should stay awake.
public final class CalendarEventTrigger: Trigger {
    private let monitor: CalendarMonitoring

    public init(monitor: CalendarMonitoring = EventKitCalendarMonitor()) {
        self.monitor = monitor
    }

    public var label: String { "Calendar event in progress" }

    public func isSatisfied() -> Bool { monitor.isEventInProgress }
}
