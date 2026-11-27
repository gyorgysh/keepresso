import Foundation
import Testing
@testable import KeepressoCore

private final class OverlappingHelper: NSObject, @unchecked Sendable {
    let slowCallStarted = DispatchSemaphore(value: 0)
    private var version: Int
    private var lowPowerCalls = 0
    private var pingCalls = 0
    init(version: Int = HelperService.protocolVersion) { self.version = version }
    var lowPowerCallCount: Int { lock.lock(); defer { lock.unlock() }; return lowPowerCalls }
    var pingCallCount: Int { lock.lock(); defer { lock.unlock() }; return pingCalls }
    @objc func setLowPowerHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); lowPowerCalls += 1; lock.unlock()
        reply(true)
    }
    @objc func setAdapterLowPowerHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); lowPowerCalls += 1; lock.unlock()
        reply(true)
    }
    private let lock = NSLock()
    private var pendingReply: (@Sendable (Bool) -> Void)?

    @objc func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        pendingReply = reply
        lock.unlock()
        slowCallStarted.signal()
    }

    @objc func setSleepHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }

    @objc func ping(reply: @escaping @Sendable (Int) -> Void) {
        lock.lock(); pingCalls += 1; let replyVersion = version; lock.unlock()
        reply(replyVersion)
    }
    func replaceVersion(with version: Int) {
        lock.lock(); self.version = version; lock.unlock()
    }

    func waitForSlowCall() -> Bool {
        slowCallStarted.wait(timeout: .now() + 30) == .success
    }

    func finishSlowCall() {
        lock.lock()
        let reply = pendingReply
        pendingReply = nil
        lock.unlock()
        reply?(true)
    }
}

private final class AnonymousHelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let helper: OverlappingHelper
    init(version: Int = HelperService.protocolVersion) { helper = OverlappingHelper(version: version) }
    var activeConnections: Int { lock.lock(); defer { lock.unlock() }; return connections.count }
    func waitForNoConnections() -> Bool {
        for _ in 0..<200 { if activeConnections == 0 { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return false
    }
    let disconnected = DispatchSemaphore(value: 0)

    func waitForDisconnect() -> Bool {
        disconnected.wait(timeout: .now() + 10) == .success
    }
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = helper
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else { return }
            self.lock.lock()
            self.connections.removeAll { $0 === connection }
            self.lock.unlock()
            self.disconnected.signal()
        }
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.resume()
        return true
    }

    func stop() {
        lock.lock()
        let old = connections
        connections = []
        lock.unlock()
        old.forEach { $0.invalidate() }
    }
}

private final class BackgroundCallState: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result = false
}

private final class BackgroundCall: @unchecked Sendable {
    private let state: BackgroundCallState
    private let thread: Thread

    init(_ work: @escaping @Sendable () -> Bool) {
        let state = BackgroundCallState()
        let thread = Thread { [state] in
            let ok = work()
            state.lock.lock()
            state.result = ok
            state.lock.unlock()
            state.finished.signal()
        }
        thread.name = "keepresso-test-helper-call"
        thread.qualityOfService = .userInitiated
        self.state = state
        self.thread = thread
        thread.start()
    }

    func value(timeout: TimeInterval = 30) -> Bool? {
        guard state.finished.wait(timeout: .now() + timeout) == .success else { return nil }
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.result
    }
}

private let testCallTimeout: TimeInterval = 30

private func blockingValue<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: work()) }.start()
    }
}

@Test func completedHelperPingDoesNotCancelAnOverlappingWrite() async {
    let delegate = AnonymousHelperListener()
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate(); delegate.stop() }
    let endpoint = listener.endpoint
    let client = XPCHelperClient(
        timeout: testCallTimeout, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) }
    )
    let slow = BackgroundCall { client.setSleepDisabled(true) }
    let started = await blockingValue { delegate.helper.waitForSlowCall() }
    #expect(started)
    guard started else { _ = await blockingValue { slow.value() }; return }
    #expect(await blockingValue { client.ping() })
    delegate.helper.finishSlowCall()
    #expect(await blockingValue { slow.value() } == true)
}

@Test func releasingTheLastHelperHoldDisconnectsForDaemonRetirement() async {
    let delegate = AnonymousHelperListener()
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate(); delegate.stop() }
    let endpoint = listener.endpoint
    let client = XPCHelperClient(
        timeout: testCallTimeout, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) }
    )
    #expect(await blockingValue { client.setSleepHold(true) })
    #expect(await blockingValue { client.setSleepHold(false) })
    #expect(await blockingValue { delegate.waitForDisconnect() })
}

