import Testing
import Foundation
@testable import KeepressoCore

@Test func cacheProbesOnceWithinTheTTL() {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var probes = 0
    let cache = TTLCache<Int>(ttl: 1, now: { now }) { probes += 1; return probes }

    #expect(cache.current == 1)
    #expect(cache.current == 1) // still fresh: cached, not re-probed
    #expect(probes == 1)
}

@Test func cacheReprobesAfterTheTTLLapses() {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var probes = 0
    let cache = TTLCache<Int>(ttl: 1, now: { now }) { probes += 1; return probes }

    #expect(cache.current == 1)
    now = now.addingTimeInterval(1.5) // past the TTL
    #expect(cache.current == 2)
    #expect(probes == 2)
}

@Test func cacheTreatsAProbedNilAsARealValue() {
    // For an optional Value, a probed nil must be cached (not re-probed as a
    // miss): HostCPULoadReader's first delta read is nil and shouldn't re-run.
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var probes = 0
    let cache = TTLCache<Int?>(ttl: 1, now: { now }) { probes += 1; return nil }

    #expect(cache.current == nil)
    #expect(cache.current == nil)
    #expect(probes == 1) // the nil was cached, not treated as absent
}
