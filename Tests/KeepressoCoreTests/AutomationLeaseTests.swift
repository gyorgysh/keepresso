import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Fixtures

private let base = Date(timeIntervalSince1970: 1_000_000)
private let idA = "aaaaaaaa-1111-2222-3333-444444444444"
private let idB = "bbbbbbbb-1111-2222-3333-444444444444"

private func record(
    id: String = idA,
    owner: String = "tester",
    tool: String = "test-tool",
    task: String = "a task",
    createdAt: Date = base,
    updatedAt: Date = base,
    ttl: Int = 300,
    maxLifetime: Int = 3_600,
    state: AutomationLeaseRecord.State = .active,
    endedAt: Date? = nil
) -> AutomationLeaseRecord {
    AutomationLeaseRecord(
        id: id, owner: owner, tool: tool, task: task,
        createdAt: createdAt, updatedAt: updatedAt,
        ttlSeconds: ttl, maxLifetimeSeconds: maxLifetime,
        state: state, endedAt: endedAt
    )
}

private final class FakeLeaseStore: LeaseRecordStoring {
    var records: [String: AutomationLeaseRecord] = [:]
    private(set) var deleted: [String] = []

    init(_ initial: [AutomationLeaseRecord] = []) {
        for r in initial { records[r.id] = r }
    }

    func loadAll() -> [AutomationLeaseRecord] { Array(records.values) }
    func write(_ record: AutomationLeaseRecord) { records[record.id] = record }
    func delete(id: String) {
        records[id] = nil
        deleted.append(id)
    }
}

// MARK: - Policy

@Test func canonicalIdAcceptsOnlyUUIDsAndLowercases() {
    #expect(AutomationLease.canonicalId("AAAAAAAA-1111-2222-3333-444444444444") == idA)
    #expect(AutomationLease.canonicalId(idA) == idA)
    #expect(AutomationLease.canonicalId("") == nil)
    #expect(AutomationLease.canonicalId("not-a-uuid") == nil)
    #expect(AutomationLease.canonicalId("../../etc/passwd") == nil)
}

@Test func sanitizedStripsControlCharactersAndCapsLength() {
    #expect(AutomationLease.sanitized("clean label") == "clean label")
    #expect(AutomationLease.sanitized("a\u{0000}b\u{0007}c\nd") == "abcd")
    #expect(AutomationLease.sanitized("  padded  ") == "padded")
    #expect(AutomationLease.sanitized(String(repeating: "x", count: 500)).count == 200)
}

@Test func clampsRejectHostileDurations() {
    #expect(AutomationLease.clampedTTL(0) == 10)
    #expect(AutomationLease.clampedTTL(-5) == 10)
    #expect(AutomationLease.clampedTTL(1_000_000_000) == 86_400)
    #expect(AutomationLease.clampedTTL(300) == 300)
    // Lifetime: capped at 7 days, never below the TTL, defaulted when nil.
    #expect(AutomationLease.clampedMaxLifetime(nil, ttl: 300) == 604_800)
    #expect(AutomationLease.clampedMaxLifetime(10_000_000, ttl: 300) == 604_800)
    #expect(AutomationLease.clampedMaxLifetime(60, ttl: 300) == 300)
}

@Test func adjudicationJudgesTTLAndLifetime() {
    // Fresh: live.
    #expect(AutomationLease.adjudicate(record(), now: base) == .live)
    #expect(AutomationLease.adjudicate(record(), now: base.addingTimeInterval(299)) == .live)
    // Past the heartbeat horizon: lapsed by TTL.
    #expect(AutomationLease.adjudicate(record(), now: base.addingTimeInterval(300))
        == .lapsed(reason: "ttl-expired"))
    // Heartbeats kept it fresh, but the lifetime ceiling passed anyway.
    let longLived = record(updatedAt: base.addingTimeInterval(3_500), ttl: 300, maxLifetime: 3_600)
    #expect(AutomationLease.adjudicate(longLived, now: base.addingTimeInterval(3_650))
        == .lapsed(reason: "lifetime-cap"))
}

@Test func adjudicationClampsHostileRecordValues() {
    // A tampered file claiming a year-long TTL still expires after the
    // clamped day.
    let hostile = record(ttl: 31_536_000, maxLifetime: 31_536_000)
    #expect(AutomationLease.adjudicate(hostile, now: base.addingTimeInterval(86_399)) == .live)
    #expect(AutomationLease.adjudicate(hostile, now: base.addingTimeInterval(86_400))
        == .lapsed(reason: "ttl-expired"))
}

@Test func terminalRecordsPruneAfterRetention() {
    let fresh = record(state: .released, endedAt: base)
    #expect(AutomationLease.adjudicate(fresh, now: base.addingTimeInterval(30))
        == .terminal(prune: false))
    #expect(AutomationLease.adjudicate(fresh, now: base.addingTimeInterval(61))
        == .terminal(prune: true))
    // A terminal record missing its endedAt can never prove it is fresh.
    let stampless = record(state: .revoked)
    #expect(AutomationLease.adjudicate(stampless, now: base) == .terminal(prune: true))
}

