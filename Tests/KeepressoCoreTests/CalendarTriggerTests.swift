import Testing
import Foundation
@testable import KeepressoCore

private final class FakeCalendarMonitor: CalendarMonitoring {
    var inProgress: Bool
    init(inProgress: Bool) { self.inProgress = inProgress }
    var isEventInProgress: Bool { inProgress }
}

private func minutes(_ m: Double) -> Date {
    Date(timeIntervalSinceReferenceDate: m * 60)
}

@Test func calendarTriggerFollowsMonitorState() {
    let monitor = FakeCalendarMonitor(inProgress: true)
    let trigger = CalendarEventTrigger(monitor: monitor)
    #expect(trigger.isSatisfied())

    monitor.inProgress = false
    #expect(!trigger.isSatisfied())
}

@Test func calendarRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.calendarEvent
    #expect(rule.label == "Calendar event in progress")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}

@Test func factoryBuildsACalendarTrigger() {
    let monitor = FakeCalendarMonitor(inProgress: true)
    let factory = TriggerFactory(calendar: monitor)
    let engine = factory.makeEngine(from: RuleSet(rules: [.calendarEvent]))
    #expect(engine.isSatisfied())
}

// MARK: - The in-progress predicate

@Test func timedEventSpanningNowIsInProgress() {
    let windows = [CalendarEventWindow(start: minutes(0), end: minutes(30))]
    #expect(EventKitCalendarMonitor.hasTimedEvent(in: windows, at: minutes(10)))
    #expect(!EventKitCalendarMonitor.hasTimedEvent(in: windows, at: minutes(40)))
    #expect(!EventKitCalendarMonitor.hasTimedEvent(in: [], at: minutes(10)))
}

@Test func startIsInclusiveAndEndExclusive() {
    // Back-to-back events must hand over cleanly, without double-counting the
    // shared boundary.
    let windows = [CalendarEventWindow(start: minutes(0), end: minutes(30))]
    #expect(EventKitCalendarMonitor.hasTimedEvent(in: windows, at: minutes(0)))
    #expect(!EventKitCalendarMonitor.hasTimedEvent(in: windows, at: minutes(30)))
}

@Test func allDayEventsNeverCountAsInProgress() {
    // A birthday must not keep the Mac awake for 24 hours.
    let allDay = [CalendarEventWindow(start: minutes(-600), end: minutes(840), isAllDay: true)]
    #expect(!EventKitCalendarMonitor.hasTimedEvent(in: allDay, at: minutes(10)))
}

// MARK: - Stale-while-revalidate cache

@Test func calendarMonitorServesCachedWindowsAndRefreshesInBackground() async {
    let stub = CalendarFetchStub(windows: [CalendarEventWindow(start: minutes(0), end: minutes(30))])
    let clock = CalendarTestClock()
    let monitor = EventKitCalendarMonitor(ttl: 60, now: { clock.now }, fetch: stub.fetch)

    // First read: nothing cached yet, kicks off the background fetch.
    #expect(!monitor.isEventInProgress)
    #expect(await calendarEventually { monitor.isEventInProgress })

    // Within the TTL, reads reuse the cached windows without refetching, and
    // containment stays per-tick accurate: past the event's end the verdict
    // flips even though the cache is still fresh.
    clock.advance(10 * 60)
    #expect(monitor.isEventInProgress)
    clock.advance(25 * 60)
    #expect(stub.callCount == 1)

    // Past the TTL the refresh lands in the background.
    stub.windows = []
    _ = monitor.isEventInProgress
    #expect(await calendarEventually { stub.callCount == 2 })
}

@Test func missingCalendarAccessReadsAsNoEvents() async {
    let stub = CalendarFetchStub(windows: nil)
    let clock = CalendarTestClock()
    let monitor = EventKitCalendarMonitor(ttl: 60, now: { clock.now }, fetch: stub.fetch)

    #expect(!monitor.isEventInProgress)
    #expect(await calendarEventually { stub.callCount == 1 })
    #expect(!monitor.isEventInProgress)
}

// MARK: - Test doubles (mirroring VPNTriggerTests' thread-safe stubs)

private final class CalendarFetchStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _windows: [CalendarEventWindow]?
    private var _callCount = 0

    init(windows: [CalendarEventWindow]?) { _windows = windows }

    var callCount: Int { lock.withLock { _callCount } }
    var windows: [CalendarEventWindow]? {
        get { lock.withLock { _windows } }
        set { lock.withLock { _windows = newValue } }
    }

    func fetch() -> [CalendarEventWindow]? {
        lock.withLock {
            _callCount += 1
            return _windows
        }
    }
}

private final class CalendarTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSinceReferenceDate: 0)

    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private func calendarEventually(_ condition: @escaping () -> Bool) async -> Bool {
    for _ in 0 ..< 400 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
