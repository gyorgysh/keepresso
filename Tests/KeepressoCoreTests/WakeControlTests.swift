import Testing
import Foundation
@testable import KeepressoCore

private let base = Date(timeIntervalSince1970: 4_000_000)
private let reqId = "cccccccc-1111-2222-3333-444444444444"

private func request(
    oneShot: Date? = nil,
    repeatDays: String? = nil,
    repeatTime: String? = nil
) -> AutomationWakeRequest {
    AutomationWakeRequest(
        requestId: reqId, oneShot: oneShot,
        repeatDays: repeatDays, repeatTime: repeatTime, requestedAt: base
    )
}

// MARK: - Adjudication

@Test func wakeAdjudicationAcceptsSaneRequests() throws {
    // A one-shot an hour out.
    let oneShot = AutomationWakeControl.adjudicate(
        request(oneShot: base.addingTimeInterval(3_600)), now: base)
    guard case .apply(let config?) = oneShot else {
        Issue.record("expected an applied config")
        return
    }
    #expect(config.oneShot == base.addingTimeInterval(3_600))
    #expect(!config.repeatingEnabled)

    // A weekday-morning repeat.
    let repeating = AutomationWakeControl.adjudicate(
        request(repeatDays: "mtwrf", repeatTime: "07:30"), now: base)
    guard case .apply(let repeatConfig?) = repeating else {
        Issue.record("expected an applied config")
        return
    }
    #expect(repeatConfig.repeatingEnabled)
    #expect(repeatConfig.repeatWeekdays == "MTWRF")
    #expect(repeatConfig.repeatSecondsFromMidnight == 7 * 3600 + 30 * 60)

    // All nil: clear.
    #expect(AutomationWakeControl.adjudicate(request(), now: base) == .apply(nil))
}

@Test func wakeAdjudicationRejectsHostileRequests() {
    func isInvalid(_ verdict: AutomationWakeControl.Verdict) -> Bool {
        if case .invalid = verdict { return true }
        return false
    }
    // Past, too-soon, and absurdly far one-shots.
    #expect(isInvalid(AutomationWakeControl.adjudicate(
        request(oneShot: base.addingTimeInterval(-60)), now: base)))
    #expect(isInvalid(AutomationWakeControl.adjudicate(
        request(oneShot: base.addingTimeInterval(10)), now: base)))
    #expect(isInvalid(AutomationWakeControl.adjudicate(
        request(oneShot: base.addingTimeInterval(400 * 24 * 3600)), now: base)))
    // Repeating halves alone, junk days, junk time.
    #expect(isInvalid(AutomationWakeControl.adjudicate(request(repeatDays: "MTW"), now: base)))
    #expect(isInvalid(AutomationWakeControl.adjudicate(request(repeatTime: "07:30"), now: base)))
    #expect(isInvalid(AutomationWakeControl.adjudicate(
        request(repeatDays: "XYZ", repeatTime: "07:30"), now: base)))
    #expect(isInvalid(AutomationWakeControl.adjudicate(
        request(repeatDays: "MTW", repeatTime: "25:99"), now: base)))
    // A junk request id.
    var bad = request(oneShot: base.addingTimeInterval(3_600))
    bad.requestId = "../../etc"
    #expect(isInvalid(AutomationWakeControl.adjudicate(bad, now: base)))
}

// MARK: - Client ack loop

/// A scripted wake-client world mirroring LeaseClientTests' shape.
private final class World {
    var now = base
    var written: [AutomationWakeRequest] = []
    var pending: AutomationWakeRequest?
    var claimed: [String] = []
    var statusScript: [StatusSnapshot?] = [nil]
    var nudged = 0

    func client() -> WakeClient {
        WakeClient(
            now: { self.now },
            writeRequest: {
                self.written.append($0)
                self.pending = $0
            },
            claimRequest: { id in
                self.claimed.append(id)
                guard self.pending?.requestId == id else { return false }
                self.pending = nil
                return true
            },
            readStatus: {
                self.statusScript.count > 1
                    ? self.statusScript.removeFirst()
                    : self.statusScript[0]
            },
            nudgeApp: {
                self.nudged += 1
                return true
            },
            sleep: { self.now.addTimeInterval($0) },
            isPidAlive: { $0 == 77 },
            readSched: { SystemWakeState(repeatingSummary: "wakeorpoweron at 7:30AM MTWRF") },
            generateId: { reqId }
        )
    }
}

private func ack(_ outcome: String) -> StatusSnapshot {
    StatusSnapshot(
        isActive: false, pid: 77, writtenAt: base,
        lastWakeRequestId: reqId, lastWakeRequestOutcome: outcome
    )
}

@Test func wakeApplyWaitsForTheAppVerdict() {
    let world = World()
    world.statusScript = [nil, ack("applied")]

    let outcome = world.client().apply(
        oneShot: base.addingTimeInterval(3_600), repeatDays: nil, repeatTime: nil)
    #expect(outcome.exitCode == 0)
    #expect(world.nudged == 1)
    #expect(world.written.first?.oneShot == base.addingTimeInterval(3_600))
}

