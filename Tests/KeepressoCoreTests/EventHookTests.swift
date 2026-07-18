import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Fakes

private final class FakeHookRunner: HookRunning {
    private(set) var ran: [HookAction] = []
    func run(_ action: HookAction) { ran.append(action) }
}

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

// MARK: - Classification

@Test func decisionKindsMapOntoHookEvents() {
    #expect(EventHookPolicy.hookEvents(for: .sessionStarted) == [.sessionStarted])
    #expect(EventHookPolicy.hookEvents(for: .sessionEnded) == [.sessionEnded])
    #expect(EventHookPolicy.hookEvents(for: .triggerFired) == [.triggerFired, .sessionStarted])
    #expect(EventHookPolicy.hookEvents(for: .triggerReleased) == [.triggerReleased, .sessionEnded])
    #expect(EventHookPolicy.hookEvents(for: .batteryPaused) == [.batteryPaused, .sessionEnded])
    #expect(EventHookPolicy.hookEvents(for: .thermalPaused) == [.thermalPaused, .sessionEnded])
    #expect(EventHookPolicy.hookEvents(for: .startRefused).isEmpty)
    #expect(EventHookPolicy.hookEvents(for: nil).isEmpty)
}

// MARK: - Dispatch

@MainActor
@Test func matchingHooksRunAndRespectDebounce() {
    let runner = FakeHookRunner()
    let clock = Clock()
    let dispatcher = EventHookDispatcher(runner: runner, now: { clock.now })
    let hook = EventHook(event: .sessionEnded, action: .runShortcut(name: "Ping"))
    dispatcher.hooks = [hook, EventHook(enabled: false, event: .sessionEnded, action: .shell(command: "echo no"))]

    dispatcher.handle(sessionEvent: SessionEvent(
        id: 0, date: clock.now, began: false, reason: "Timed session ended", kind: .sessionEnded
    ))
    #expect(runner.ran == [.runShortcut(name: "Ping")])

    // Same hook inside the debounce window is dropped.
    clock.advance(1)
    dispatcher.handle(sessionEvent: SessionEvent(
        id: 1, date: clock.now, began: false, reason: "again", kind: .sessionEnded
    ))
    #expect(runner.ran.count == 1)

    // After the window, it fires again.
    clock.advance(EventHookDispatcher.debounce)
    dispatcher.handle(sessionEvent: SessionEvent(
        id: 2, date: clock.now, began: false, reason: "later", kind: .sessionEnded
    ))
    #expect(runner.ran.count == 2)
}

@MainActor
@Test func suspendedDispatcherRunsNothing() {
    let runner = FakeHookRunner()
    let dispatcher = EventHookDispatcher(runner: runner)
    dispatcher.hooks = [EventHook(event: .sessionStarted, action: .webhook(url: "https://example.test/h"))]
    dispatcher.isSuspended = true
    dispatcher.fire(.sessionStarted)
    #expect(runner.ran.isEmpty)
}

@MainActor
@Test func triggerReleaseAlsoFiresSessionEndedHooks() {
    let runner = FakeHookRunner()
    let dispatcher = EventHookDispatcher(runner: runner)
    dispatcher.hooks = [
        EventHook(event: .triggerReleased, action: .shell(command: "a")),
        EventHook(event: .sessionEnded, action: .shell(command: "b")),
    ]
    dispatcher.handle(sessionEvent: SessionEvent(
        id: 0, date: Date(), began: false, reason: "Trigger conditions ended", kind: .triggerReleased
    ))
    #expect(runner.ran == [.shell(command: "a"), .shell(command: "b")])
}

// MARK: - Persistence

@Test func eventHooksRoundTripThroughSettings() throws {
    var settings = KeepressoSettings.default
    settings.eventHooks = [
        EventHook(event: .agentWentIdle, action: .runShortcut(name: "Agent done")),
        EventHook(enabled: false, event: .thermalStageChanged, action: .webhook(url: "https://ntfy.sh/x")),
    ]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.eventHooks == settings.eventHooks)
}

@Test func settingsWithoutEventHooksDecodeEmpty() throws {
    let empty = try JSONDecoder().decode(KeepressoSettings.self, from: Data("{}".utf8))
    #expect(empty.eventHooks.isEmpty)
}
