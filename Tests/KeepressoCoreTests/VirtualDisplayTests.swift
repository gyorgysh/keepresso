import Testing
import Foundation
@testable import KeepressoCore

/// Programmable fake virtual-display backend recording start/stop.
private final class FakeVirtualDisplay: VirtualDisplaying {
    var supported: Bool
    var succeed: Bool
    private(set) var startCalls: [VirtualDisplayConfig] = []
    private(set) var stopCalls = 0
    private var active = false

    init(supported: Bool = true, succeed: Bool = true) {
        self.supported = supported
        self.succeed = succeed
    }

    var isSupported: Bool { supported }
    var isActive: Bool { active }
    var displayID: UInt32? { active ? 42 : nil }
    var isMain = false
    func start(_ config: VirtualDisplayConfig) -> Bool {
        startCalls.append(config)
        active = succeed
        return succeed
    }
    func promoteToMain() -> Bool {
        isMain = succeed && active
        return isMain
    }
    func stop() { stopCalls += 1; active = false; isMain = false }
}

@MainActor
@Test func settingConfigStartsTheDisplay() {
    let backend = FakeVirtualDisplay()
    let controller = VirtualDisplayController(backend: backend)
    controller.config = VirtualDisplayConfig(width: 2560, height: 1440, hiDPI: true)
    #expect(backend.startCalls.count == 1)
    #expect(controller.isActive)
    #expect(controller.lastError == nil)
}

@MainActor
@Test func clearingConfigStopsTheDisplay() {
    let backend = FakeVirtualDisplay()
    let controller = VirtualDisplayController(backend: backend)
    controller.config = VirtualDisplayConfig(width: 1920, height: 1080)
    controller.config = nil
    #expect(backend.stopCalls >= 1)
    #expect(!controller.isActive)
}

@MainActor
@Test func unsupportedReportsErrorAndDoesNotStart() {
    let backend = FakeVirtualDisplay(supported: false)
    let controller = VirtualDisplayController(backend: backend)
    controller.config = VirtualDisplayConfig(width: 3840, height: 2160)
    #expect(backend.startCalls.isEmpty)
    #expect(controller.lastError != nil)
}

@MainActor
@Test func failedStartSurfacesError() {
    let backend = FakeVirtualDisplay(succeed: false)
    let controller = VirtualDisplayController(backend: backend)
    controller.config = VirtualDisplayConfig(width: 2560, height: 1440)
    #expect(controller.lastError != nil)
    #expect(!controller.isActive)
}

@Test func virtualDisplayConfigEncodesRoundTrip() throws {
    let config = VirtualDisplayConfig(width: 2880, height: 1620, hiDPI: false)
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(VirtualDisplayConfig.self, from: data) == config)
    #expect(config.label == "2880\u{00D7}1620")
}

@Test func automaticVirtualDisplayDecisionCoversTheStateMatrix() {
    let awake = DisplayTopologySnapshot.BuiltInDisplay(
        isOnline: true, isActive: true, isAsleep: false)
    let asleep = DisplayTopologySnapshot.BuiltInDisplay(
        isOnline: true, isActive: false, isAsleep: true)
    let transitional = DisplayTopologySnapshot.BuiltInDisplay(
        isOnline: true, isActive: false, isAsleep: false)

    #expect(VirtualDisplayAutoDecision.decide(
        power: .battery,
        topology: DisplayTopologySnapshot(builtIn: asleep, externalOnlineDisplayCount: 0)
    ) == .start)
    #expect(VirtualDisplayAutoDecision.decide(
        power: .battery,
        topology: DisplayTopologySnapshot(builtIn: awake, externalOnlineDisplayCount: 0)
    ) == .stop)
    #expect(VirtualDisplayAutoDecision.decide(
        power: .battery,
        topology: DisplayTopologySnapshot(builtIn: asleep, externalOnlineDisplayCount: 1)
    ) == .stop)
    #expect(VirtualDisplayAutoDecision.decide(power: .ac, topology: nil) == .stop)
    #expect(VirtualDisplayAutoDecision.decide(
        power: .battery,
        topology: DisplayTopologySnapshot(builtIn: transitional, externalOnlineDisplayCount: 0)
    ) == .hold)
    #expect(VirtualDisplayAutoDecision.decide(power: .unknown, topology: nil) == .hold)
}

@MainActor
@Test func virtualDisplayCanBePromotedOnlyAfterItStarts() {
    let backend = FakeVirtualDisplay()
    let controller = VirtualDisplayController(backend: backend)

    #expect(!controller.promoteToMain())
    controller.config = VirtualDisplayConfig(width: 1920, height: 1080)
    #expect(controller.promoteToMain())
    #expect(controller.isMain)
}
