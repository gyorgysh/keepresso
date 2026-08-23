import Testing
import Foundation
@testable import KeepressoCore

private final class FakeRemapper: KeyboardRemapping, @unchecked Sendable {
    var current = KeyboardKeyMapping(entries: [
        .init(src: 1, dst: 2),
        .init(src: 3, dst: 4),
    ])
    var applied: [KeyboardKeyMapping] = []
    var applySucceeds = true

    func currentMapping() -> KeyboardKeyMapping { current }

    func apply(_ mapping: KeyboardKeyMapping) -> Bool {
        applied.append(mapping)
        guard applySucceeds else { return false }
        current = mapping
        return true
    }
}

private final class MemoryMarker: KeyboardLockMarking, @unchecked Sendable {
    var stored: KeyboardKeyMapping?

    func save(original: KeyboardKeyMapping) { stored = original }
    func load() -> KeyboardKeyMapping? { stored }
    func clear() { stored = nil }
}

private final class FakeLocker: KeyboardLocking, @unchecked Sendable {
    var locked = false
    var lockResult: KeyboardLockResult = .applied
    private(set) var lockCalls = 0
    private(set) var unlockCalls = 0
    private(set) var restoreCalls = 0

    func lock() -> KeyboardLockResult {
        lockCalls += 1
        if lockResult != .cancelled { locked = true }
        return lockResult
    }

    func unlock() {
        unlockCalls += 1
        locked = false
    }

    var isLocked: Bool { locked }

    func restoreIfNeeded() {
        restoreCalls += 1
        if locked { unlock() }
    }
}

private final class FakeKeyboardHelper: PrivilegedHelperCalling, @unchecked Sendable {
    var version = HelperService.protocolVersion
    var lockSucceeds = true
    var unlockSucceeds = true
    private(set) var calls: [Bool] = []

    func ping() -> Bool { version == HelperService.protocolVersion }
    func pingVersion() -> Int? { version }
    func setSleepDisabled(_ disabled: Bool) -> Bool { true }
    func setSleepHold(_ holding: Bool) -> Bool { true }
    func setAWDLHold(_ holding: Bool) -> Bool { true }
    func setFanHold(_ holding: Bool, percent: Int) -> Bool { true }
    func fanHoldDropped() -> Bool? { false }
    func setPriorityHold(_ holding: Bool, pid: Int) -> Bool { true }
    func sleepNow() -> Bool { true }
    func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool { true }
    func flushDNS() -> Bool { true }
    func setKeyboardLock(_ holding: Bool) -> Bool {
        calls.append(holding)
        return holding ? lockSucceeds : unlockSucceeds
    }
}

@Test func lockWritesMarkerAndUnlockRestoresTheCapturedMapping() {
    let remapper = FakeRemapper()
    let marker = MemoryMarker()
    let original = remapper.current
    let locker = KeyboardLocker(remapper: remapper, marker: marker)

    #expect(locker.lock() == .applied)
    #expect(marker.stored == original)
    #expect(remapper.applied.last == .disabledKeyboard)
    #expect(locker.isLocked)

    locker.unlock()
    #expect(remapper.applied.last == original)
    #expect(remapper.applied.last != .empty)
    #expect(marker.stored == nil)
    #expect(!locker.isLocked)
}

@Test func leftoverMarkerRestoresOnLaunch() {
    let remapper = FakeRemapper()
    remapper.current = .disabledKeyboard
    let marker = MemoryMarker()
    marker.stored = KeyboardKeyMapping(entries: [.init(src: 9, dst: 8)])
    let locker = KeyboardLocker(remapper: remapper, marker: marker)

    locker.restoreIfNeeded()
    #expect(remapper.applied.last?.entries == [KeyboardKeyMapping.Entry(src: 9, dst: 8)])
    #expect(marker.stored == nil)
    #expect(!locker.isLocked)
}

@Test func failedUnlockKeepsTheMarkerAndStaysLocked() {
    let remapper = FakeRemapper()
    let marker = MemoryMarker()
    let original = remapper.current
    let locker = KeyboardLocker(remapper: remapper, marker: marker)

    #expect(locker.lock() == .applied)
    remapper.applySucceeds = false
    locker.unlock()
    #expect(locker.isLocked)
    #expect(marker.stored == original)
}

