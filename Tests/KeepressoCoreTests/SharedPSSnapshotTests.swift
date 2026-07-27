import Testing
import Foundation
@testable import KeepressoCore

private final class RunStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _output: String?
    private var _callCount = 0

    init(output: String?) { _output = output }

    var callCount: Int { lock.withLock { _callCount } }
    var output: String? {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    func run() -> String? {
        lock.withLock {
            _callCount += 1
            return _output
        }
    }
}

private final class SnapshotClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSinceReferenceDate: 0)

    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@Test func sharedPSSnapshotCachesWithinTTL() {
    let stub = RunStub(output: "1 0 0.5 ?? /bin/zsh\n2 1 1.0 ttys001 node server.js")
    let clock = SnapshotClock()
    let snapshot = SharedPSSnapshot(ttl: 3, now: { clock.now }, run: stub.run)

    #expect(snapshot.fetchRaw()?.contains("node server.js") == true)
    #expect(stub.callCount == 1)
    clock.advance(2)
    #expect(snapshot.fetchRaw()?.contains("node server.js") == true)
    #expect(stub.callCount == 1)
}

@Test func sharedPSSnapshotRefetchesAfterTTL() {
    let stub = RunStub(output: "1 0 0.0 ?? first")
    let clock = SnapshotClock()
    let snapshot = SharedPSSnapshot(ttl: 3, now: { clock.now }, run: stub.run)

    #expect(snapshot.fetchRaw()?.contains("first") == true)
    stub.output = "1 0 0.0 ?? second"
    clock.advance(4)
    #expect(snapshot.fetchRaw()?.contains("second") == true)
    #expect(stub.callCount == 2)
}

@Test func sharedPSSnapshotDerivesCommandListing() {
    let rich = """
        1 0 0.5 ?? /bin/zsh
        42 1 12.0 ttys001 /opt/homebrew/bin/claude --resume
        """
    let listing = SharedPSSnapshot.commandListing(fromRich: rich)
    #expect(listing == "/bin/zsh\n/opt/homebrew/bin/claude --resume")
}

@Test func sharedPSSnapshotServesProcessAndAgentFetchesOnce() {
    let stub = RunStub(output: "10 1 2.0 ttys002 claude\n20 1 0.1 ?? /usr/bin/ssh")
    let clock = SnapshotClock()
    let snapshot = SharedPSSnapshot(ttl: 3, now: { clock.now }, run: stub.run)

    let commands = snapshot.fetchCommandListing()
    let raw = snapshot.fetchRaw()
    #expect(commands == "claude\n/usr/bin/ssh")
    #expect(raw?.contains("claude") == true)
    #expect(stub.callCount == 1)
}
