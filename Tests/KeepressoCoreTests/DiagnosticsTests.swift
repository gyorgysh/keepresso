import Testing
import Foundation
@testable import KeepressoCore

// The controller (and its log) are @MainActor; these tests mirror
// SessionControllerTests' setup with a fake assertion backend and a movable
// clock.

private final class LogFakeAssertions: PowerAsserting {
    var held: Set<PowerAssertionKind> = []
    func apply(_ kinds: Set<PowerAssertionKind>, reason: String) { held = kinds }
}

@MainActor
private func makeController(now: @escaping () -> Date) -> SessionController {
    SessionController(assertions: LogFakeAssertions(), now: now)
}

@Test @MainActor func logRecordsManualStartAndStop() {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let session = makeController(now: { clock })

    session.start(mode: .indefinite)
    clock = clock.addingTimeInterval(60)
    session.stop()

    let events = session.log.events
    #expect(events.count == 2)
    #expect(events[0].began && events[0].reason == "Started manually")
    #expect(!events[1].began && events[1].reason == "Stopped manually")
    #expect(events[1].date.timeIntervalSince(events[0].date) == 60)
}

@Test @MainActor func logRecordsCommandCauseAndRestart() {
    let session = makeController(now: { Date(timeIntervalSinceReferenceDate: 0) })

    session.start(mode: .indefinite, cause: .command)
    session.start(mode: .timed(duration: 60), cause: .manual) // restart while active
    session.stop(cause: .command)

    let reasons = session.log.events.map(\.reason)
    #expect(reasons == ["Started by a command", "Restarted manually", "Stopped by a command"])
}

@Test @MainActor func idempotentStopDoesNotSpamTheLog() {
    let session = makeController(now: { Date(timeIntervalSinceReferenceDate: 0) })
    session.stop()
    session.stop()
    #expect(session.log.events.isEmpty)
}

@Test @MainActor func logRecordsTimedExpiry() {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let session = makeController(now: { clock })

    session.start(mode: .timed(duration: 30))
    clock = clock.addingTimeInterval(31)
    session.reconcile(now: clock)

    #expect(session.log.events.last?.reason == "Timed session ended")
    #expect(session.log.events.last?.began == false)
}

@Test @MainActor func logRecordsBatteryPause() {
    let session = makeController(now: { Date(timeIntervalSinceReferenceDate: 0) })
    session.pauseBelowBatteryPercent = 20

    session.start(mode: .indefinite)
    session.reconcile(systemIdleSeconds: 0, batteryPercent: 15)

    #expect(session.log.events.last?.reason == "Paused, battery below 20%")
}

@Test @MainActor func logRecordsTriggerFlipsWithDescriberDetail() {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let session = makeController(now: { clock })

    final class Gate: TriggerEvaluating {
        var satisfied = false
        func isSatisfied() -> Bool { satisfied }
    }
    let gate = Gate()
    session.triggerGate = gate
    session.triggerDescriber = { gate.satisfied ? "Camera in use" : nil }

    gate.satisfied = true
    session.reconcile(now: clock)
    clock = clock.addingTimeInterval(10)
    gate.satisfied = false
    session.reconcile(now: clock)

    let events = session.log.events
    #expect(events.count == 2)
    #expect(events[0].reason == "Triggers: Camera in use")
    #expect(events[1].reason == "Trigger conditions ended")
}

@Test @MainActor func logIsBoundedToItsCapacity() {
    let log = DecisionLog()
    let epoch = Date(timeIntervalSinceReferenceDate: 0)
    for index in 0 ..< (DecisionLog.capacity + 25) {
        log.record(began: index.isMultiple(of: 2), reason: "event \(index)", at: epoch)
    }
    #expect(log.events.count == DecisionLog.capacity)
    #expect(log.events.first?.reason == "event 25") // oldest fell off
    #expect(log.events.last?.reason == "event \(DecisionLog.capacity + 24)")
}

@Test func assertionEffectMapsKnownTypesAndHidesBookkeeping() {
    func info(_ type: String) -> PowerAssertionInfo {
        PowerAssertionInfo(id: "1", pid: 1, processName: "test", type: type, name: "n")
    }
    #expect(info("PreventUserIdleDisplaySleep").effect == "Preventing display sleep")
    #expect(info("PreventUserIdleSystemSleep").effect == "Preventing system sleep")
    #expect(info("NoIdleSleepAssertion").effect == "Preventing system sleep")
    #expect(info("SomeInternalBookkeepingType").effect == nil)
}

@Test func realAssertionListerReadsWithoutCrashing() {
    // Read-only sweep of powerd's live assertion list: contents vary by
    // machine, so just prove the plumbing returns and every row is coherent.
    let list = IOPMAssertionLister().current()
    for info in list {
        #expect(!info.processName.isEmpty)
        #expect(!info.type.isEmpty)
    }
}
