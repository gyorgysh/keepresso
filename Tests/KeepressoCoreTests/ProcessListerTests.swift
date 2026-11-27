import Testing
import Foundation
@testable import KeepressoCore

private final class FetchStub: @unchecked Sendable {
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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSinceReferenceDate: 0)

    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private func eventually(_ condition: @escaping () -> Bool) async -> Bool {
    for _ in 0 ..< 400 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@Test func firstReadIsEmptyThenRefreshLands() async {
    let stub = FetchStub(output: "node server.js\nffmpeg -i in.mov")
    let clock = TestClock()
    let lister = PSProcessLister(ttl: 3, now: { clock.now }, fetch: stub.fetch)

    #expect(lister.current.isEmpty)
    #expect(await eventually { lister.current == ["node server.js", "ffmpeg -i in.mov"] })
}

@Test func freshCacheDoesNotRefetch() async {
    let stub = FetchStub(output: "node server.js")
    let clock = TestClock()
    let lister = PSProcessLister(ttl: 3, now: { clock.now }, fetch: stub.fetch)

    _ = lister.current
    #expect(await eventually { stub.callCount == 1 })

    clock.advance(2)
    for _ in 0 ..< 5 { #expect(lister.current == ["node server.js"]) }
    #expect(stub.callCount == 1)
}

@Test func staleReadReturnsSnapshotImmediatelyAndRefreshes() async {
    let stub = FetchStub(output: "old")
    let clock = TestClock()
    let lister = PSProcessLister(ttl: 3, now: { clock.now }, fetch: stub.fetch)

    _ = lister.current
    #expect(await eventually { stub.callCount == 1 })

    stub.output = "new"
    clock.advance(4)
    #expect(lister.current == ["old"])
    #expect(await eventually { lister.current == ["new"] })
    #expect(stub.callCount == 2)
}

@Test func onlyOneRefreshInFlightAtATime() async {
    let stub = FetchStub(output: "a")
    let clock = TestClock()
    let lister = PSProcessLister(ttl: 3, now: { clock.now }, fetch: stub.fetch)

    for _ in 0 ..< 5 { _ = lister.current }
    #expect(await eventually { stub.callCount >= 1 })
    _ = await eventually { false }
    #expect(stub.callCount == 1)
}

@Test func failedFetchResetsTheLatchAndKeepsTheSnapshot() async {
    let stub = FetchStub(output: "node server.js")
    let clock = TestClock()
    let lister = PSProcessLister(ttl: 3, now: { clock.now }, fetch: stub.fetch)

    _ = lister.current
    #expect(await eventually { lister.current == ["node server.js"] })

    stub.output = nil
    clock.advance(4)
    #expect(lister.current == ["node server.js"])
    #expect(await eventually { stub.callCount == 2 })
    #expect(lister.current == ["node server.js"])

    stub.output = "recovered"
    clock.advance(4)
    _ = lister.current
    #expect(await eventually { lister.current == ["recovered"] })
    #expect(stub.callCount == 3)
}

@Test func firstFetchFailureLeavesEmptyUntilALaterRefresh() async {
    let stub = FetchStub(output: nil)
    let clock = TestClock()
    let lister = PSProcessLister(ttl: 3, now: { clock.now }, fetch: stub.fetch)

    _ = lister.current
    #expect(await eventually { stub.callCount == 1 })
    #expect(lister.current.isEmpty)

    stub.output = "recovered"
    clock.advance(4)
    _ = lister.current
    #expect(await eventually { lister.current == ["recovered"] })
    #expect(stub.callCount == 2)
}
