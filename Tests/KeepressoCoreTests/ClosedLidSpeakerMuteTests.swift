import Testing
import Foundation
@testable import KeepressoCore

private final class FakeSpeakers: BuiltInSpeakerMuting {
    var muted: Bool?
    var refuseSets = false
    private(set) var sets: [Bool] = []
    init(muted: Bool? = false) { self.muted = muted }
    func isMuted() -> Bool? { muted }
    func setMuted(_ value: Bool) -> Bool {
        sets.append(value)
        guard muted != nil, !refuseSets else { return false }
        muted = value
        return true
    }
}

private final class FakeMarker: SpeakerMuteMarking {
    var isSet = false
    var refuseSets = false
    func set() -> Bool {
        guard !refuseSets else { return false }
        isSet = true
        return true
    }
    func clear() { isSet = false }
}

@MainActor
private func makeController(muted: Bool? = false) -> (ClosedLidSpeakerMuteController, FakeSpeakers, FakeMarker) {
    let speakers = FakeSpeakers(muted: muted)
    let marker = FakeMarker()
    return (ClosedLidSpeakerMuteController(speakers: speakers, marker: marker), speakers, marker)
}

@MainActor
@Test func speakerMuteMutesWhileLidClosedInClosedDisplayModeAndRestores() {
    let (controller, speakers, marker) = makeController()
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true)
    #expect(speakers.muted == false)

    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == true)
    #expect(controller.holding)
    #expect(marker.isSet)

    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.sets == [true])

    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true)
    #expect(speakers.muted == false)
    #expect(!controller.holding)
    #expect(!marker.isSet)
}

@MainActor
@Test func speakerMuteNeedsClosedDisplayModeAndTheSetting() {
    let (controller, speakers, _) = makeController()
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: false)
    controller.tick(enabled: false, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.sets.isEmpty)
}

@MainActor
@Test func speakerMuteEndsWhenClosedDisplayModeOrTheSettingTurnsOff() {
    let (controller, speakers, _) = makeController()
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == true)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: false)
    #expect(speakers.muted == false)

    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == true)
    controller.tick(enabled: false, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == false)
}

@MainActor
@Test func speakerMuteLeavesSpeakersTheUserAlreadyMuted() {
    let (controller, speakers, marker) = makeController(muted: true)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(!controller.holding)
    #expect(!marker.isSet)
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true)
    #expect(speakers.muted == true)
    #expect(speakers.sets.isEmpty)
}

@MainActor
@Test func speakerMuteKeepsAnUnmuteMadeWithTheLidShut() {
    let (controller, speakers, marker) = makeController()
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    speakers.muted = false
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == false)
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true)
    #expect(speakers.sets == [true])
    #expect(!marker.isSet)

    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == true)
}

@MainActor
@Test func speakerMuteReEnableWithTheLidShutMutesAgain() {
    let (controller, speakers, _) = makeController(muted: true)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.sets.isEmpty)

    controller.tick(enabled: false, lidClosed: nil, closedDisplayActive: true)
    speakers.muted = false
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == true)
    #expect(controller.holding)
}

@MainActor
@Test func speakerMuteWaitsWhileNoSpeakersAreReachable() {
    let (controller, speakers, marker) = makeController(muted: nil)
    let start = Date(timeIntervalSince1970: 1_000_000)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start)
    #expect(!controller.holding)
    #expect(!marker.isSet)

    speakers.muted = false
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start.addingTimeInterval(1))
    #expect(speakers.muted == false)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true,
                    now: start.addingTimeInterval(ClosedLidSpeakerMuteController.unreachableRetry))
    #expect(speakers.muted == true)
}

@MainActor
@Test func speakerMuteRetriesAFailedUnmuteAndKeepsTheMarker() {
    let (controller, speakers, marker) = makeController()
    let start = Date(timeIntervalSince1970: 1_000_000)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start)
    speakers.refuseSets = true
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true, now: start.addingTimeInterval(1))
    #expect(speakers.muted == true)
    #expect(controller.holding)
    #expect(marker.isSet)

    speakers.refuseSets = false
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true, now: start.addingTimeInterval(2))
    #expect(speakers.muted == true)
    #expect(speakers.sets == [true, false])
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true,
                    now: start.addingTimeInterval(1 + ClosedLidSpeakerMuteController.unreachableRetry))
    #expect(speakers.muted == false)
    #expect(!marker.isSet)
}