@Test func cancelledUnlockPromptKeepsTheLock() {
    let remapper = FakeRemapper()
    remapper.applySucceeds = false
    let marker = MemoryMarker()
    let original = remapper.current
    var privilegedCalls = 0
    let locker = KeyboardLocker(
        remapper: remapper,
        marker: marker,
        privilegedApply: { mapping in
            privilegedCalls += 1
            if mapping == .disabledKeyboard {
                remapper.current = mapping
                return .applied
            }
            return .cancelled
        }
    )

    #expect(locker.lock() == .applied)
    locker.unlock()
    #expect(privilegedCalls == 2)
    #expect(locker.isLocked)
    #expect(marker.stored == original)
}

@Test func failedLaunchRestoreKeepsTheMarkerAndStaysLocked() {
    let remapper = FakeRemapper()
    remapper.applySucceeds = false
    remapper.current = .disabledKeyboard
    let marker = MemoryMarker()
    let original = KeyboardKeyMapping(entries: [.init(src: 9, dst: 8)])
    marker.stored = original
    let locker = KeyboardLocker(remapper: remapper, marker: marker)

    locker.restoreIfNeeded()
    #expect(locker.isLocked)
    #expect(marker.stored == original)
    #expect(remapper.applied.last == original)
}

@Test func leftoverMarkerAlreadyMatchingCurrentClearsWithoutApply() {
    let remapper = FakeRemapper()
    let original = KeyboardKeyMapping(entries: [.init(src: 9, dst: 8)])
    remapper.current = original
    let marker = MemoryMarker()
    marker.stored = original
    let locker = KeyboardLocker(remapper: remapper, marker: marker)

    locker.restoreIfNeeded()
    #expect(!locker.isLocked)
    #expect(marker.stored == nil)
    #expect(remapper.applied.isEmpty)
}

@Test func leftoverMarkerIsANoOpWhenAbsent() {
    let remapper = FakeRemapper()
    let locker = KeyboardLocker(remapper: remapper, marker: MemoryMarker())
    locker.restoreIfNeeded()
    #expect(remapper.applied.isEmpty)
}

@Test func failedHidutilStillMarksLockedSoOverlayCanSwallowKeys() {
    let remapper = FakeRemapper()
    remapper.applySucceeds = false
    let marker = MemoryMarker()
    let original = remapper.current
    let locker = KeyboardLocker(remapper: remapper, marker: marker)

    #expect(locker.lock() == .overlayOnly)
    #expect(locker.isLocked)
    #expect(marker.stored == original)

    locker.unlock()
    #expect(!locker.isLocked)
    #expect(marker.stored == nil)
}

@Test func cancelledAdminPromptDoesNotLock() {
    let remapper = FakeRemapper()
    let marker = MemoryMarker()
    var privilegedCalls = 0
    let locker = KeyboardLocker(
        remapper: remapper,
        marker: marker,
        privilegedApply: { _ in
            privilegedCalls += 1
            return .cancelled
        }
    )

    #expect(locker.lock() == .cancelled)
    #expect(!locker.isLocked)
    #expect(marker.stored == nil)
    #expect(privilegedCalls == 1)
    #expect(remapper.applied.isEmpty)
}

@Test func helperLockSkipsTheAdminPrompt() {
    let remapper = FakeRemapper()
    let marker = MemoryMarker()
    let helper = FakeKeyboardHelper()
    var privilegedCalls = 0
    let locker = KeyboardLocker(
        remapper: remapper,
        marker: marker,
        helper: helper,
        helperAvailable: { true },
        privilegedApply: { _ in
            privilegedCalls += 1
            return .cancelled
        }
    )

    #expect(locker.lock() == .applied)
    #expect(helper.calls == [true])
    #expect(privilegedCalls == 0)
    #expect(locker.isLocked)

    locker.unlock()
    #expect(helper.calls == [true, false])
    #expect(privilegedCalls == 0)
}

