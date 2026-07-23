import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Scripted world

private let base = Date(timeIntervalSince1970: 2_000_000)
private let idA = "aaaaaaaa-1111-2222-3333-444444444444"

/// In-memory store shared with AutomationLeaseTests' semantics.
private final class MemoryStore: LeaseRecordStoring {
    var records: [String: AutomationLeaseRecord] = [:]
    func loadAll() -> [AutomationLeaseRecord] { Array(records.values) }
    func write(_ record: AutomationLeaseRecord) { records[record.id] = record }
    func delete(id: String) { records[id] = nil }
}

/// A fully scripted client world: the clock advances only when the poll
/// sleeps, and the status file plays back a scripted sequence.
private final class World {
    let store = MemoryStore()
    var now = base
    /// Consumed one per readStatus call; the last entry repeats.
    var statusScript: [StatusSnapshot?] = [nil]
    var nudged = 0
    var nudgeResult = true
    var livePids: Set<Int32> = [77]

    func client(owner: String = "tester") -> LeaseClient {
        LeaseClient(
            store: store,
            now: { self.now },
            readStatus: {
                self.statusScript.count > 1
                    ? self.statusScript.removeFirst()
                    : self.statusScript[0]
            },
            nudgeApp: {
                self.nudged += 1
                return self.nudgeResult
            },
            sleep: { self.now.addTimeInterval($0) },
            isPidAlive: { self.livePids.contains($0) },
            ownerPid: 4242,
            defaultOwner: owner
        )
    }
}

private func snapshot(
    isActive: Bool = true,
    pid: Int32 = 77,
    leaseIDs: [String]? = nil,
    leasesEnabled: Bool? = true
) -> StatusSnapshot {
    StatusSnapshot(
        isActive: isActive, pid: pid, writtenAt: base,
        leaseIDs: leaseIDs, leasesEnabled: leasesEnabled
    )
}

// MARK: - Acquire

@Test func acquireSucceedsOnceTheAppAcknowledges() {
    let world = World()
    // Cold launch: no file, then a snapshot without the id, then the ack.
    world.statusScript = [nil, snapshot(), snapshot(leaseIDs: [idA])]

    let outcome = world.client().acquire(
        id: idA, owner: nil, tool: "test-tool", task: "a task",
        ttlSeconds: 300, maxLifetimeSeconds: nil
    )
    #expect(outcome.exitCode == 0)
    #expect(world.nudged == 1)
    #expect(outcome.json.contains("\"acquired\" : true"))
    #expect(outcome.json.contains("\"renewed\" : false"))
    let record = world.store.records[idA]
    #expect(record?.owner == "tester")
    #expect(record?.ownerPid == 4242)
    #expect(record?.ttlSeconds == 300)
    #expect(record?.maxLifetimeSeconds == AutomationLease.maxLifetimeCap)
}

@Test func acquireTimesOutAndFailsClosed() {
    let world = World()
    world.statusScript = [snapshot()] // the app never lists the id

    let outcome = world.client().acquire(
        id: idA, owner: nil, tool: "t", task: "x",
        ttlSeconds: 300, maxLifetimeSeconds: nil
    )
    #expect(outcome.exitCode == 2)
    // Fail closed: the unacknowledged record must not linger and silently
    // hold the Mac awake at the app's next launch.
    #expect(world.store.records.isEmpty)
    #expect(world.now >= base.addingTimeInterval(LeaseClient.ackTimeout))
}

@Test func acquireReportsTheDisabledPreference() {
    let world = World()
    world.statusScript = [snapshot(leasesEnabled: false)]

    let outcome = world.client().acquire(
        id: idA, owner: nil, tool: "t", task: "x",
        ttlSeconds: 300, maxLifetimeSeconds: nil
    )
    #expect(outcome.exitCode == 4)
    #expect(world.store.records.isEmpty)
}

@Test func acquireFailsFastWhenTheDoorbellCannotRing() {
    let world = World()
    world.nudgeResult = false

    let outcome = world.client().acquire(
        id: idA, owner: nil, tool: "t", task: "x",
        ttlSeconds: 300, maxLifetimeSeconds: nil
    )
    #expect(outcome.exitCode == 2)
    #expect(world.store.records.isEmpty)
}

@Test func reacquireOfALiveLeaseKeepsItsCreationAnchor() {
    let world = World()
    world.statusScript = [snapshot(leaseIDs: [idA])]
    let client = world.client()
    _ = client.acquire(id: idA, owner: nil, tool: "t", task: "x", ttlSeconds: 300, maxLifetimeSeconds: nil)

    world.now = base.addingTimeInterval(100)
    let outcome = client.acquire(
        id: idA, owner: nil, tool: "t", task: "renamed",
        ttlSeconds: 600, maxLifetimeSeconds: nil
    )
    #expect(outcome.exitCode == 0)
    #expect(outcome.json.contains("\"renewed\" : true"))
    let record = world.store.records[idA]
    // The lifetime ceiling stays anchored to the original acquisition.
    #expect(record?.createdAt == base)
    #expect(record?.updatedAt == base.addingTimeInterval(100))
    #expect(record?.task == "renamed")

    // Re-acquiring after the lease ended starts a fresh anchor instead.
    world.store.records[idA]?.state = .released
    world.store.records[idA]?.endedAt = world.now
    world.now = base.addingTimeInterval(200)
    _ = client.acquire(id: idA, owner: nil, tool: "t", task: "x", ttlSeconds: 300, maxLifetimeSeconds: nil)
    #expect(world.store.records[idA]?.createdAt == base.addingTimeInterval(200))
}

