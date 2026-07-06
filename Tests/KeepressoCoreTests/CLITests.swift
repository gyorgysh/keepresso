import Testing
import Foundation
@testable import KeepressoCore

// MARK: - App commands

@Test func bareInvocationShowsHelp() throws {
    #expect(try CLIRequest.parse([]) == .help)
    #expect(try CLIRequest.parse(["--help"]) == .help)
    #expect(try CLIRequest.parse(["help"]) == .help)
}

@Test func parsesPlainStart() throws {
    #expect(try CLIRequest.parse(["start"]) == .remote(.start(durationMinutes: nil, untilTime: nil)))
}

@Test func parsesStartWithMinutes() throws {
    #expect(try CLIRequest.parse(["start", "--for", "90"])
        == .remote(.start(durationMinutes: 90, untilTime: nil)))
    #expect(try CLIRequest.parse(["start", "--duration", "2.5"])
        == .remote(.start(durationMinutes: 2.5, untilTime: nil)))
}

@Test func parsesStartUntil() throws {
    #expect(try CLIRequest.parse(["start", "--until", "18:30"])
        == .remote(.start(durationMinutes: nil, untilTime: "18:30")))
}

@Test func rejectsBadStartOptions() {
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["start", "--for", "zero"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["start", "--for", "-5"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["start", "--until", "25:00"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["start", "--until", "18:5"]) }
    #expect(throws: CLIUsageError.self) {
        try CLIRequest.parse(["start", "--for", "10", "--until", "18:00"])
    }
}

@Test func parsesStopAndToggle() throws {
    #expect(try CLIRequest.parse(["stop"]) == .remote(.stop))
    #expect(try CLIRequest.parse(["toggle"]) == .remote(.toggle))
}

@Test func parsesStatus() throws {
    #expect(try CLIRequest.parse(["status"]) == .status(json: false))
    #expect(try CLIRequest.parse(["status", "--json"]) == .status(json: true))
}

@Test func rejectsUnknownCommand() {
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["brew"]) }
}

// MARK: - URL building round-trips through the app-side parser

@Test func startURLRoundTripsThroughURLCommand() {
    let plain = CLIRequest.RemoteCommand.start(durationMinutes: nil, untilTime: nil)
    #expect(URLCommand.parse(URL(string: plain.urlString)!) == .start(mode: .indefinite))

    let timed = CLIRequest.RemoteCommand.start(durationMinutes: 90, untilTime: nil)
    #expect(timed.urlString == "keepresso://start?duration=90")
    #expect(URLCommand.parse(URL(string: timed.urlString)!) == .start(mode: .timed(duration: 90 * 60)))

    let fractional = CLIRequest.RemoteCommand.start(durationMinutes: 2.5, untilTime: nil)
    #expect(URLCommand.parse(URL(string: fractional.urlString)!) == .start(mode: .timed(duration: 150)))
}

@Test func untilURLRoundTripsThroughURLCommand() throws {
    let command = CLIRequest.RemoteCommand.start(durationMinutes: nil, untilTime: "18:30")
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 12))!
    let parsed = URLCommand.parse(URL(string: command.urlString)!, now: now)
    let expected = try #require(SessionMode.until(hour: 18, minute: 30, now: now))
    #expect(parsed == .start(mode: expected))
}

@Test func stopAndToggleURLsRoundTrip() {
    #expect(URLCommand.parse(URL(string: CLIRequest.RemoteCommand.stop.urlString)!) == .stop)
    #expect(URLCommand.parse(URL(string: CLIRequest.RemoteCommand.toggle.urlString)!) == .toggle)
}

// MARK: - Holds

@Test func parsesTimedHold() throws {
    #expect(try CLIRequest.parse(["-t", "300"])
        == .hold(.init(timeoutSeconds: 300)))
}

@Test func parsesProcessWaitHold() throws {
    #expect(try CLIRequest.parse(["-w", "1234"])
        == .hold(.init(waitForPID: 1234)))
}

@Test func parsesIndefiniteHold() throws {
    #expect(try CLIRequest.parse(["-i"]) == .hold(.init()))
    #expect(try CLIRequest.parse(["-d"]) == .hold(.init(display: true)))
}

@Test func parsesCombinedFlags() throws {
    #expect(try CLIRequest.parse(["-di", "-t", "60"])
        == .hold(.init(display: true, timeoutSeconds: 60)))
    #expect(try CLIRequest.parse(["-du"])
        == .hold(.init(display: true, declareUserActivity: true)))
}

@Test func bareUserActivityIsOneShot() throws {
    #expect(try CLIRequest.parse(["-u"])
        == .hold(.init(declareUserActivity: true, oneShot: true)))
}

@Test func userActivityWithBoundIsNotOneShot() throws {
    #expect(try CLIRequest.parse(["-u", "-t", "5"])
        == .hold(.init(declareUserActivity: true, timeoutSeconds: 5)))
}

@Test func rejectsBadHoldFlags() {
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["-t"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["-t", "soon"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["-w", "0"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["-x"]) }
    #expect(throws: CLIUsageError.self) { try CLIRequest.parse(["-dt", "60"]) }
}

// MARK: - Status file

@Test func statusSnapshotRoundTripsThroughDisk() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("status.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let snapshot = StatusSnapshot(
        isActive: true,
        endsAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
        triggersEnabled: true,
        triggersPaused: false,
        appVersion: "1.8.0",
        pid: 4242,
        writtenAt: Date(timeIntervalSinceReferenceDate: 799_999_000)
    )
    StatusFile.write(snapshot, to: url)
    #expect(StatusFile.read(from: url) == snapshot)
}

@Test func statusFileReadsMissingFileAsNil() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-tests-\(UUID().uuidString).json")
    #expect(StatusFile.read(from: url) == nil)
}

@Test func statusFileIsScriptFriendlyJSON() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-tests-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    StatusFile.write(
        StatusSnapshot(isActive: false, pid: 1, writtenAt: Date(timeIntervalSince1970: 1_800_000_000)),
        to: url
    )
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(object?["isActive"] as? Bool == false)
    // ISO 8601, not a raw interval, so `jq` users can read it.
    #expect((object?["writtenAt"] as? String)?.hasSuffix("Z") == true)
}