@Test func lowPowerHoldKeepsItsConnectionUntilReleased() async {
    let delegate = AnonymousHelperListener()
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate; listener.resume()
    defer { listener.invalidate(); delegate.stop() }
    let endpoint = listener.endpoint
    let client = XPCHelperClient(timeout: testCallTimeout, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) })
    #expect(await blockingValue { client.setLowPowerHold(true) })
    #expect(await blockingValue { client.ping() })
    #expect(delegate.activeConnections > 0)
    #expect(await blockingValue { client.setLowPowerHold(false) })
    #expect(await blockingValue { delegate.waitForNoConnections() })
    #expect(delegate.helper.lowPowerCallCount == 2)
}
@Test func lowPowerHoldDoesNotCallAnOlderDaemonsMissingVerb() async {
    let delegate = AnonymousHelperListener(version: 9)
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate; listener.resume()
    defer { listener.invalidate(); delegate.stop() }
    let endpoint = listener.endpoint
    let client = XPCHelperClient(timeout: testCallTimeout, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) })
    #expect(await blockingValue { !client.setLowPowerHold(true) })
    #expect(delegate.helper.pingCallCount == 1)
    #expect(delegate.helper.lowPowerCallCount == 0)
}

@Test func adapterLowPowerHoldKeepsConnectionUntilBothProfilesRelease() async {
    let delegate = AnonymousHelperListener()
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate; listener.resume()
    defer { listener.invalidate(); delegate.stop() }
    let endpoint = listener.endpoint
    let client = XPCHelperClient(timeout: testCallTimeout, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) })
    #expect(await blockingValue { client.setLowPowerHold(true) })
    #expect(await blockingValue { client.setAdapterLowPowerHold(true) })
    #expect(await blockingValue { client.setLowPowerHold(false) })
    #expect(delegate.activeConnections > 0)
    #expect(await blockingValue { client.ping() })
    #expect(await blockingValue { client.setAdapterLowPowerHold(false) })
    #expect(await blockingValue { delegate.waitForNoConnections() })
    #expect(delegate.helper.lowPowerCallCount == 4)
}

@Test func adapterLowPowerHoldDoesNotCallAnOlderDaemonsMissingVerb() async {
    let delegate = AnonymousHelperListener(version: 11)
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate; listener.resume()
    defer { listener.invalidate(); delegate.stop() }
    let endpoint = listener.endpoint
    let client = XPCHelperClient(timeout: testCallTimeout, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) })
    #expect(await blockingValue { !client.setAdapterLowPowerHold(true) })
    #expect(delegate.helper.pingCallCount == 1)
    #expect(delegate.helper.lowPowerCallCount == 0)
}

@Test func unsupportedLowPowerReleaseDoesNotPinTheOlderDaemonAfterReplacement() async {
    for adapter in [false, true] {
        let delegate = AnonymousHelperListener()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate; listener.resume()
        defer { listener.invalidate(); delegate.stop() }
        let endpoint = listener.endpoint
        let client = XPCHelperClient(timeout: testCallTimeout, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) })
        #expect(await blockingValue { adapter ? client.setAdapterLowPowerHold(true) : client.setLowPowerHold(true) })
        delegate.helper.replaceVersion(with: adapter ? 11 : 9)
        #expect(await blockingValue { !(adapter ? client.setAdapterLowPowerHold(false) : client.setLowPowerHold(false)) })
        #expect(await blockingValue { delegate.waitForNoConnections() })
        #expect(delegate.helper.lowPowerCallCount == 1)
    }
}

@Test @MainActor func lowPowerDisarmDuringBatteryWriteNeverEngagesAdapterAndRestoresImmediately() async throws {
    let helper = HelperRoutingTestClient()
    let controller = ClosedLidLowPowerController(helper: helper)
    let barrier = BlockingLowPowerTestCall { finish in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                controller.tick(enabled: false, lidClosed: false, closedDisplayActive: true, onBattery: true, helperAvailable: true, allowOnAC: true)
                finish()
            }
        }
    }
    helper.lowPowerBarrier = barrier
    defer { barrier.release() }
    controller.tick(enabled: true, lidClosed: true, closedDisplayActive: true, onBattery: true, helperAvailable: true, allowOnAC: true)
    for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(!controller.holding && !controller.hasPendingRequests)
    #expect(controller.status == .off)
    #expect(helper.calls == ["setLowPowerHold(true)", "setLowPowerHold(false)"])
}
