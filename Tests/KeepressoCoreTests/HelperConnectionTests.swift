import Foundation
import Testing
@testable import KeepressoCore

/// The three harmless selectors used by the anonymous test endpoint. The
/// exported object intentionally implements only these; calling any other
/// HelperXPCProtocol verb would raise.
private final class OverlappingHelper: NSObject, @unchecked Sendable {
    let slowCallStarted = DispatchSemaphore(value: 0)
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
        reply(HelperService.protocolVersion)
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
    let helper = OverlappingHelper()
    let disconnected = DispatchSemaphore(value: 0)

    func waitForDisconnect() -> Bool {
        disconnected.wait(timeout: .now() + 10) == .success
    }
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = helper
        connection.invalidationHandler = { [weak self] in self?.disconnected.signal() }
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
/// for the wrong reason. A global queue grows threads on demand.
private final class BackgroundCall: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result = false

    init(_ work: @escaping @Sendable () -> Bool) {
        DispatchQueue.global().async { [self] in
            let ok = work()
            lock.lock()
            result = ok
            lock.unlock()
            finished.signal()
        }
    }

    /// The call's result, or nil when it hadn't returned in time. Generous
    /// like `waitForSlowCall` above: same loaded-runner reason.
    func value(timeout: TimeInterval = 30) -> Bool? {
        guard finished.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

// A generous client timeout: these tests are about the order calls finish in,
// not about how long one waits. The regression they guard fails fast (the
// error handler answers the moment a connection is cancelled underneath).
private let testCallTimeout: TimeInterval = 30

@Test func completedHelperPingDoesNotCancelAnOverlappingWrite() {
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
    let started = delegate.helper.waitForSlowCall()
    #expect(started)
    guard started else { _ = slow.value(); return }
    #expect(client.ping())
    // ping() has returned, including its connection-release housekeeping.
    // The other reply must still be deliverable on the shared connection.
    delegate.helper.finishSlowCall()
    #expect(slow.value() == true)
}

@Test func releasingTheLastHelperHoldDisconnectsForDaemonRetirement() {
    let delegate = AnonymousHelperListener()
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate(); delegate.stop() }
    let endpoint = listener.endpoint
    let client = XPCHelperClient(
        timeout: testCallTimeout, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) }
    )
    #expect(client.setSleepHold(true))
    #expect(client.setSleepHold(false))
    // No further ping should be needed to let the old daemon retire.
    #expect(delegate.waitForDisconnect())
}
