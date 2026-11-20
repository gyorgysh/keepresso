import Testing
import Foundation
@testable import PervigilCore

/// Built-in speakers with a controllable mute state. `muted == nil` models
/// no reachable speakers (headphones on the jack, or none at all).
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
    #expect(speakers.muted == false) // lid open: untouched

    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == true)
    #expect(controller.holding)
    #expect(marker.isSet)

    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.sets == [true]) // held, not re-applied every tick

    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true)
    #expect(speakers.muted == false)
    #expect(!controller.holding)
    #expect(!marker.isSet)
}

@MainActor
@Test func speakerMuteNeedsClosedDisplayModeAndTheSetting() {
    let (controller, speakers, _) = makeController()
    // Lid closed, but closed-display mode off: the Mac is about to sleep anyway.
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: false)
    // Setting off: never touches the speakers.
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
    #expect(speakers.muted == true) // still the user's mute
    #expect(speakers.sets.isEmpty)
}

@MainActor
@Test func speakerMuteKeepsAnUnmuteMadeWithTheLidShut() {
    let (controller, speakers, marker) = makeController()
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    speakers.muted = false // the user unmuted (remote session, keyboard)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == false) // not re-muted in the same stretch
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true)
    #expect(speakers.sets == [true])
    #expect(!marker.isSet)

    // The next lid-closed stretch mutes again.
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.muted == true)
}

@MainActor
@Test func speakerMuteReEnableWithTheLidShutMutesAgain() {
    let (controller, speakers, _) = makeController(muted: true)
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true)
    #expect(speakers.sets.isEmpty) // the user's own mute: stretch handled

    // Turned off (the host ticks with no lid reading), then the user
    // unmutes and turns it back on with the lid still shut.
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

    // Headphones unplugged with the lid still shut: the speakers are now the
    // route. The device scan backs off, so they get muted on the next probe.
    speakers.muted = false
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, now: start.addingTimeInterval(1))
    #expect(speakers.muted == false) // inside the backoff: no probe
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

    // A failed unmute backs off like unreachable speakers, so the device scan
    // does not run every tick.
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

    // CoreAudio accepted an unmute but its immediate read-back was stale.
    // It lands after the lid closes again, while release is still pending.
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
    marker.isSet = true // a previous run muted and never got to unmute
    controller.restoreIfNeeded()
    #expect(controller.holding)
    #expect(speakers.muted == true) // nothing read yet: lid may still be shut

    controller.tick(enabled: true, lidClosed: nil, closedDisplayActive: nil)
    #expect(speakers.muted == true) // still no reading: keep holding

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
    #expect(speakers.sets.isEmpty) // no unmute blip, no re-mute
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
    // The lid reads open; closed-display mode hasn't been read yet. An open
    // lid can't be closed-display mode, so the sound comes back now.
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

    // Lid opens while the speakers can't be reached: hold and retry later.
    let saved = speakers.muted
    speakers.muted = nil
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true, now: start.addingTimeInterval(1))
    #expect(controller.holding)
    #expect(marker.isSet)

    speakers.muted = saved
    controller.tick(enabled: true, lidClosed: false, closedDisplayActive: true, now: start.addingTimeInterval(2))
    #expect(speakers.muted == true) // inside the backoff
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
    let legacy = try JSONDecoder().decode(PervigilSettings.self, from: Data(#"{"triggersEnabled": true}"#.utf8))
    #expect(!legacy.closedLidMuteSpeakers)
    #expect(legacy.triggersEnabled)

    let garbled = try JSONDecoder().decode(
        PervigilSettings.self, from: Data(#"{"closedLidMuteSpeakers": "yes", "triggersEnabled": true}"#.utf8))
    #expect(!garbled.closedLidMuteSpeakers)
    #expect(garbled.triggersEnabled)

    var settings = PervigilSettings()
    settings.closedLidMuteSpeakers = true
    let decoded = try JSONDecoder().decode(PervigilSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.closedLidMuteSpeakers)
    let imported = try SettingsTransfer.importSettings(from: SettingsTransfer.exportData(settings))
    #expect(imported.closedLidMuteSpeakers)
}

@Test func speakerMuteMarkerFileRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pervigil-speaker-mute-\(UUID().uuidString)", isDirectory: true)
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
    #expect(source.reads == 1) // ticker and features share the reading

    source.closed = false
    clock.nanos += 600_000_000 // next tick
    #expect(lid.isClosed() == false)
    #expect(source.reads == 2)

    // A clock that somehow runs backwards never pins a stale reading.
    clock.nanos -= 10_000_000_000
    source.closed = true
    #expect(lid.isClosed() == true)
    #expect(source.reads == 3)
}
