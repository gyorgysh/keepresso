import Foundation
import Testing
@testable import KeepressoCore

private final class MemoryLeaseStore: LeaseRecordStoring {
    var records: [AgentWakeLeaseRecord] = []

    func update(
        _ transform: (inout [AgentWakeLeaseRecord]) throws -> Void
    ) throws {
        try transform(&records)
    }
}

private final class LeaseTestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class LeaseTestIDs {
    private var next = 1

    func make() -> String {
        defer { next += 1 }
        return "lease-\(next)"
    }
}

private func testCommander(
    store: MemoryLeaseStore,
    clock: LeaseTestClock,
    ids: LeaseTestIDs = LeaseTestIDs()
) -> FileLeaseCommander {
    FileLeaseCommander(
        store: store,
        now: { clock.now },
        makeID: { ids.make() }
    )
}

// MARK: - CLI parsing

@Test func parsesLeaseAcquireOptions() throws {
    #expect(try CLIRequest.parse([
        "lease", "acquire",
        "--owner", "quasar",
        "--agent", "codex",
        "--task", "fix-tests",
        "--ttl", "300",
        "--max-lifetime", "7200",
        "--message", "working",
    ]) == .lease(.acquire(
        owner: "quasar",
        agent: "codex",
        task: "fix-tests",
        ttlSeconds: 300,
        maxLifetimeSeconds: 7200,
        message: "working"
    )))
}

@Test func parsesEveryLeaseLifecycleCommand() throws {
    #expect(try CLIRequest.parse([
        "lease", "renew", "lease-1", "--ttl", "240", "--message", "progress",
    ]) == .lease(.renew(id: "lease-1", ttlSeconds: 240, message: "progress")))

    #expect(try CLIRequest.parse([
        "lease", "heartbeat", "lease-1", "--ttl", "180",
    ]) == .lease(.heartbeat(id: "lease-1", ttlSeconds: 180, message: nil)))

    #expect(try CLIRequest.parse([
        "lease", "release", "lease-1", "--result", "failure", "--message", "failed",
    ]) == .lease(.release(id: "lease-1", result: .failure, message: "failed")))

    #expect(try CLIRequest.parse([
        "lease", "list", "--owner", "quasar", "--agent", "codex",
        "--task", "fix-tests", "--all",
    ]) == .lease(.list(LeaseListFilter(
        owner: "quasar",
        agent: "codex",
        task: "fix-tests",
        includeInactive: true
    ))))

    #expect(try CLIRequest.parse(["lease", "status"]) == .lease(.status(id: nil)))
    #expect(try CLIRequest.parse(["lease", "status", "lease-1"])
        == .lease(.status(id: "lease-1")))
}

@Test func rejectsInvalidLeaseCLIParameters() {
    #expect(throws: CLIUsageError.self) {
        try CLIRequest.parse(["lease", "acquire", "--owner", "me"])
    }
    #expect(throws: CLIUsageError.self) {
        try CLIRequest.parse([
            "lease", "acquire", "--owner", "me", "--agent", "codex",
            "--task", "task", "--ttl", "zero",
        ])
    }
    #expect(throws: CLIUsageError.self) {
        try CLIRequest.parse(["lease", "renew"])
    }
    #expect(throws: CLIUsageError.self) {
        try CLIRequest.parse(["lease", "release", "lease-1", "--result", "done"])
    }
    #expect(throws: CLIUsageError.self) {
        try CLIRequest.parse(["lease", "list", "--all", "--all"])
    }
}

// MARK: - Lease behavior