@Test func staleHelperFallsThroughToPrivilegedApply() {
    let remapper = FakeRemapper()
    let helper = FakeKeyboardHelper()
    helper.version = 8
    var privilegedCalls = 0
    let locker = KeyboardLocker(
        remapper: remapper,
        marker: MemoryMarker(),
        helper: helper,
        helperAvailable: { true },
        privilegedApply: { _ in
            privilegedCalls += 1
            return .applied
        }
    )

    #expect(locker.lock() == .applied)
    #expect(helper.calls.isEmpty)
    #expect(privilegedCalls == 1)
}

@Test func launchRestoreDoesNotPrompt() {
    let remapper = FakeRemapper()
    let marker = MemoryMarker()
    marker.stored = KeyboardKeyMapping(entries: [.init(src: 1, dst: 0)])
    var privilegedCalls = 0
    let locker = KeyboardLocker(
        remapper: remapper,
        marker: marker,
        privilegedApply: { _ in
            privilegedCalls += 1
            return .applied
        }
    )
    locker.restoreIfNeeded()
    #expect(privilegedCalls == 0)
    #expect(marker.stored == nil)
}

@Test @MainActor func durationZeroMeansUntilClick() async {
    let locker = FakeLocker()
    var now = Date(timeIntervalSince1970: 1_000)
    let controller = KeyboardLockController(locker: locker, now: { now })
    #expect(await controller.lock(duration: 0) == .applied)
    #expect(controller.isLocked)
    #expect(controller.unlockAt == nil)
    now = now.addingTimeInterval(3_600)
    controller.tick()
    #expect(controller.isLocked)
    controller.unlock()
    #expect(!controller.isLocked)
}

@Test @MainActor func positiveDurationAutoUnlocksOnInjectedClock() async {
    let locker = FakeLocker()
    var now = Date(timeIntervalSince1970: 1_000)
    let controller = KeyboardLockController(locker: locker, now: { now })
    #expect(await controller.lock(duration: 30) == .applied)
    #expect(controller.unlockAt == now.addingTimeInterval(30))
    now = now.addingTimeInterval(29)
    controller.tick()
    #expect(controller.isLocked)
    now = now.addingTimeInterval(2)
    controller.tick()
    #expect(!controller.isLocked)
    #expect(locker.restoreCalls == 1)
}

@Test @MainActor func controllerCancelDoesNotShowAsLocked() async {
    let locker = FakeLocker()
    locker.lockResult = .cancelled
    let controller = KeyboardLockController(locker: locker)
    #expect(await controller.lock(duration: 60) == .cancelled)
    #expect(!controller.isLocked)
    #expect(controller.unlockAt == nil)
    #expect(!controller.isBusy)
}

@Test @MainActor func controllerOverlayOnlyIsNotGlobal() async {
    let locker = FakeLocker()
    locker.lockResult = .overlayOnly
    let controller = KeyboardLockController(locker: locker)
    #expect(await controller.lock(duration: 0) == .overlayOnly)
    #expect(controller.isLocked)
    #expect(!controller.isGlobal)
}

@Test @MainActor func controllerRestoreIfNeededCallsThrough() {
    let locker = FakeLocker()
    locker.locked = true
    let controller = KeyboardLockController(locker: locker)
    controller.restoreIfNeeded()
    #expect(locker.restoreCalls == 1)
    #expect(!controller.isLocked)
}

@Test @MainActor func controllerUnlockKeepsLockedWhenRestoreFails() async {
    let remapper = FakeRemapper()
    let marker = MemoryMarker()
    let locker = KeyboardLocker(remapper: remapper, marker: marker)
    let controller = KeyboardLockController(locker: locker)
    #expect(await controller.lock() == .applied)
    remapper.applySucceeds = false
    controller.unlock()
    #expect(controller.isLocked)
    #expect(marker.stored != nil)
}

@Test func hidutilGetParserReadsNeXTSTEPPairs() {
    // hidutil prints Dst before Src. Either order must parse.
    let dstFirst = """
    (
            {
            HIDKeyboardModifierMappingDst = 0;
            HIDKeyboardModifierMappingSrc = 30064771076;
        }
    )
    """
    #expect(KeyboardKeyMapping.parseHidutilGet(dstFirst).entries
        == [.init(src: 3_006_477_1076, dst: 0)])
    let srcFirst = """
    HIDKeyboardModifierMappingSrc = 30064771076
    HIDKeyboardModifierMappingDst = 0
    """
    #expect(KeyboardKeyMapping.parseHidutilGet(srcFirst).entries
        == [.init(src: 3_006_477_1076, dst: 0)])
    #expect(KeyboardKeyMapping.parseHidutilGet("(null)").entries.isEmpty)
    #expect(KeyboardKeyMapping.parseHidutilGet("").entries.isEmpty)
}