@Test func fileNamesFlattenHostileIds() {
    #expect(FileLeaseStore.fileName(forId: idA) == "\(idA).json")
    #expect(FileLeaseStore.fileName(forId: "../../x") == "______x.json")
    #expect(FileLeaseStore.fileName(forId: "") == "lease.json")
}

// MARK: - Engine

@MainActor
@Test func engineReportsLiveLeasesSortedByExpiry() {
    let later = record(id: idB, updatedAt: base.addingTimeInterval(100))
    let store = FakeLeaseStore([record(), later])
    let engine = LeaseEngine(store: store)

    let live = engine.tick(now: base.addingTimeInterval(150))
    #expect(live.map(\.id) == [idA, idB])
    #expect(live[0].expiresAt == base.addingTimeInterval(300))
    #expect(live[0].tool == "test-tool")
}

@MainActor
@Test func engineStampsLapsedLeasesExpired() {
    let store = FakeLeaseStore([record()])
    let engine = LeaseEngine(store: store)

    #expect(engine.tick(now: base.addingTimeInterval(301)).isEmpty)
    let stamped = store.records[idA]
    #expect(stamped?.state == .expired)
    #expect(stamped?.endReason == "ttl-expired")
    #expect(stamped?.endedAt == base.addingTimeInterval(301))
}

@MainActor
@Test func enginePrunesLongEndedRecords() {
    let store = FakeLeaseStore([
        record(id: idA, state: .released, endedAt: base),
        record(id: idB, state: .released, endedAt: base.addingTimeInterval(100)),
    ])
    let engine = LeaseEngine(store: store)

    #expect(engine.tick(now: base.addingTimeInterval(120)).isEmpty)
    // idA is 120 s past its end: pruned. idB ended 20 s ago: retained for
    // ack polls and lease list.
    #expect(store.deleted == [idA])
    #expect(store.records[idB] != nil)
}

@MainActor
@Test func engineSanitizesDisplayFieldsFromDisk() {
    let hostile = record(tool: "evil\u{0007}tool", task: String(repeating: "y", count: 300))
    let engine = LeaseEngine(store: FakeLeaseStore([hostile]))

    let live = engine.tick(now: base)
    #expect(live.first?.tool == "eviltool")
    #expect(live.first?.task.count == 200)
}

@MainActor
@Test func engineClampsFutureDatedRecordsAfterClockRollback() {
    // A clock set backwards leaves updatedAt in the future, which would
    // silently extend the lease by the size of the jump. The engine pulls
    // the timestamps back to now, healing the on-disk record too, so the
    // horizon is one TTL from the present and clients read the same view.
    let store = FakeLeaseStore([
        record(updatedAt: base.addingTimeInterval(7_200), ttl: 300)
    ])
    let engine = LeaseEngine(store: store)

    let live = engine.tick(now: base)
    #expect(live.count == 1)
    #expect(live.first?.expiresAt == base.addingTimeInterval(300))
    #expect(store.records[idA]?.updatedAt == base)

    // One TTL later the healed record expires on schedule.
    #expect(engine.tick(now: base.addingTimeInterval(301)).isEmpty)
    #expect(store.records[idA]?.state == .expired)
}

@MainActor
@Test func revokeAllEndsOnlyActiveLeases() {
    let store = FakeLeaseStore([
        record(id: idA),
        record(id: idB, state: .released, endedAt: base),
    ])
    let engine = LeaseEngine(store: store)

    engine.revokeAll(now: base.addingTimeInterval(5))
    #expect(store.records[idA]?.state == .revoked)
    #expect(store.records[idA]?.endReason == "stopped-by-user")
    #expect(store.records[idA]?.endedAt == base.addingTimeInterval(5))
    #expect(store.records[idB]?.state == .released)
    #expect(engine.tick(now: base.addingTimeInterval(6)).isEmpty)
}

// MARK: - File store round trip

@Test func fileStoreRoundTripsAndDiscardsJunk() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-lease-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileLeaseStore(directory: dir)

    store.write(record())
    // Junk that can never become a lease: dropped on the next scan.
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("junk.json"))
    // A record whose id is not canonical: also dropped.
    try Data(#"{"id":"nope"}"#.utf8).write(to: dir.appendingPathComponent("nope.json"))

    // write() warms the in-memory map; force a directory rescan so junk is
    // noticed and discarded the way a doorbell / TTL miss would.
    store.invalidateCache()
    let loaded = store.loadAll()
    #expect(loaded.count == 1)
    #expect(loaded.first == record())
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("junk.json").path))

    store.delete(id: idA)
    #expect(store.loadAll().isEmpty)
}

