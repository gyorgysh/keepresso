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

    let loaded = store.loadAll()
    #expect(loaded.count == 1)
    #expect(loaded.first == record())
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("junk.json").path))

    store.delete(id: idA)
    #expect(store.loadAll().isEmpty)
}
