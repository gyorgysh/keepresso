import Foundation
import Testing
@testable import KeepressoCore

/// Only these two harmless selectors are used by the anonymous test endpoint.
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

    func waitForSlowCall() -> Bool {
        slowCallStarted.wait(timeout: .now() + 3) == .success
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
        disconnected.wait(timeout: .now() + 3) == .success
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

@Test func completedHelperPingDoesNotCancelAnOverlappingWrite() async {
    let delegate = AnonymousHelperListener()
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate(); delegate.stop() }
    let endpoint = listener.endpoint
    let client = XPCHelperClient(timeout: 5, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) })
    let slow = Task.detached { client.setSleepDisabled(true) }
    let started = await Task.detached {
        delegate.helper.waitForSlowCall()
    }.value
    #expect(started)
    guard started else { _ = await slow.value; return }
    let ping = await Task.detached { client.ping() }.value
    #expect(ping)
    // ping() has returned, including its connection-release housekeeping.
    // The other reply must still be deliverable on the shared connection.
    delegate.helper.finishSlowCall()
    #expect(await slow.value)
}

@Test func releasingTheLastHelperHoldDisconnectsForDaemonRetirement() async {
    let delegate = AnonymousHelperListener()
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate(); delegate.stop() }
    let endpoint = listener.endpoint
    let client = XPCHelperClient(timeout: 5, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) })
    #expect(await Task.detached { client.setSleepHold(true) }.value)
    #expect(await Task.detached { client.setSleepHold(false) }.value)
    // No further ping should be needed to let the old daemon retire.
    #expect(await Task.detached { delegate.waitForDisconnect() }.value)
}