@MainActor
@Test func speakerMuteFailedMuteLeavesNoMarker() {
    let (controller, speakers, marker) = makeController()
    speakers.refuseSets = true
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(!controller.holding)
    #expect(!marker.isSet)
}

@MainActor
@Test func speakerMuteRetriesAFailedMuteAfterBackingOff() {
    let (controller, speakers, marker) = makeController()
    let start = Date(timeIntervalSince1970: 1_000_000)
    speakers.refuseSets = true
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start)
    speakers.refuseSets = false
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start.addingTimeInterval(1))
    #expect(speakers.sets == [true])
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true,
                    now: start.addingTimeInterval(ClosedLidSpeakerMuteController.unreachableRetry))
    #expect(speakers.sets == [true, true])
    #expect(controller.holding)
    #expect(marker.isSet)
}

@MainActor
@Test func speakerMuteRetriesWhenItsRecoveryMarkerCouldNotBeWritten() {
    let (controller, speakers, marker) = makeController()
    let start = Date(timeIntervalSince1970: 1_000_000)
    marker.refuseSets = true
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start)
    #expect(speakers.sets.isEmpty)
    marker.refuseSets = false
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true,
                    now: start.addingTimeInterval(ClosedLidSpeakerMuteController.unreachableRetry))
    #expect(speakers.muted == true)
    #expect(controller.holding)
    #expect(marker.isSet)
}

@MainActor
@Test func speakerMuteFinishesAnUnconfirmedReleaseBeforeRearming() {
    let (controller, speakers, marker) = makeController()
    let start = Date(timeIntervalSince1970: 1_000_000)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start)
    speakers.refuseSets = true
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true, now: start.addingTimeInterval(1))
    #expect(controller.holding)

    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start.addingTimeInterval(2))
    speakers.refuseSets = false
    speakers.muted = false
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true,
                    now: start.addingTimeInterval(1 + ClosedLidSpeakerMuteController.unreachableRetry))
    #expect(speakers.muted == true)
    #expect(speakers.sets == [true, false, true])
    #expect(controller.holding)
    #expect(marker.isSet)

    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true,
                    now: start.addingTimeInterval(20))
    #expect(speakers.muted == false)
    #expect(!marker.isSet)
}

@MainActor
@Test func speakerMuteRestoresAfterACrash() {
    let (controller, speakers, marker) = makeController(muted: true)
    marker.isSet = true
    controller.restoreIfNeeded()
    #expect(controller.holding)
    #expect(speakers.muted == true)

    controller.tick(enabled: true, lidClosed: nil, closedDisplayActive: nil)
    #expect(speakers.muted == true)

    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: false)
    #expect(speakers.muted == false)
    #expect(!marker.isSet)
    #expect(!controller.holding)
}

@MainActor
@Test func speakerMuteCrashRestoreWithTheLidStillShutStaysMuted() {
    let (controller, speakers, marker) = makeController(muted: true)
    marker.isSet = true
    controller.restoreIfNeeded()
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.sets.isEmpty)
    #expect(controller.holding)

    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true)
    #expect(speakers.muted == false)
    #expect(!marker.isSet)
}

@MainActor
@Test func speakerMuteCrashRestoreReleasesOnAnOpenLidBeforeTheModeIsKnown() {
    let (controller, speakers, marker) = makeController(muted: true)
    marker.isSet = true
    controller.restoreIfNeeded()
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: nil)
    #expect(speakers.muted == false)
    #expect(!marker.isSet)
    #expect(!controller.holding)
}

@MainActor
@Test func speakerMuteCrashRestoreReleasesWhenTheModeIsOffBeforeTheLidIsKnown() {
    let (controller, speakers, marker) = makeController(muted: true)
    marker.isSet = true
    controller.restoreIfNeeded()
    controller.tick(enabled: true, lidClosed: nil, closedDisplayActive: false)
    #expect(speakers.muted == false)
    #expect(!marker.isSet)
    #expect(!controller.holding)
}

