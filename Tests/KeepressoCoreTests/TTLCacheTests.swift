import Testing
import Foundation
@testable import KeepressoCore

@Test func cacheProbesOnceWithinTheTTL() {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var probes = 0
    let cache = TTLCache<Int>(ttl: 1, now: { now }) { probes += 1; return probes }

    #expect(cache.current == 1)
    #expect(cache.current == 1)
    #expect(probes == 1)
}

@Test func cacheReprobesAfterTheTTLLapses() {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var probes = 0
    let cache = TTLCache<Int>(ttl: 1, now: { now }) { probes += 1; return probes }

    #expect(cache.current == 1)
    now = now.addingTimeInterval(1.5)
    #expect(cache.current == 2)
    #expect(probes == 2)
}

@Test func cacheTreatsAProbedNilAsARealValue() {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var probes = 0
    let cache = TTLCache<Int?>(ttl: 1, now: { now }) { probes += 1; return nil }

    #expect(cache.current == nil)
    #expect(cache.current == nil)
    #expect(probes == 1)
}