@Test func acquireClampsHostileDurations() {
    let world = World()
    world.statusScript = [snapshot(leaseIDs: [idA])]

    _ = world.client().acquire(
        id: idA, owner: nil, tool: "t", task: "x",
        ttlSeconds: 999_999_999, maxLifetimeSeconds: 999_999_999
    )
    #expect(world.store.records[idA]?.ttlSeconds == 86_400)
    #expect(world.store.records[idA]?.maxLifetimeSeconds == AutomationLease.maxLifetimeCap)
}

// MARK: - Heartbeat

@Test func heartbeatExtendsALiveLease() {
    let world = World()
    world.store.records[idA] = AutomationLeaseRecord(
        id: idA, owner: "o", tool: "t", task: "x",
        createdAt: base, updatedAt: base, ttlSeconds: 300, maxLifetimeSeconds: 3_600
    )
    world.statusScript = [snapshot()]
    world.now = base.addingTimeInterval(150)

    let outcome = world.client().heartbeat(id: idA, ttlSeconds: nil)
    #expect(outcome.exitCode == 0)
    #expect(world.store.records[idA]?.updatedAt == world.now)
}

@Test func heartbeatOfAnEndedOrMissingLeaseFails() {
    let world = World()
    let client = world.client()

    #expect(client.heartbeat(id: idA, ttlSeconds: nil).exitCode == 3)

    world.store.records[idA] = AutomationLeaseRecord(
        id: idA, owner: "o", tool: "t", task: "x",
        createdAt: base, updatedAt: base, ttlSeconds: 300, maxLifetimeSeconds: 3_600,
        state: .revoked, endedAt: base, endReason: "stopped-by-user"
    )
    let outcome = client.heartbeat(id: idA, ttlSeconds: nil)
    #expect(outcome.exitCode == 3)
    #expect(outcome.json.contains("revoked"))
    // Never resurrected.
    #expect(world.store.records[idA]?.state == .revoked)

    // A lapsed-but-unstamped lease reads as expired too.
    world.store.records[idA] = AutomationLeaseRecord(
        id: idA, owner: "o", tool: "t", task: "x",
        createdAt: base, updatedAt: base, ttlSeconds: 300, maxLifetimeSeconds: 3_600
    )
    world.now = base.addingTimeInterval(500)
    #expect(client.heartbeat(id: idA, ttlSeconds: nil).exitCode == 3)
}

@Test func heartbeatWithoutARunningAppStillWritesButSignals() {
    let world = World()
    world.store.records[idA] = AutomationLeaseRecord(
        id: idA, owner: "o", tool: "t", task: "x",
        createdAt: base, updatedAt: base, ttlSeconds: 300, maxLifetimeSeconds: 3_600
    )
    world.statusScript = [snapshot(pid: 99)] // a pid that is not alive
    world.livePids = []
    world.now = base.addingTimeInterval(100)

    let outcome = world.client().heartbeat(id: idA, ttlSeconds: nil)
    // The record is written (leases survive an app relaunch), but the caller
    // must know nothing is holding the Mac right now.
    #expect(outcome.exitCode == 2)
    #expect(world.store.records[idA]?.updatedAt == world.now)
}

// MARK: - Release and list

@Test func releaseIsIdempotent() {
    let world = World()
    let client = world.client()
    #expect(client.release(id: idA).exitCode == 0) // nothing there: still ok

    world.store.records[idA] = AutomationLeaseRecord(
        id: idA, owner: "o", tool: "t", task: "x",
        createdAt: base, updatedAt: base, ttlSeconds: 300, maxLifetimeSeconds: 3_600
    )
    #expect(client.release(id: idA).exitCode == 0)
    #expect(world.store.records[idA]?.state == .released)
    #expect(world.store.records[idA]?.endReason == "released")
    // Releasing again does not disturb the terminal record.
    #expect(client.release(id: idA).exitCode == 0)
    #expect(world.store.records[idA]?.state == .released)
}

@Test func listShowsLiveAndEndedLeases() {
    let world = World()
    world.store.records[idA] = AutomationLeaseRecord(
        id: idA, owner: "o", tool: "t", task: "live one",
        createdAt: base, updatedAt: base, ttlSeconds: 300, maxLifetimeSeconds: 3_600
    )
    world.now = base.addingTimeInterval(10)

    let outcome = world.client().list()
    #expect(outcome.exitCode == 0)
    #expect(outcome.json.contains("\"state\" : \"active\""))
    #expect(outcome.human.contains("live one"))

    // Past the TTL the same record lists as expired even before the app
    // stamps it.
    world.now = base.addingTimeInterval(500)
    #expect(world.client().list().json.contains("\"state\" : \"expired\""))
}