@Test func acquireCreatesBoundedLeaseAndStableJSON() throws {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let store = MemoryLeaseStore()
    let response = testCommander(
        store: store,
        clock: LeaseTestClock(instant)
    ).execute(.acquire(
        owner: "quasar",
        agent: "codex",
        task: "task-1",
        ttlSeconds: 300,
        maxLifetimeSeconds: 3_600,
        message: "starting"
    ))

    #expect(response.ok)
    #expect(response.command == "acquire")
    #expect(response.lease?.id == "lease-1")
    #expect(response.lease?.expiresAt == instant.addingTimeInterval(300))
    #expect(response.lease?.maxExpiresAt == instant.addingTimeInterval(3_600))
    #expect(response.status?.wakeRequired == true)
    #expect(response.status?.activeCount == 1)

    let first = try #require(LeaseJSON.encode(response, prettyPrinted: false))
    let second = try #require(LeaseJSON.encode(response, prettyPrinted: false))
    #expect(first == second)
    let object = try #require(
        JSONSerialization.jsonObject(with: first) as? [String: Any]
    )
    #expect(Set(object.keys) == [
        "schemaVersion", "ok", "command", "code", "message", "lease", "leases", "status",
    ])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["leases"] is NSNull)
    let lease = try #require(object["lease"] as? [String: Any])
    #expect((lease["acquiredAt"] as? String)?.hasSuffix("Z") == true)
    #expect(lease["releasedAt"] is NSNull)
    #expect(lease["result"] is NSNull)
}

@Test func concurrentLeasesKeepWakeDemandUntilAllRelease() throws {
    let store = MemoryLeaseStore()
    let commander = testCommander(
        store: store,
        clock: LeaseTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    )
    let first = commander.execute(.acquire(
        owner: "one", agent: "codex", task: "task-1",
        ttlSeconds: 300, maxLifetimeSeconds: 3_600, message: nil
    ))
    let second = commander.execute(.acquire(
        owner: "two", agent: "claude-code", task: "task-2",
        ttlSeconds: 300, maxLifetimeSeconds: 3_600, message: nil
    ))
    let firstID = try #require(first.lease?.id)
    let secondID = try #require(second.lease?.id)

    let afterFirst = commander.execute(.release(
        id: firstID, result: .success, message: "done"
    ))
    #expect(afterFirst.status?.activeCount == 1)
    #expect(afterFirst.status?.wakeRequired == true)

    let afterSecond = commander.execute(.release(
        id: secondID, result: .failure, message: "failed"
    ))
    #expect(afterSecond.status?.activeCount == 0)
    #expect(afterSecond.status?.releasedCount == 2)
    #expect(afterSecond.status?.wakeRequired == false)
}

@Test func renewalIsCappedAndForgottenLeaseExpires() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = LeaseTestClock(start)
    let store = MemoryLeaseStore()
    let commander = testCommander(store: store, clock: clock)
    let acquired = commander.execute(.acquire(
        owner: "owner", agent: "codex", task: "task",
        ttlSeconds: 30, maxLifetimeSeconds: 100, message: nil
    ))
    let id = try #require(acquired.lease?.id)

    clock.now = start.addingTimeInterval(20)
    let renewed = commander.execute(.heartbeat(
        id: id, ttlSeconds: 100, message: "still working"
    ))
    #expect(renewed.ok)
    #expect(renewed.lease?.expiresAt == start.addingTimeInterval(100))
    #expect(renewed.lease?.message == "still working")

    clock.now = start.addingTimeInterval(101)
    let expired = commander.execute(.status(id: id))
    #expect(expired.lease?.state == .expired)
    #expect(expired.lease?.result == .timeout)
    #expect(expired.status?.expiredCount == 1)
    #expect(expired.status?.wakeRequired == false)
}

@Test func fileStorePersistsTopLevelSchemaAndRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-lease-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("wake-leases.json")
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let first = FileLeaseCommander(
        store: JSONLeaseFileStore(fileURL: fileURL),
        now: { instant },
        makeID: { "persisted-lease" }
    )
    #expect(first.execute(.acquire(
        owner: "owner", agent: "codex", task: "task",
        ttlSeconds: 300, maxLifetimeSeconds: 3_600, message: nil
    )).ok)

    let document = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    #expect(document["schemaVersion"] as? Int == 1)
    #expect((document["leases"] as? [[String: Any]])?.count == 1)

    let second = FileLeaseCommander(
        store: JSONLeaseFileStore(fileURL: fileURL),
        now: { instant }
    )
    let status = second.execute(.status(id: "persisted-lease"))
    #expect(status.ok)
    #expect(status.lease?.owner == "owner")
}

@Test func defaultLeaseStoreUsesApplicationSupportPath() {
    #expect(JSONLeaseFileStore.defaultURL().path.hasSuffix(
        "/Library/Application Support/Keepresso/wake-leases.json"
    ))
}