@Test func disabledKeyboardPutsSpecialMacKeysBeforeTheKeyboardPage() {
    let srcs = KeyboardKeyMapping.disabledKeyboard.entries.map(\.src)
    let missionControl = KeyboardKeyMapping.hidUsage(page: 0xFF01, usage: 0x10)
    let spotlight = KeyboardKeyMapping.hidUsage(page: 0xFF01, usage: 0x01)
    let dictation = KeyboardKeyMapping.hidUsage(page: 0x000C, usage: 0xCF)
    let search = KeyboardKeyMapping.hidUsage(page: 0x000C, usage: 0x221)
    let launchpad = KeyboardKeyMapping.hidUsage(page: 0xFF01, usage: 0x04)
    let fn = KeyboardKeyMapping.hidUsage(page: 0x00FF, usage: 0x03)
    let dnd = KeyboardKeyMapping.hidUsage(page: 0x0001, usage: 0x9B)
    let f3 = KeyboardKeyMapping.hidUsage(page: 0x0007, usage: 0x3C)
    let space = KeyboardKeyMapping.hidUsage(page: 0x0007, usage: 0x2C)
    let command = KeyboardKeyMapping.hidUsage(page: 0x0007, usage: 0xE3)
    let letterA = KeyboardKeyMapping.hidUsage(page: 0x0007, usage: 0x04)

    for usage in [missionControl, spotlight, dictation, search, launchpad, fn, dnd, f3, space, command] {
        #expect(srcs.contains(usage))
    }
    #expect(!srcs.contains(letterA))
    let specialIndex = srcs.firstIndex(of: missionControl)!
    let keyboardIndex = srcs.firstIndex(of: f3)!
    #expect(specialIndex < keyboardIndex)
    #expect(KeyboardKeyMapping.disabledKeyboard.entries.allSatisfy { $0.dst == 0 })
}

@Test func disabledKeyboardOmitsRestrictedAlphanumericUsages() {
    let restricted = KeyboardKeyMapping.disabledKeyboard.entries.filter {
        $0.src >> 32 == 0x0007 && KeyboardKeyMapping.isRestrictedKeyboardUsage($0.src & 0xffff_ffff)
    }
    #expect(restricted.isEmpty)
    #expect(KeyboardKeyMapping.isRestrictedKeyboardUsage(0x04))
    #expect(KeyboardKeyMapping.isRestrictedKeyboardUsage(0x27))
    #expect(KeyboardKeyMapping.isRestrictedKeyboardUsage(0x35))
    #expect(!KeyboardKeyMapping.isRestrictedKeyboardUsage(0x2C))
    #expect(!KeyboardKeyMapping.isRestrictedKeyboardUsage(0x3C))
    #expect(!KeyboardKeyMapping.isRestrictedKeyboardUsage(0xE3))
}

@Test func hidutilSetJSONNamesTheMappingKeys() {
    let mapping = KeyboardKeyMapping(entries: [.init(src: 1, dst: 2)])
    let json = mapping.hidutilSetJSON()
    #expect(json.contains("UserKeyMapping"))
    #expect(json.contains("HIDKeyboardModifierMappingSrc"))
    #expect(json.contains("HIDKeyboardModifierMappingDst"))
}

@Test func osascriptOutcomeTreatsCancelAsCancelled() {
    #expect(OsascriptKeyboardRemapper.outcome(status: 0, stderr: "") == .applied)
    #expect(OsascriptKeyboardRemapper.outcome(status: 1, stderr: "error -128") == .cancelled)
    #expect(OsascriptKeyboardRemapper.outcome(status: 1, stderr: "User canceled.") == .cancelled)
    #expect(OsascriptKeyboardRemapper.outcome(status: 1, stderr: "hidutil: failed") == .overlayOnly)
}
