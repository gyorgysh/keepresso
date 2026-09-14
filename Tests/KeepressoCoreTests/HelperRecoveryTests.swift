import Foundation
import Testing
@testable import KeepressoCore

@Test func helperOwnershipRejectsDevelopmentAndTrashCopies() {
    let home = URL(fileURLWithPath: "/Users/test")
    for path in ["/Applications/Keepresso.app", "/Users/test/Applications/Keepresso.app"] {
        #expect(HelperInstallation.ownsRegistration(bundleURL: URL(fileURLWithPath: path), homeURL: home))
    }
    for path in [
        "/Users/test/Library/Developer/Xcode/DerivedData/Keepresso/Build/Products/Debug/Keepresso.app",
        "/Users/test/.Trash/Applications/Keepresso.app",
        // The app at a DMG's root, which is where it actually sits when run
        // from the mounted image. Not "/Volumes/<name>/Applications/...":
        // that is the drag-install symlink to /Applications, and
        // `resolvingSymlinksInPath` reads the real filesystem, so with the
        // release DMG mounted the fixture would resolve into /Applications
        // and the case would flip.
        "/Volumes/Keepresso/Keepresso.app",
        "/tmp/Applications/Keepresso.app",
        "/Users/other/Applications/Keepresso.app"
    ] {
        #expect(!HelperInstallation.ownsRegistration(bundleURL: URL(fileURLWithPath: path), homeURL: home))
    }
}

@Test @MainActor func helperRecoveryWaitsForLaunchdWithoutChangingRegistration() async {
    var replies: [Int?] = [nil, nil, 9]
    var delays: [TimeInterval] = []
    let version = await HelperRecoveryProbe.version(
        ping: {
            guard !replies.isEmpty else { Issue.record("Pinged more than three times"); return nil }
            return replies.removeFirst()
        },
        wait: { delays.append($0) }
    )
    #expect(version == 9)
    #expect(delays == [1, 3])
    #expect(replies.isEmpty)
}

@Test @MainActor func helperRecoveryAcceptsAnOldDaemonAsAlive() async {
    var pings = 0
    let version = await HelperRecoveryProbe.version(
        ping: { pings += 1; return 8 },
        wait: { _ in Issue.record("A responding daemon must not be retried") }
    )
    #expect(version == 8)
    #expect(pings == 1)
}

@Test @MainActor func helperRecoveryStopsAfterThreeFailedHandshakes() async {
    var pings = 0
    let version = await HelperRecoveryProbe.version(
        ping: { pings += 1; return nil }, wait: { _ in }
    )
    #expect(version == nil)
    #expect(pings == 3)
}

@Test @MainActor func helperRecoveryHonorsACustomSchedule() async {
    // The post-update handshake waits out a slow launchd spawn on extra
    // rounds instead of giving up after the default three pings.
    var replies: [Int?] = [nil, nil, nil, 9]
    var delays: [TimeInterval] = []
    let version = await HelperRecoveryProbe.version(
        ping: { replies.isEmpty ? nil : replies.removeFirst() },
        wait: { delays.append($0) },
        delays: [0.0, 1.0, 3.0, 30.0]
    )
    #expect(version == 9)
    #expect(delays == [1.0, 3.0, 30.0])
    #expect(replies.isEmpty)
}

@Test @MainActor func helperRecoveryWaitsOutASlowColdStartSpawn() async {
    // The cold-start schedule: pings at roughly 0, 1, 4, 14, 34, 64, 94 and
    // 124 seconds. A daemon launchd only hands over after a minute and a half
    // is still found, instead of being called broken at the old ~30s ceiling.
    let schedule: [TimeInterval] = [0.0, 1.0, 3.0, 10.0, 20.0, 30.0, 30.0, 30.0]
    var replies: [Int?] = [nil, nil, nil, nil, nil, nil, 7]
    var waited: [TimeInterval] = []
    let version = await HelperRecoveryProbe.version(
        ping: { replies.isEmpty ? nil : replies.removeFirst() },
        wait: { waited.append($0) },
        delays: schedule
    )
    #expect(version == 7)
    // Answered on the seventh ping, so six waits elapsed: ~94 seconds in.
    #expect(waited == [1.0, 3.0, 10.0, 20.0, 30.0, 30.0])
    #expect(waited.reduce(0, +) == 94)
}

@Test @MainActor func helperRecoveryGivesUpOnceTheScheduleIsSpent() async {
    // Nothing ever answers: every round is spent and the probe reports a
    // genuinely dead daemon rather than waiting forever.
    var pings = 0
    let version = await HelperRecoveryProbe.version(
        ping: { pings += 1; return nil },
        wait: { _ in },
        delays: [0.0, 1.0, 3.0, 10.0, 20.0, 30.0, 30.0, 30.0]
    )
    #expect(version == nil)
    #expect(pings == 8)
}

@Test @MainActor func helperRecoveryDoesNotRetryAfterCancellation() async {
    var pings = 0
    let version = await HelperRecoveryProbe.version(
        ping: { pings += 1; return nil }, wait: { _ in throw CancellationError() }
    )
    #expect(version == nil)
    #expect(pings == 1)
}
