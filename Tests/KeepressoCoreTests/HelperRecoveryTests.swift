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
        "/Volumes/Keepresso/Applications/Keepresso.app",
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

@Test @MainActor func helperRecoveryDoesNotRetryAfterCancellation() async {
    var pings = 0
    let version = await HelperRecoveryProbe.version(
        ping: { pings += 1; return nil }, wait: { _ in throw CancellationError() }
    )
    #expect(version == nil)
    #expect(pings == 1)
}