@MainActor
@Test func speakerMuteCrashRestoreWithTheFeatureOffReleasesWithoutReadings() {
    let (controller, speakers, marker) = makeController(muted: true)
    marker.isSet = true
    controller.restoreIfNeeded()
    controller.tick(enabled: false, lidClosed: nil, closedDisplayActive: nil)
    #expect(speakers.muted == false)
    #expect(!marker.isSet)
}

@MainActor
@Test func speakerMuteReleaseBacksOffWhileSpeakersAreUnreachable() {
    let (controller, speakers, marker) = makeController()
    let start = Date(timeIntervalSince1970: 1_000_000)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start)
    #expect(speakers.muted == true)

    let saved = speakers.muted
    speakers.muted = nil
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true, now: start.addingTimeInterval(1))
    #expect(controller.holding)
    #expect(marker.isSet)

    speakers.muted = saved
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true, now: start.addingTimeInterval(2))
    #expect(speakers.muted == true)
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true,
                    now: start.addingTimeInterval(1 + ClosedLidSpeakerMuteController.unreachableRetry))
    #expect(speakers.muted == false)
    #expect(!marker.isSet)
}

@MainActor
@Test func speakerMuteCrashRestoreWithoutMarkerChangesNothing() {
    let (controller, speakers, _) = makeController(muted: true)
    controller.restoreIfNeeded()
    #expect(speakers.muted == true)
    #expect(speakers.sets.isEmpty)
}

@MainActor
@Test func speakerMuteReleaseAtQuitUnmutes() {
    let (controller, speakers, marker) = makeController()
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    controller.release()
    #expect(speakers.muted == false)
    #expect(!marker.isSet)
}

@Test func speakerMuteSettingDefaultsOffAndRoundTrips() throws {
    let legacy = try JSONDecoder().decode(KeepressoSettings.self, from: Data(#"{"triggersEnabled": true}"#.utf8))
    #expect(!legacy.closedLidMuteSpeakers)
    #expect(legacy.triggersEnabled)

    let garbled = try JSONDecoder().decode(
        KeepressoSettings.self, from: Data(#"{"closedLidMuteSpeakers": "yes", "triggersEnabled": true}"#.utf8))
    #expect(!garbled.closedLidMuteSpeakers)
    #expect(garbled.triggersEnabled)

    var settings = KeepressoSettings()
    settings.closedLidMuteSpeakers = true
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.closedLidMuteSpeakers)
    let imported = try SettingsTransfer.importSettings(from: SettingsTransfer.exportData(settings))
    #expect(imported.closedLidMuteSpeakers)
}

@Test func speakerMuteMarkerFileRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-speaker-mute-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let marker = FileSpeakerMuteMarker(url: dir.appendingPathComponent("speaker-mute"))
    #expect(!marker.isSet)
    #expect(marker.set())
    #expect(marker.isSet)
    marker.clear()
    #expect(!marker.isSet)
}

private final class CountingLid: LidStateReading, @unchecked Sendable {
    var closed: Bool? = true
    private(set) var reads = 0
    func isClosed() -> Bool? { reads += 1; return closed }
}

private final class FakeMonotonic: @unchecked Sendable {
    var nanos: UInt64 = 100_000_000_000
}

@Test func cachedLidStateSharesOneReadWithinItsWindow() {
    let source = CountingLid()
    let clock = FakeMonotonic()
    let lid = CachedLidState(source, ttl: 0.5, clock: { clock.nanos })
    #expect(lid.isClosed() == true)
    #expect(lid.isClosed() == true)
    #expect(source.reads == 1)

    source.closed = false
    clock.nanos += 600_000_000
    #expect(lid.isClosed() == false)
    #expect(source.reads == 2)

    clock.nanos -= 10_000_000_000
    source.closed = true
    #expect(lid.isClosed() == true)
    #expect(source.reads == 3)
}
