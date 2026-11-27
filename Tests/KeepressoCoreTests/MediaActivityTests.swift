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
    #expect(probeCount == 1)

    clock = clock.addingTimeInterval(2)
    #expect(monitor.current.cameraInUse)
    #expect(probeCount == 2)
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
    engine.tick()
    #expect(engine.isSatisfied())

    monitor.snapshot = MediaActivitySnapshot(audioPlaying: false)
    clock = clock.addingTimeInterval(AudioPlayingTrigger.releaseGrace - 1)
    engine.tick()
    #expect(engine.isSatisfied())

    clock = clock.addingTimeInterval(2)
    engine.tick()
    #expect(!engine.isSatisfied())
}


@Test func captureMatcherMatchesExactAndHelperPrefix() {
    let capturing: Set<String> = ["com.hnc.Discord.helper.Renderer", "com.apple.FaceTime"]
    #expect(MediaInUseTrigger.captures(["com.hnc.Discord"], in: capturing))
    #expect(MediaInUseTrigger.captures(["com.apple.FaceTime"], in: capturing))
    #expect(MediaInUseTrigger.captures(["com.tinyspeck.slackmacgap", "com.hnc.Discord"], in: capturing))
}

@Test func captureMatcherRejectsNonMatchesAndEmptyScope() {
    let capturing: Set<String> = ["com.hnc.Discord.helper.Renderer"]
    #expect(!MediaInUseTrigger.captures(["com.tinyspeck.slackmacgap"], in: capturing))
    #expect(!MediaInUseTrigger.captures([], in: capturing))
    #expect(!MediaInUseTrigger.captures([""], in: capturing))
    #expect(!MediaInUseTrigger.captures(["com.hnc.Disc"], in: capturing))
}

@Test func scopedMicTriggerFiresOnlyForListedApps() {
    let monitor = FakeMediaMonitor(microphone: true)
    monitor.snapshot = MediaActivitySnapshot(
        microphoneInUse: true,
        micCapturingBundleIDs: ["com.hnc.Discord.helper.Renderer"]
    )
    let slack = MediaInUseTrigger(device: .microphone, appFilter: ["com.tinyspeck.slackmacgap"], monitor: monitor)
    #expect(!slack.isSatisfied())
    let discord = MediaInUseTrigger(device: .microphone, appFilter: ["com.hnc.Discord"], monitor: monitor)
    #expect(discord.isSatisfied())
    let any = MediaInUseTrigger(device: .microphone, monitor: monitor)
    #expect(any.isSatisfied())
}

@Test func scopedMicTriggerWithEmptyFilterNeverHolds() {
    let monitor = FakeMediaMonitor(microphone: true)
    monitor.snapshot = MediaActivitySnapshot(
        microphoneInUse: true,
        micCapturingBundleIDs: ["com.hnc.Discord.helper.Renderer"]
    )
    let empty = MediaInUseTrigger(device: .microphone, appFilter: [], monitor: monitor)
    #expect(!empty.isSatisfied())
}

@Test func factoryBuildsScopedMicTrigger() {
    let monitor = FakeMediaMonitor(microphone: true)
    monitor.snapshot = MediaActivitySnapshot(
        microphoneInUse: true,
        micCapturingBundleIDs: ["com.tinyspeck.slackmacgap.helper"]
    )
    let factory = TriggerFactory(media: monitor)
    let rule = TriggerRule.micInUse(MicInUseRule(apps: [ScopedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")]))
    let engine = factory.makeEngine(from: RuleSet(rules: [rule]))
    #expect(engine.isSatisfied())

    monitor.snapshot = MediaActivitySnapshot(
        microphoneInUse: true,
        micCapturingBundleIDs: ["com.hnc.Discord.helper.Renderer"]
    )
    #expect(!engine.isSatisfied())
}

@Test func micInUseRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.micInUse(MicInUseRule(apps: [
        ScopedApp(bundleID: "com.hnc.Discord", name: "Discord"),
        ScopedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
    ]))
    #expect(rule.label == "Microphone in use by Discord, Slack")
    #expect(rule.requiredPermission == nil)
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}

@Test func oldUnscopedMediaInUseJSONStillDecodes() throws {
    let json = Data(#"[{"mediaInUse":{"_0":"microphone"}}]"#.utf8)
    #expect(try JSONDecoder().decode([TriggerRule].self, from: json) == [.mediaInUse(.microphone)])
}

@Test func multiIdPresetRuleMatchesEitherVariantAndDedupsLabel() {
    let rule = MicInUseRule(apps: [
        ScopedApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams"),
        ScopedApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
    ])
    #expect(TriggerRule.micInUse(rule).label == "Microphone in use by Microsoft Teams")
    let ids = rule.apps.map(\.bundleID)
    #expect(MediaInUseTrigger.captures(ids, in: ["com.microsoft.teams"]))
    #expect(MediaInUseTrigger.captures(ids, in: ["com.microsoft.teams2.helper"]))
    #expect(!MediaInUseTrigger.captures(ids, in: ["com.hnc.Discord.helper.Renderer"]))
}

@Test func enclosingAppBundleResolvesElectronHelperToItsApp() {
    let helper = "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"
    #expect(CoreMediaActivityMonitor.enclosingAppBundleURL(forExecutablePath: helper)?.path == "/Applications/Discord.app")
    let native = "/Applications/FaceTime.app/Contents/MacOS/FaceTime"
    #expect(CoreMediaActivityMonitor.enclosingAppBundleURL(forExecutablePath: native)?.path == "/Applications/FaceTime.app")
    #expect(CoreMediaActivityMonitor.enclosingAppBundleURL(forExecutablePath: "/usr/bin/some-tool") == nil)
}

@Test func meetingsPresetWatchesCameraAndMicrophone() {
    let meetings = Preset.builtIns.first { $0.id == "meetings" }
    #expect(meetings != nil)
    #expect(meetings?.ruleSet.combine == .any)
    #expect(meetings?.ruleSet.rules == [.mediaInUse(.camera), .mediaInUse(.microphone)])
}

@Test func meetingsPresetReachesExistingUsersViaSeeding() {
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
