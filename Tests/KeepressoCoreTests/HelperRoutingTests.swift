import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Fakes

private final class FakeHelperClient: PrivilegedHelperCalling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    var pingSucceeds = true
    var holdSucceeds = true

    func ping() -> Bool {
        record("ping")
        return pingSucceeds
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        record("setSleepDisabled(\(disabled))")
        return holdSucceeds
    }

    func setSleepHold(_ holding: Bool) -> Bool {
        record("setSleepHold(\(holding))")
        return holdSucceeds
    }

    func setAWDLHold(_ holding: Bool) -> Bool {
        record("setAWDLHold(\(holding))")
        return holdSucceeds
    }

    private func record(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }
}

private final class FakeFallbackSleepWatchdog: SleepWatchdogLaunching, @unchecked Sendable {
    var flagPresent = false
    private(set) var startCalls = 0
    private(set) var removeCalls = 0

    func isFlagPresent() -> Bool { flagPresent }
    func createFlag() -> Bool {
        flagPresent = true
        return true
    }
    func removeFlag() {
        flagPresent = false
        removeCalls += 1
    }
    func startHelper(appPID: Int32) -> SleepSettingResult {
        startCalls += 1
        return .applied
    }
}

private final class FakeFallbackSleepControl: SleepSettingControlling, @unchecked Sendable {
    var reading: Bool? = false
    private(set) var writes: [Bool] = []

    func isSleepDisabled() -> Bool? { reading }
    func setSleepDisabled(_ disabled: Bool) -> SleepSettingResult {
        writes.append(disabled)
        return .applied
    }
}

// MARK: - Watchdog routing

@Test func routedSleepWatchdogUsesDaemonWithoutAnyPromptWhenInstalled() {
    let client = FakeHelperClient()
    let fallback = FakeFallbackSleepWatchdog()
    let routed = RoutedSleepWatchdog(
        daemon: HelperDaemonSleepWatchdog(helper: client),
        fallback: fallback,
        helperInstalled: { true }
    )

    #expect(routed.createFlag())
    // "Starting the helper" is a version-checked ping: nothing spawns, no prompt.
    #expect(routed.startHelper(appPID: 1) == .applied)
    #expect(routed.isFlagPresent())
    routed.removeFlag()
    #expect(!routed.isFlagPresent())

    #expect(client.calls == ["setSleepHold(true)", "ping", "setSleepHold(false)"])
    #expect(fallback.startCalls == 0)
    #expect(!fallback.flagPresent)
}

@Test func routedSleepWatchdogFallsBackWhenHelperMissing() {
    let client = FakeHelperClient()
    let fallback = FakeFallbackSleepWatchdog()
    let routed = RoutedSleepWatchdog(
        daemon: HelperDaemonSleepWatchdog(helper: client),
        fallback: fallback,
        helperInstalled: { false }
    )

    #expect(routed.createFlag())
    #expect(routed.startHelper(appPID: 1) == .applied)
    #expect(routed.isFlagPresent())
    routed.removeFlag()

    #expect(fallback.startCalls == 1)
    // Not installed and never held via the daemon: no XPC traffic at all.
    #expect(client.calls.isEmpty)
}

@Test func routedWatchdogReleasesADaemonHoldEvenAfterUninstall() {
    let client = FakeHelperClient()
    let installed = LockedFlag(true)
    let routed = RoutedSleepWatchdog(
        daemon: HelperDaemonSleepWatchdog(helper: client),
        fallback: FakeFallbackSleepWatchdog(),
        helperInstalled: { installed.value }
    )

    #expect(routed.createFlag())
    // The helper is removed mid-hold: the release must still reach the daemon
    // side (its local hold bookkeeping), not silently route away.
    installed.value = false
    routed.removeFlag()
    #expect(client.calls.contains("setSleepHold(false)"))
    #expect(!routed.isFlagPresent())
}

@Test func routedAWDLWatchdogMirrorsTheSleepRouting() {
    let client = FakeHelperClient()
    let routed = RoutedAWDLWatchdog(
        daemon: HelperDaemonAWDLWatchdog(helper: client),
        fallback: OsascriptAWDLWatchdog(
            flagURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("keepresso-test-\(UUID().uuidString).flag")
        ),
        helperInstalled: { true }
    )

    #expect(routed.createFlag())
    #expect(routed.startHelper(appPID: 1) == .started)
    routed.removeFlag()
    #expect(client.calls == ["setAWDLHold(true)", "ping", "setAWDLHold(false)"])

    // A dead daemon surfaces as a failure, not a hang or a false start.
    client.pingSucceeds = false
    #expect(routed.startHelper(appPID: 1) == .failed("The Keepresso helper isn't responding."))
}

// MARK: - Sleep-setting routing

@Test func routedSleepControlReadsLocallyAndWritesThroughTheHelper() {
    let client = FakeHelperClient()
    let fallback = FakeFallbackSleepControl()
    let routed = RoutedSleepControl(
        helper: client,
        fallback: fallback,
        helperInstalled: { true }
    )

    // Reads never need privileges; they stay on the plain pmset backend.
    fallback.reading = true
    #expect(routed.isSleepDisabled() == true)

    #expect(routed.setSleepDisabled(true) == .applied)
    #expect(client.calls == ["setSleepDisabled(true)"])
    #expect(fallback.writes.isEmpty)

    client.holdSucceeds = false
    #expect(routed.setSleepDisabled(false) == .failed("The Keepresso helper couldn't change the setting."))
}

@Test func routedSleepControlPromptsViaFallbackWhenHelperMissing() {
    let client = FakeHelperClient()
    let fallback = FakeFallbackSleepControl()
    let routed = RoutedSleepControl(
        helper: client,
        fallback: fallback,
        helperInstalled: { false }
    )

    #expect(routed.setSleepDisabled(true) == .applied)
    #expect(fallback.writes == [true])
    #expect(client.calls.isEmpty)
}

/// A tiny lock-guarded flag for simulating install-state flips mid-test.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ initial: Bool) {
        stored = initial
    }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
