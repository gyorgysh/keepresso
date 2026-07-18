import Foundation
import Testing
@testable import KeepressoCore

private final class AdapterLeaseStore: AgentLeasePersisting {
    var state = AgentLeasePersistenceState.empty

    func load() throws -> AgentLeasePersistenceState { state }

    func update(
        _ mutation: (inout AgentLeasePersistenceState) throws -> Void
    ) throws -> AgentLeasePersistenceState {
        try mutation(&state)
        return state
    }
}

@MainActor
private final class RecordingAppSignaler: AgentLeaseAppSignaling {
    var launchRequests: [Bool] = []

    func leaseStateDidChange(launchIfNeeded: Bool) {
        launchRequests.append(launchIfNeeded)
    }
}

private final class LeaseTestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private func testAdapter(
    store: AgentLeasePersisting,
    clock: LeaseTestClock,
    signaler: AgentLeaseAppSignaling
) throws -> AgentLeaseCommandAdapter {
    let service = try AgentLeaseCommandService(
        persistence: store,
        now: { clock.now }
    )
    return AgentLeaseCommandAdapter(service: service, appSignaler: signaler)
}

@MainActor
private func testAdapter(
    store: AgentLeasePersisting,
    clock: LeaseTestClock
) throws -> AgentLeaseCommandAdapter {
    try testAdapter(store: store, clock: clock, signaler: RecordingAppSignaler())
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
        "lease", "renew", "ae21d9ee-c5c7-4dff-8664-b29d73ac9b11", "--ttl", "240",
    ]) == .lease(.renew(
        id: "ae21d9ee-c5c7-4dff-8664-b29d73ac9b11",
        ttlSeconds: 240,
        message: nil
    )))

    #expect(try CLIRequest.parse([
        "lease", "heartbeat", "ae21d9ee-c5c7-4dff-8664-b29d73ac9b11", "--ttl", "180",
    ]) == .lease(.heartbeat(
        id: "ae21d9ee-c5c7-4dff-8664-b29d73ac9b11",
        ttlSeconds: 180,
        message: nil
    )))

    #expect(try CLIRequest.parse([
        "lease", "release", "ae21d9ee-c5c7-4dff-8664-b29d73ac9b11",
        "--result", "failure", "--message", "failed",
    ]) == .lease(.release(
        id: "ae21d9ee-c5c7-4dff-8664-b29d73ac9b11",
        result: .failure,
        message: "failed"
    )))

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
        try CLIRequest.parse([
            "lease", "release", "ae21d9ee-c5c7-4dff-8664-b29d73ac9b11", "--result", "timeout",
        ])
    }
    #expect(throws: CLIUsageError.self) {
        try CLIRequest.parse(["lease", "list", "--all", "--all"])
    }
}

// MARK: - Authoritative service adapter

@Test @MainActor func acquireUsesAgentLeaseServiceAndStableJSON() throws {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let store = AdapterLeaseStore()
    let signaler = RecordingAppSignaler()
    let response = try testAdapter(
        store: store,
        clock: LeaseTestClock(instant),
        signaler: signaler
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
    #expect(UUID(uuidString: response.lease?.id ?? "") != nil)
    #expect(response.lease?.expiresAt == instant.addingTimeInterval(300))
    #expect(response.lease?.maxExpiresAt == instant.addingTimeInterval(3_600))
    #expect(response.status?.wakeRequired == true)
    #expect(response.status?.activeCount == 1)
    #expect(store.state.leases.count == 1)
    #expect(store.state.leases[0].metadata.attributes["message"] == "starting")
    #expect(signaler.launchRequests == [true])

    let first = try #require(LeaseJSON.encode(response, prettyPrinted: false))
    let second = try #require(LeaseJSON.encode(response, prettyPrinted: false))
    #expect(first == second)
    let object = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
    #expect(Set(object.keys) == [
        "schemaVersion", "ok", "command", "code", "message", "lease", "leases", "status",
    ])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["leases"] is NSNull)
}

