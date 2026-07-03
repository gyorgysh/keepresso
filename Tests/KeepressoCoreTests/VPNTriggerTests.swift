import Testing
import Foundation
@testable import KeepressoCore

private final class FakeVPNMonitor: VPNMonitoring {
    var connected: Bool
    init(connected: Bool) { self.connected = connected }
    var isConnected: Bool { connected }
}

@Test func vpnTriggerFollowsConnectionState() {
    let monitor = FakeVPNMonitor(connected: true)
    let trigger = VPNConnectedTrigger(monitor: monitor)
    #expect(trigger.isSatisfied())

    monitor.connected = false
    #expect(!trigger.isSatisfied())
}

@Test func vpnRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.vpnConnected
    #expect(rule.label == "VPN connected")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}

@Test func factoryBuildsAVPNTrigger() {
    let monitor = FakeVPNMonitor(connected: true)
    let factory = TriggerFactory(vpn: monitor)
    let engine = factory.makeEngine(from: RuleSet(rules: [.vpnConnected]))
    #expect(engine.isSatisfied())
}

@Test func scutilParserFindsAConnectedService() {
    let connected = """
    Available network connection services in the current set (*=enabled):
    * (Connected)     B49DFB1B-2977-4E52-9EC8-4A22E1F4F3A4 IPSec  "Work VPN"  [IPSec]
    * (Disconnected)  0F2A6C1E-9B7C-4F2E-A16B-8A3E5B0D6C11 VPN    "Home"     [com.wireguard.macos]
    """
    #expect(SCUtilVPNMonitor.hasConnectedService(in: connected))
}

@Test func scutilParserIgnoresDisconnectedAndGarbage() {
    let disconnected = """
    Available network connection services in the current set (*=enabled):
    * (Disconnected)  0F2A6C1E-9B7C-4F2E-A16B-8A3E5B0D6C11 VPN    "Home"     [com.wireguard.macos]
    """
    #expect(!SCUtilVPNMonitor.hasConnectedService(in: disconnected))
    #expect(!SCUtilVPNMonitor.hasConnectedService(in: ""))
    #expect(!SCUtilVPNMonitor.hasConnectedService(in: "no services"))
    // A service merely named "Connected" must not count; the state is the
    // parenthesized word.
    #expect(!SCUtilVPNMonitor.hasConnectedService(in: #"* (Disconnected) 1234 VPN "Connected" [VPN]"#))
}

@Test func vpnMonitorServesStaleVerdictAndRefreshesInBackground() async {
    let stub = VPNFetchStub(output: "* (Connected) 1234 VPN \"Work\" [VPN]")
    let clock = VPNTestClock()
    let monitor = SCUtilVPNMonitor(ttl: 3, now: { clock.now }, fetch: stub.fetch)

    // First read: nothing cached yet, kicks off the background fetch.
    #expect(!monitor.isConnected)
    #expect(await vpnEventually { monitor.isConnected })

    // Within the TTL, reads reuse the verdict without re-spawning scutil.
    clock.advance(2)
    for _ in 0 ..< 5 { #expect(monitor.isConnected) }
    #expect(stub.callCount == 1)

    // Past the TTL, the stale verdict returns instantly and the refresh
    // lands in the background.
    stub.output = "* (Disconnected) 1234 VPN \"Work\" [VPN]"
    clock.advance(4)
    #expect(monitor.isConnected)
    #expect(await vpnEventually { !monitor.isConnected })
    #expect(stub.callCount == 2)
}

// MARK: - Test doubles (mirroring ProcessListerTests' thread-safe stubs)

private final class VPNFetchStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _output: String?
    private var _callCount = 0

    init(output: String?) { _output = output }

    var callCount: Int { lock.withLock { _callCount } }
    var output: String? {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    func fetch() -> String? {
        lock.withLock {
            _callCount += 1
            return _output
        }
    }
}

private final class VPNTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSinceReferenceDate: 0)

    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private func vpnEventually(_ condition: @escaping () -> Bool) async -> Bool {
    for _ in 0 ..< 400 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
