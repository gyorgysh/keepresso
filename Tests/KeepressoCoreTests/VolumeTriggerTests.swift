import Testing
import Foundation
@testable import KeepressoCore

private final class FakeVolumeMonitor: VolumeMonitoring {
    var snapshot: VolumeSnapshot
    init(volumeNames: Set<String>) { snapshot = VolumeSnapshot(volumeNames: volumeNames) }
    var current: VolumeSnapshot { snapshot }
}

@Test func firesWhileTheVolumeIsMounted() {
    let monitor = FakeVolumeMonitor(volumeNames: ["Backup", "media"])
    let trigger = VolumeMountedTrigger(volumeName: "Backup", monitor: monitor)
    #expect(trigger.isSatisfied())

    monitor.snapshot = VolumeSnapshot(volumeNames: ["media"])
    #expect(!trigger.isSatisfied())
}

@Test func volumeNameMatchIsExact() {
    let monitor = FakeVolumeMonitor(volumeNames: ["Backup Drive"])
    #expect(!VolumeMountedTrigger(volumeName: "Backup", monitor: monitor).isSatisfied())
    #expect(!VolumeMountedTrigger(volumeName: "backup drive", monitor: monitor).isSatisfied())
    #expect(VolumeMountedTrigger(volumeName: "Backup Drive", monitor: monitor).isSatisfied())
}

@Test func volumeRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.volumeMounted("media")
    #expect(rule.label == "Volume \u{201C}media\u{201D} mounted")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}

@Test func factoryBuildsAVolumeTrigger() {
    let monitor = FakeVolumeMonitor(volumeNames: ["media"])
    let factory = TriggerFactory(volumes: monitor)
    let engine = factory.makeEngine(from: RuleSet(rules: [.volumeMounted("media")]))
    #expect(engine.isSatisfied())
}
