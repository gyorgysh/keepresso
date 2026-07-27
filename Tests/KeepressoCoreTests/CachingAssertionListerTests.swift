import Testing
import Foundation
@testable import KeepressoCore

private final class FakeAssertionLister: AssertionListing {
    var lists: [[PowerAssertionInfo]] = []
    private(set) var callCount = 0

    func current() -> [PowerAssertionInfo] {
        callCount += 1
        if lists.isEmpty { return [] }
        let index = min(callCount - 1, lists.count - 1)
        return lists[index]
    }
}

@Test func cachingAssertionListerReusesWithinTTL() {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let inner = FakeAssertionLister()
    inner.lists = [
        [PowerAssertionInfo(id: "a", pid: 1, processName: "Chrome", type: "PreventUserIdleSystemSleep", name: "n")],
        [PowerAssertionInfo(id: "b", pid: 2, processName: "Other", type: "PreventUserIdleSystemSleep", name: "n")],
    ]
    let cache = CachingAssertionLister(inner: inner, ttl: 3, now: { clock })

    #expect(cache.current().first?.processName == "Chrome")
    #expect(inner.callCount == 1)
    clock = clock.addingTimeInterval(2)
    #expect(cache.current().first?.processName == "Chrome")
    #expect(inner.callCount == 1)
    clock = clock.addingTimeInterval(2)
    #expect(cache.current().first?.processName == "Other")
    #expect(inner.callCount == 2)
}

@Test func cachingAssertionListerUncachedBypassesTTL() {
    let clock = Date(timeIntervalSinceReferenceDate: 0)
    let inner = FakeAssertionLister()
    inner.lists = [
        [PowerAssertionInfo(id: "a", pid: 1, processName: "Chrome", type: "PreventUserIdleSystemSleep", name: "n")],
        [PowerAssertionInfo(id: "b", pid: 2, processName: "Other", type: "PreventUserIdleSystemSleep", name: "n")],
    ]
    let cache = CachingAssertionLister(inner: inner, ttl: 3, now: { clock })

    _ = cache.current()
    #expect(cache.currentUncached().first?.processName == "Other")
    #expect(inner.callCount == 2)
}
