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
    engine.tick()
    #expect(engine.isSatisfied())

    // Playback stops: the rule keeps holding through a brief silence...
    monitor.snapshot = MediaActivitySnapshot(audioPlaying: false)
    clock = clock.addingTimeInterval(AudioPlayingTrigger.releaseGrace - 1)
    engine.tick()
    #expect(engine.isSatisfied())

    // ...and releases once the grace runs out.
    clock = clock.addingTimeInterval(2)
    engine.tick()
    #expect(!engine.isSatisfied())
}

// MARK: - App-scoped microphone (Discord/Slack/... calls)

@Test func captureMatcherMatchesExactAndHelperPrefix() {
    // A native call app captures under its own id (exact match); an Electron
    // app captures under a child helper id (prefix match).
    let capturing: Set<String> = ["com.hnc.Discord.helper.Renderer", "com.apple.FaceTime"]
    #expect(MediaInUseTrigger.captures(["com.hnc.Discord"], in: capturing))        // helper prefix
    #expect(MediaInUseTrigger.captures(["com.apple.FaceTime"], in: capturing))     // exact
    #expect(MediaInUseTrigger.captures(["com.tinyspeck.slackmacgap", "com.hnc.Discord"], in: capturing))
}

@Test func captureMatcherRejectsNonMatchesAndEmptyScope() {
    let capturing: Set<String> = ["com.hnc.Discord.helper.Renderer"]
    #expect(!MediaInUseTrigger.captures(["com.tinyspeck.slackmacgap"], in: capturing))
    #expect(!MediaInUseTrigger.captures([], in: capturing))          // empty scope never matches
    #expect(!MediaInUseTrigger.captures([""], in: capturing))        // empty id never matches
    // A sibling-prefix must not false-match: "com.hnc.Disc" is not a bundle
    // ancestor of "com.hnc.Discord..." (the dot boundary guards against it).
    #expect(!MediaInUseTrigger.captures(["com.hnc.Disc"], in: capturing))
}

@Test func scopedMicTriggerFiresOnlyForListedApps() {
    let monitor = FakeMediaMonitor(microphone: true)
    monitor.snapshot = MediaActivitySnapshot(
        microphoneInUse: true,
        micCapturingBundleIDs: ["com.hnc.Discord.helper.Renderer"]
    )
    // Unscoped mic use is Discord; a Slack-scoped rule stays quiet...
    let slack = MediaInUseTrigger(device: .microphone, appFilter: ["com.tinyspeck.slackmacgap"], monitor: monitor)
    #expect(!slack.isSatisfied())
    // ...while a Discord-scoped rule fires on the helper via the prefix rule.
    let discord = MediaInUseTrigger(device: .microphone, appFilter: ["com.hnc.Discord"], monitor: monitor)
    #expect(discord.isSatisfied())
    // The unscoped rule still fires on any mic use.
    let any = MediaInUseTrigger(device: .microphone, monitor: monitor)
    #expect(any.isSatisfied())
}

@Test func scopedMicTriggerWithEmptyFilterNeverHolds() {
    // A half-configured scope (no apps) must not pin the Mac awake even while
    // the mic is genuinely in use.
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

    // A different app on the mic no longer satisfies the Slack-scoped rule.
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
    #expect(rule.requiredPermission == nil)   // reads process state, no TCC permission
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}

@Test func oldUnscopedMediaInUseJSONStillDecodes() throws {
    // The wire format of the pre-existing unscoped rule must not change when the
    // sibling `.micInUse` case is added, or upgraders lose their saved rules.
    let json = Data(#"[{"mediaInUse":{"_0":"microphone"}}]"#.utf8)
    #expect(try JSONDecoder().decode([TriggerRule].self, from: json) == [.mediaInUse(.microphone)])
}

@Test func multiIdPresetRuleMatchesEitherVariantAndDedupsLabel() {
    // A preset like Teams or Telegram carries several bundle ids under one name.
    let rule = MicInUseRule(apps: [
        ScopedApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams"),
        ScopedApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
    ])
    // The shared display name shows once, not "Microsoft Teams, Microsoft Teams".
    #expect(TriggerRule.micInUse(rule).label == "Microphone in use by Microsoft Teams")
    let ids = rule.apps.map(\.bundleID)
    #expect(MediaInUseTrigger.captures(ids, in: ["com.microsoft.teams"]))          // classic client
    #expect(MediaInUseTrigger.captures(ids, in: ["com.microsoft.teams2.helper"]))  // new client's helper
    #expect(!MediaInUseTrigger.captures(ids, in: ["com.hnc.Discord.helper.Renderer"]))
}

@Test func enclosingAppBundleResolvesElectronHelperToItsApp() {
    // The mic capturer is a helper buried in Frameworks; resolve to the app.
    let helper = "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"
    #expect(CoreMediaActivityMonitor.enclosingAppBundleURL(forExecutablePath: helper)?.path == "/Applications/Discord.app")
    // A native app whose own binary captures resolves to itself.
    let native = "/Applications/FaceTime.app/Contents/MacOS/FaceTime"
    #expect(CoreMediaActivityMonitor.enclosingAppBundleURL(forExecutablePath: native)?.path == "/Applications/FaceTime.app")
    // A plain CLI outside any bundle has no enclosing app.
    #expect(CoreMediaActivityMonitor.enclosingAppBundleURL(forExecutablePath: "/usr/bin/some-tool") == nil)
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