@Test func wakeApplyMapsAppOutcomesToExitCodes() {
    for (outcome, code) in [("disabled", Int32(4)), ("invalid", Int32(64)), ("helperUnavailable", Int32(1))] {
        let world = World()
        world.statusScript = [ack(outcome)]
        let result = world.client().apply(
            oneShot: base.addingTimeInterval(3_600), repeatDays: nil, repeatTime: nil)
        #expect(result.exitCode == code, "outcome \(outcome)")
    }
}

@Test func wakeApplyTimesOutWithoutAnAck() {
    let world = World()
    world.statusScript = [ack("applied")]
    // The ack belongs to a different request id.
    world.statusScript = [StatusSnapshot(
        isActive: false, pid: 77, writtenAt: base,
        lastWakeRequestId: "dddddddd-1111-2222-3333-444444444444",
        lastWakeRequestOutcome: "applied"
    )]

    let outcome = world.client().apply(
        oneShot: base.addingTimeInterval(3_600), repeatDays: nil, repeatTime: nil)
    #expect(outcome.exitCode == 2)
    #expect(world.now >= base.addingTimeInterval(LeaseClient.ackTimeout))
    // Timeout claims only this request id so the app cannot apply it later.
    #expect(world.claimed == [reqId])
    #expect(world.pending == nil)
}

@Test func wakeRequestClaimIsIdempotentAndIdMatched() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-wake-claim-\(UUID().uuidString)")
        .appendingPathComponent("wake.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let request = AutomationWakeRequest(
        requestId: reqId, oneShot: base.addingTimeInterval(3_600),
        requestedAt: base
    )
    AutomationWakeRequestFile.write(request, to: url)
    #expect(AutomationWakeRequestFile.claim(requestId: "other-id", at: url) == false)
    #expect(AutomationWakeRequestFile.read(from: url) == request)
    #expect(AutomationWakeRequestFile.claim(requestId: reqId, at: url))
    #expect(AutomationWakeRequestFile.read(from: url) == nil)
    // A late claim after the client timed out finds nothing.
    #expect(AutomationWakeRequestFile.claim(requestId: reqId, at: url) == false)
}

@Test func wakeApplyRejectsInvalidRequestsWithoutARoundTrip() {
    let world = World()
    let outcome = world.client().apply(
        oneShot: base.addingTimeInterval(-60), repeatDays: nil, repeatTime: nil)
    #expect(outcome.exitCode == 64)
    #expect(world.written.isEmpty)
    #expect(world.nudged == 0)
}

@Test func wakeStatusReadsUnprivileged() {
    let world = World()
    let outcome = world.client().status()
    #expect(outcome.exitCode == 0)
    #expect(outcome.human.contains("wakeorpoweron at 7:30AM MTWRF"))
}

// MARK: - Request file round trip

@Test func wakeRequestFileRoundTrips() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-wake-tests-\(UUID().uuidString)")
        .appendingPathComponent("wake.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(AutomationWakeRequestFile.read(from: url) == nil)
    let request = AutomationWakeRequest(
        requestId: reqId, oneShot: base.addingTimeInterval(3_600),
        repeatDays: "MTWRF", repeatTime: "07:30", requestedAt: base
    )
    AutomationWakeRequestFile.write(request, to: url)
    #expect(AutomationWakeRequestFile.read(from: url) == request)
    AutomationWakeRequestFile.delete(at: url)
    #expect(AutomationWakeRequestFile.read(from: url) == nil)
}

// MARK: - CLI parsing

@Test func wakeCommandsParse() throws {
    #expect(try CLIRequest.parse(["wake", "status", "--json"]) == .wake(.status(json: true)))
    #expect(try CLIRequest.parse(["wake", "clear"]) == .wake(.clear(json: false)))

    let repeating = try CLIRequest.parse(["wake", "set", "--repeat", "MTWRF", "--time", "07:30"])
    #expect(repeating == .wake(.set(oneShot: nil, repeatDays: "MTWRF", repeatTime: "07:30", json: false)))

    guard case .wake(.set(let oneShot?, nil, nil, false)) =
        try CLIRequest.parse(["wake", "set", "--at", "2026-12-24 07:30"]) else {
        Issue.record("expected a one-shot set")
        return
    }
    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: oneShot)
    #expect(parts.year == 2026 && parts.month == 12 && parts.day == 24)
    #expect(parts.hour == 7 && parts.minute == 30)
}

@Test func wakeCommandsRejectJunk() {
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["wake"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["wake", "install"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["wake", "set"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["wake", "set", "--at", "tomorrow"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["wake", "set", "--repeat", "MTW"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["wake", "set", "--time", "07:30"]) }
    #expect(throws: CLIUsageError.self) {
        try CLIRequest.parse(["wake", "set", "--repeat", "QQ", "--time", "07:30"])
    }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["wake", "status", "--at", "x"]) }
}