@Test @MainActor func concurrentLeasesSignalAndKeepUnionActive() throws {
    let clock = LeaseTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let signaler = RecordingAppSignaler()
    let adapter = try testAdapter(
        store: AdapterLeaseStore(),
        clock: clock,
        signaler: signaler
    )
    let first = adapter.execute(.acquire(
        owner: "one", agent: "codex", task: "task-1",
        ttlSeconds: 300, maxLifetimeSeconds: 3_600, message: nil
    ))
    let second = adapter.execute(.acquire(
        owner: "two", agent: "claude-code", task: "task-2",
        ttlSeconds: 300, maxLifetimeSeconds: 3_600, message: nil
    ))
    let firstID = try #require(first.lease?.id)
    let secondID = try #require(second.lease?.id)

    let heartbeat = adapter.execute(.heartbeat(
        id: firstID, ttlSeconds: nil, message: nil
    ))
    #expect(heartbeat.ok)
    let afterFirst = adapter.execute(.release(
        id: firstID, result: .success, message: nil
    ))
    #expect(afterFirst.status?.activeCount == 1)
    #expect(afterFirst.status?.wakeRequired == true)

    let afterSecond = adapter.execute(.release(
        id: secondID, result: .failure, message: "failed"
    ))
    #expect(afterSecond.status?.activeCount == 0)
    #expect(afterSecond.status?.releasedCount == 2)
    #expect(afterSecond.status?.wakeRequired == false)
    #expect(signaler.launchRequests == [true, true, true, false, false])
}

@Test @MainActor func watchdogOwnsTimeoutAndStatusReconcilesIt() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = LeaseTestClock(start)
    let adapter = try testAdapter(store: AdapterLeaseStore(), clock: clock)
    let acquired = adapter.execute(.acquire(
        owner: "owner", agent: "codex", task: "task",
        ttlSeconds: 30, maxLifetimeSeconds: 100, message: nil
    ))
    let id = try #require(acquired.lease?.id)

    clock.now = start.addingTimeInterval(20)
    let renewed = adapter.execute(.heartbeat(id: id, ttlSeconds: 100, message: nil))
    #expect(renewed.ok)
    #expect(renewed.lease?.expiresAt == start.addingTimeInterval(100))

    let rejected = adapter.execute(.release(id: id, result: .timeout, message: nil))
    #expect(!rejected.ok)
    #expect(rejected.code == "invalid_arguments")

    clock.now = start.addingTimeInterval(101)
    let expired = adapter.execute(.status(id: id))
    #expect(expired.lease?.state == .expired)
    #expect(expired.lease?.result == .timeout)
    #expect(expired.status?.expiredCount == 1)
    #expect(expired.status?.wakeRequired == false)
}

@Test @MainActor func adapterUsesAuthoritativeFileStore() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-lease-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("wake-leases.json")
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let signaler = RecordingAppSignaler()
    let first = try testAdapter(
        store: FileAgentLeaseStore(fileURL: fileURL),
        clock: LeaseTestClock(instant),
        signaler: signaler
    )
    let acquired = first.execute(.acquire(
        owner: "owner", agent: "codex", task: "task",
        ttlSeconds: 300, maxLifetimeSeconds: 3_600, message: nil
    ))
    #expect(acquired.ok)
    let id = try #require(acquired.lease?.id)

    let document = try AgentLeaseFileCodec.decode(Data(contentsOf: fileURL))
    #expect(document.schemaVersion == AgentLeasePersistenceState.currentSchemaVersion)
    #expect(document.leases.count == 1)

    let second = try testAdapter(
        store: FileAgentLeaseStore(fileURL: fileURL),
        clock: LeaseTestClock(instant),
        signaler: signaler
    )
    let status = second.execute(.status(id: id))
    #expect(status.ok)
    #expect(status.lease?.owner == "owner")
}

@Test func defaultLeaseStoreUsesApplicationSupportPath() {
    #expect(FileAgentLeaseStore.defaultURL().path.hasSuffix(
        "/Library/Application Support/Keepresso/wake-leases.json"
    ))
}