@Test func fileStoreCacheServesMemoryUntilDiskChanges() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-lease-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var clock = base
    let store = FileLeaseStore(directory: dir, cacheTTL: 30, now: { clock })

    store.write(record())
    #expect(store.loadAll().count == 1)
    // Unchanged directory: cache hit (still one record).
    #expect(store.loadAll().count == 1)

    // Out-of-band acquire: new file mtime/name must be visible without a
    // doorbell or TTL wait (CLI/MCP from another process).
    let writer = FileLeaseStore(directory: dir, cacheTTL: 30, now: { clock })
    writer.write(record(id: idB, tool: "foreign"))
    let afterAcquire = store.loadAll()
    #expect(afterAcquire.count == 2)
    #expect(Set(afterAcquire.map(\.id)) == [idA, idB])

    // Out-of-band heartbeat: same file, fresher updatedAt. Cache TTL would
    // otherwise keep the stale updatedAt and let the engine expire a live lease.
    let heartbeatAt = base.addingTimeInterval(200)
    writer.write(record(id: idA, tool: "test-tool", updatedAt: heartbeatAt))
    #expect(store.loadAll().first { $0.id == idA }?.updatedAt == heartbeatAt)

    // Out-of-band release: terminal state must land on the next loadAll.
    writer.write(record(id: idB, tool: "foreign", state: .released, endedAt: heartbeatAt))
    #expect(store.loadAll().first { $0.id == idB }?.state == .released)

    // Explicit invalidate still forces a clean rescan.
    store.invalidateCache()
    #expect(store.loadAll().count == 2)

    // Safety TTL also forces a rescan when the stamp is unchanged.
    store.write(record(id: idA, tool: "updated"))
    clock = clock.addingTimeInterval(31)
    #expect(store.loadAll().first { $0.id == idA }?.tool == "updated")
}

@MainActor
@Test func engineSeesForeignHeartbeatWithinCacheTTL() throws {
    // App store cacheTTL is longer than the adjudication window so a stale
    // listing would survive past the original TTL; only the on-disk stamp
    // check (not the safety TTL) can keep the lease live.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-lease-hb-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var clock = base
    let appStore = FileLeaseStore(directory: dir, cacheTTL: 60, now: { clock })
    let engine = LeaseEngine(store: appStore)

    appStore.write(record(ttl: 30))
    #expect(engine.tick(now: clock).map(\.id) == [idA])

    // CLI heartbeat at +25s: new horizon is +55s. Without a rescan, the app
    // would still hold updatedAt=base and expire at +30.
    clock = base.addingTimeInterval(25)
    FileLeaseStore(directory: dir, cacheTTL: 60, now: { clock })
        .write(record(updatedAt: clock, ttl: 30))

    clock = base.addingTimeInterval(35)
    let live = engine.tick(now: clock)
    #expect(live.count == 1)
    #expect(live.first?.expiresAt == base.addingTimeInterval(55))
    #expect(appStore.loadAll().first { $0.id == idA }?.state == .active)
}

@Test func fileStoreCompareAndSwapRefusesAChangedRecord() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-lease-cas-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileLeaseStore(directory: dir)
    let live = record()
    store.write(live)

    var revoked = live
    revoked.state = .revoked
    revoked.endedAt = base
    revoked.endReason = "stopped-by-user"
    FileLeaseStore(directory: dir).write(revoked)

    var heartbeat = live
    heartbeat.updatedAt = base.addingTimeInterval(10)
    #expect(!store.compareAndSwap(expected: live, new: heartbeat))
    #expect(store.loadAll().first?.state == .revoked)
}

@MainActor
@Test func engineExpiryLosesToAConcurrentHeartbeat() {
    // loadAll returns a lapsed record; compareAndSwap then sees a heartbeat
    // that landed underneath. Demand must stay up in the same tick.
    let inner = FakeLeaseStore([record(ttl: 30)])
    final class RacingStore: LeaseRecordStoring {
        let inner: FakeLeaseStore
        var flipped = false
        init(_ inner: FakeLeaseStore) { self.inner = inner }
        func loadAll() -> [AutomationLeaseRecord] { inner.loadAll() }
        func write(_ record: AutomationLeaseRecord) { inner.write(record) }
        func delete(id: String) { inner.delete(id: id) }
        func compareAndSwap(expected: AutomationLeaseRecord, new: AutomationLeaseRecord) -> Bool {
            if !flipped {
                flipped = true
                var fresh = expected
                fresh.updatedAt = expected.updatedAt.addingTimeInterval(200)
                inner.write(fresh)
            }
            return inner.compareAndSwap(expected: expected, new: new)
        }
    }
    let racing = RacingStore(inner)
    let engine = LeaseEngine(store: racing)
    let live = engine.tick(now: base.addingTimeInterval(31))
    #expect(live.count == 1)
    #expect(inner.records[idA]?.state == .active)
    #expect(inner.records[idA]?.updatedAt == base.addingTimeInterval(200))
}
