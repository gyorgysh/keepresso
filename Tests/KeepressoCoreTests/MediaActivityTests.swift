import Testing
import Foundation
@testable import KeepressoCore

private final class FakeMediaMonitor: MediaActivityMonitoring {
    var snapshot: MediaActivitySnapshot
    init(camera: Bool = false, microphone: Bool = false, audio: Bool = false) {
        snapshot = MediaActivitySnapshot(cameraInUse: camera, microphoneInUse: microphone, audioPlaying: audio)
    }
    var current: MediaActivitySnapshot { snapshot }
}

@Test func cameraTriggerFiresOnlyOnCameraUse() {
    let monitor = FakeMediaMonitor(camera: true, microphone: false)
    let trigger = MediaInUseTrigger(device: .camera, monitor: monitor)
    #expect(trigger.isSatisfied())

    monitor.snapshot = MediaActivitySnapshot(cameraInUse: false, microphoneInUse: true)
    #expect(!trigger.isSatisfied())
}

@Test func microphoneTriggerFiresOnlyOnMicrophoneUse() {
    let monitor = FakeMediaMonitor(camera: true, microphone: false)
    let trigger = MediaInUseTrigger(device: .microphone, monitor: monitor)
    #expect(!trigger.isSatisfied())

    monitor.snapshot = MediaActivitySnapshot(microphoneInUse: true)
    #expect(trigger.isSatisfied())
}

@Test func mediaInUseRuleLabelsAndCodableRoundTrip() throws {
    let rules: [TriggerRule] = [.mediaInUse(.camera), .mediaInUse(.microphone)]
    #expect(rules[0].label == "Camera in use")
    #expect(rules[1].label == "Microphone in use")
    let data = try JSONEncoder().encode(rules)
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == rules)
}

@Test func factoryBuildsMediaInUseTriggers() {
    let monitor = FakeMediaMonitor(camera: false, microphone: true)
    let factory = TriggerFactory(media: monitor)
    let engine = factory.makeEngine(
        from: RuleSet(combine: .any, rules: [.mediaInUse(.camera), .mediaInUse(.microphone)])
    )
    #expect(engine.isSatisfied())

    monitor.snapshot = MediaActivitySnapshot()
    #expect(!engine.isSatisfied())
}

@Test func mediaMonitorCachesProbeResultsBriefly() {
    var probeCount = 0
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let monitor = CoreMediaActivityMonitor(ttl: 1.5, now: { clock }) {
        probeCount += 1
        return MediaActivitySnapshot(cameraInUse: true)
    }

    #expect(monitor.current.cameraInUse)
    #expect(monitor.current.cameraInUse)
    #expect(probeCount == 1) // second read within the TTL reuses the snapshot

    clock = clock.addingTimeInterval(2)
    #expect(monitor.current.cameraInUse)
    #expect(probeCount == 2) // stale snapshot re-probes
}

@Test func audioTriggerFollowsPlaybackState() {
    let monitor = FakeMediaMonitor(audio: true)
    let trigger = AudioPlayingTrigger(monitor: monitor)
    #expect(trigger.isSatisfied())

    monitor.snapshot = MediaActivitySnapshot(audioPlaying: false)
    #expect(!trigger.isSatisfied())
}

@Test func audioPlayingRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.audioPlaying
    #expect(rule.label == "Audio playing")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}

@Test func factoryWrapsAudioPlayingInAReleaseGrace() {
    let monitor = FakeMediaMonitor(audio: true)
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let factory = TriggerFactory(media: monitor, now: { clock })
    let engine = factory.makeEngine(from: RuleSet(rules: [.audioPlaying]))
    #expect(engine.isSatisfied())

    // Playback stops: the rule keeps holding through a brief silence...
    monitor.snapshot = MediaActivitySnapshot(audioPlaying: false)
    clock = clock.addingTimeInterval(AudioPlayingTrigger.releaseGrace - 1)
    #expect(engine.isSatisfied())

    // ...and releases once the grace runs out.
    clock = clock.addingTimeInterval(2)
    #expect(!engine.isSatisfied())
}

@Test func meetingsPresetWatchesCameraAndMicrophone() {
    let meetings = Preset.builtIns.first { $0.id == "meetings" }
    #expect(meetings != nil)
    #expect(meetings?.ruleSet.combine == .any)
    #expect(meetings?.ruleSet.rules == [.mediaInUse(.camera), .mediaInUse(.microphone)])
}

@Test func meetingsPresetReachesExistingUsersViaSeeding() {
    // A user whose settings predate the meetings preset (it's absent from both
    // their presets and their seeded ids) gets it appended exactly once.
    var settings = KeepressoSettings(
        presets: Preset.builtIns.filter { $0.id != "meetings" },
        seededPresetIDs: Preset.builtIns.map(\.id).filter { $0 != "meetings" }
    )
    settings.seedNewBuiltInPresets()
    #expect(settings.presets.contains { $0.id == "meetings" })

    let countAfterFirstSeed = settings.presets.count
    settings.seedNewBuiltInPresets()
    #expect(settings.presets.count == countAfterFirstSeed)
}
