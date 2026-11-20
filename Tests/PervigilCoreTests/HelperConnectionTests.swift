import Foundation
import Testing
@testable import PervigilCore

/// The harmless selectors used by the anonymous test endpoint. The
/// exported object intentionally implements only these; calling any other
/// HelperXPCProtocol verb would raise.
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

    /// Generous on purpose: on a 3-core CI runner under full-suite parallel
    /// load, the background hop plus the XPC handshake can take seconds
    /// (locally this is milliseconds). Only the wait grows, never what the
    /// test asserts.
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

/// One blocking helper call, running on a thread of its own.
///
/// Not `Task.detached`: that borrows a thread from the cooperative pool, which
/// is only as wide as the machine has cores. On a two or three core CI runner,
/// with the rest of the suite running in parallel, a blocked call can hold the
/// pool long enough that the overlapping call never starts and the test fails
/// for the wrong reason. Not `DispatchQueue.global()` either: under the same
/// full-suite load the workqueue did not schedule the block for ~20s while
/// over a thousand sibling tests churned. A dedicated thread starts via
/// `pthread_create`, immune to pool pressure on either pool.
private final class BackgroundCallState: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result = false
}

private final class BackgroundCall: @unchecked Sendable {
    private let state: BackgroundCallState
    private let thread: Thread

    init(_ work: @escaping @Sendable () -> Bool) {
        // Locals, so the thread takes no `self` capture: `self.thread` is
        // not set yet and must not be captured during init.
        let state = BackgroundCallState()
        let thread = Thread { [state] in
            let ok = work()
            state.lock.lock()
            state.result = ok
            state.lock.unlock()
            state.finished.signal()
        }
        thread.name = "pervigil-test-helper-call"
        thread.qualityOfService = .userInitiated
        self.state = state
        self.thread = thread
        thread.start()
    }

    /// The call's result, or nil when it hadn't returned in time. Generous
    /// like `waitForSlowCall` above: same loaded-runner reason.
    func value(timeout: TimeInterval = 30) -> Bool? {
        guard state.finished.wait(timeout: .now() + timeout) == .success else { return nil }
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.result
    }
}

// A generous client timeout: these tests are about the order calls finish in,
// not about how long one waits. The regression they guard fails fast (the
// error handler answers the moment a connection is cancelled underneath).
private let testCallTimeout: TimeInterval = 30

/// A semaphore wait on a Swift Testing worker can starve the anonymous
/// listener's replies on small runners. Suspend the test while a dedicated
/// thread performs each blocking call, including rendezvous and teardown waits.
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
    // ping() has returned, including its connection-release housekeeping.
    // The other reply must still be deliverable on the shared connection.
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
    // No further ping should be needed to let the old daemon retire.
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
    // A failed rendezvous must not pass as a successful version guard.
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
        // An older daemon cannot confirm restoration, but its connection must
        // be free to retire so the current daemon can settle the restore debt.
        #expect(await blockingValue { !(adapter ? client.setAdapterLowPowerHold(false) : client.setLowPowerHold(false)) })
        #expect(await blockingValue { delegate.waitForNoConnections() })
        #expect(delegate.helper.lowPowerCallCount == 1)
    }
}

// This blocking rendezvous shares the isolated XPC cohort so it cannot
// occupy a cooperative worker while the full core suite needs the pool.
@Test @MainActor func lowPowerDisarmDuringBatteryWriteNeverEngagesAdapterAndRestoresImmediately() async throws {
    let helper = HelperRoutingTestClient()
    let controller = ClosedLidLowPowerController(helper: helper)
    // A suspended async test may need the worker occupied by the paused
    // write. Dispatch the simulated settings change directly to the main
    // queue, then release the call, preserving the intended ordering.
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
