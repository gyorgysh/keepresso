import Foundation
import Testing
@testable import KeepressoCore

private final class LeaseClock {
    var now: Date

    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

private final class MemoryAgentLeaseStore: AgentLeasePersisting {
    var state: AgentLeasePersistenceState

    init(_ state: AgentLeasePersistenceState = .empty) {
        self.state = state
    }

    func load() throws -> AgentLeasePersistenceState {
        state
    }

    func update(
        _ mutation: (inout AgentLeasePersistenceState) throws -> Void
    ) throws -> AgentLeasePersistenceState {
        try mutation(&state)
        return state
    }
}

private final class ConcurrentErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ error: Error) {
        lock.lock()
        storage.append(String(describing: error))
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func lease(
    id: UUID = UUID(),
    owner: String = "test-owner",
    acquiredAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    ttl: TimeInterval = 60,
    maxLifetime: TimeInterval = 600,
    state: AgentLeaseState = .active,
    completedAt: Date? = nil
) -> AgentWakeLease {
    AgentWakeLease(
        id: id,
        metadata: AgentLeaseMetadata(
            owner: owner,
            agent: "codex",
            task: "task-1",
            attributes: ["thread": "abc"]
        ),
        acquiredAt: acquiredAt,
        heartbeatAt: acquiredAt,
        expiresAt: acquiredAt.addingTimeInterval(min(ttl, maxLifetime)),
        ttl: ttl,
        maxLifetime: maxLifetime,
        state: state,
        completedAt: completedAt
    )
}

private func temporaryLeaseFile() throws -> (directory: URL, file: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-agent-leases-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("agent-leases.json"))
}

@Test func leaseModelRoundTripsEveryTerminalState() throws {
    let states: [AgentLeaseState] = [
        .active,
        .success,
        .failure(reason: "tool exited 9"),
        .failure(reason: nil),
        .timeout,
        .cancelled(reason: "user stopped it"),
        .cancelled(reason: nil),
    ]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for state in states {
        let original = lease(state: state)
        let decoded = try decoder.decode(
            AgentWakeLease.self,
            from: encoder.encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.state.isTerminal == (state != .active))
    }
}

@Test func stableFileCodecCarriesSchemaAndDefaultURL() throws {
    let original = AgentLeasePersistenceState(leases: [lease(
        acquiredAt: Date(timeIntervalSince1970: 1_800_000_000.1234567)
    )])
    let data = try AgentLeaseFileCodec.encode(original)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == AgentLeasePersistenceState.currentSchemaVersion)
    #expect(try AgentLeaseFileCodec.decode(data) == original)
    #expect(FileAgentLeaseStore.defaultURL().path.hasSuffix(
        "/Library/Application Support/Keepresso/wake-leases.json"
    ))
}

@Test func commandAndResponseModelsHaveStableRoundTrips() throws {
    let id = UUID()
    let metadata = AgentLeaseMetadata(owner: "codex", agent: "codex", task: "review")
    let commands: [AgentLeaseCommand] = [
        .acquire(id: id, metadata: metadata, ttl: 60, maxLifetime: 600),
        .heartbeat(id: id),
        .renew(id: id, ttl: 120),
        .release(id: id, outcome: .failure(reason: "failed")),
        .list(includeTerminal: false),
        .status(id: id),
        .snapshot,
    ]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for command in commands {
        let data = try encoder.encode(command)
        #expect(try decoder.decode(AgentLeaseCommand.self, from: data) == command)
    }

    let item = lease(id: id)
    let snapshot = AgentLeaseSnapshot(capturedAt: item.acquiredAt, leases: [item])
    let responses: [AgentLeaseCommandResponse] = [
        .lease(item),
        .leases([item]),
        .status(item),
        .status(nil),
        .snapshot(snapshot),
    ]
    for response in responses {
        let data = try encoder.encode(response)
        #expect(try decoder.decode(AgentLeaseCommandResponse.self, from: data) == response)
    }
}

@MainActor
@Test func activeLeasesFormAUnionUntilTheLastRelease() throws {
    let clock = LeaseClock()
    let store = MemoryAgentLeaseStore()
    var events: [AgentLeaseLifecycleEvent] = []
    var snapshots: [AgentLeaseSnapshot] = []
    let registry = try AgentLeaseRegistry(
        persistence: store,
        now: { clock.now },
        onEvent: { events.append($0) },
        onSnapshotChange: { snapshots.append($0) }
    )

    let first = try registry.acquire(
        owner: "codex-thread-1",
        agent: "codex",
        task: "refactor"
    )
    clock.advance(1)
    let second = try registry.acquire(
        owner: "claude-session-2",
        agent: "claude",
        task: "tests"
    )

    #expect(registry.shouldKeepAwake)
    #expect(registry.currentSnapshot.activeCount == 2)

    let failed = try registry.release(first.id, outcome: .failure(reason: "build failed"))
    #expect(failed.state == .failure(reason: "build failed"))
    #expect(registry.shouldKeepAwake)
    #expect(registry.currentSnapshot.activeLeases.map(\.id) == [second.id])

    let succeeded = try registry.release(second.id)
    #expect(succeeded.state == .success)
    #expect(!registry.shouldKeepAwake)
    #expect(registry.currentSnapshot.activeCount == 0)
    #expect(events.map(\.kind) == [.acquired, .acquired, .released, .released])
    #expect(snapshots.first?.activeCount == 0)
    #expect(snapshots.last?.activeCount == 0)
}

@MainActor
@Test func commandServiceOwnsRegistryOperationsForAdapters() throws {
    let clock = LeaseClock()
    let service = try AgentLeaseCommandService(
        persistence: MemoryAgentLeaseStore(),
        now: { clock.now }
    )
    let id = UUID()
    let metadata = AgentLeaseMetadata(owner: "mcp-client", agent: "gemini", task: "index")

    let acquiredResponse = try service.execute(.acquire(
        id: id,
        metadata: metadata,
        ttl: 30,
        maxLifetime: 300
    ))
    guard case .lease(let acquired) = acquiredResponse else {
        Issue.record("Acquire returned the wrong response")
        return
    }
    #expect(acquired.id == id)

    clock.advance(10)
    guard case .lease(let heartbeat) = try service.execute(.heartbeat(id: id)) else {
        Issue.record("Heartbeat returned the wrong response")
        return
    }
    #expect(heartbeat.heartbeatAt == clock.now)

    guard case .leases(let active) = try service.execute(.list(includeTerminal: false)) else {
        Issue.record("List returned the wrong response")
        return
    }
    #expect(active.map(\.id) == [id])

    _ = try service.execute(.release(id: id, outcome: .success))
    guard case .status(let terminal) = try service.execute(.status(id: id)) else {
        Issue.record("Status returned the wrong response")
        return
    }
    #expect(terminal?.state == .success)

    guard case .snapshot(let snapshot) = try service.execute(.snapshot) else {
        Issue.record("Snapshot returned the wrong response")
        return
    }
    #expect(!snapshot.shouldKeepAwake)
}

@MainActor
@Test func cancelledReleaseIsTerminalAndCannotBeReleasedTwice() throws {
    let registry = try AgentLeaseRegistry(persistence: MemoryAgentLeaseStore())
    let acquired = try registry.acquire(owner: "automation")
    let cancelled = try registry.release(
        acquired.id,
        outcome: .cancelled(reason: "schedule cancelled")
    )
    #expect(cancelled.state == .cancelled(reason: "schedule cancelled"))

    do {
        _ = try registry.release(acquired.id)
        Issue.record("A terminal lease was released twice")
    } catch {
        #expect(error as? AgentLeaseRegistryError == .leaseNotActive(acquired.id))
    }
}

@MainActor
@Test func heartbeatAndRenewalCannotCrossMaximumLifetime() throws {
    let clock = LeaseClock()
    var events: [AgentLeaseLifecycleEvent] = []
    let registry = try AgentLeaseRegistry(
        persistence: MemoryAgentLeaseStore(),
        now: { clock.now },
        onEvent: { events.append($0) }
    )
    let acquired = try registry.acquire(
        owner: "codex",
        ttl: 10,
        maxLifetime: 25
    )
    #expect(acquired.expiresAt == clock.now.addingTimeInterval(10))

    clock.advance(8)
    let heartbeat = try registry.heartbeat(acquired.id)
    #expect(heartbeat.heartbeatAt == clock.now)
    #expect(heartbeat.expiresAt == acquired.acquiredAt.addingTimeInterval(18))

    clock.advance(8)
    let renewed = try registry.renew(acquired.id, ttl: 20)
    #expect(renewed.ttl == 20)
    #expect(renewed.expiresAt == acquired.acquiredAt.addingTimeInterval(25))
    #expect(renewed.maxLifetimeAt == acquired.acquiredAt.addingTimeInterval(25))

    clock.advance(8)
    #expect(try registry.watchdogTick().shouldKeepAwake)
    clock.advance(1)
    #expect(!(try registry.watchdogTick()).shouldKeepAwake)

    let terminal = try #require(registry.status(for: acquired.id, refreshFromDisk: false))
    #expect(terminal.state == .timeout)
    let timeout = try #require(events.last)
    #expect(timeout.kind == .timedOut)
    #expect(timeout.timeoutCause == .maximumLifetime)
}

@MainActor
@Test func ttlWatchdogPersistsTimeoutAndRejectsLateHeartbeat() throws {
    let clock = LeaseClock()
    let store = MemoryAgentLeaseStore()
    var events: [AgentLeaseLifecycleEvent] = []
    let registry = try AgentLeaseRegistry(
        persistence: store,
        now: { clock.now },
        onEvent: { events.append($0) }
    )
    let acquired = try registry.acquire(owner: "gemini", ttl: 5, maxLifetime: 100)
    clock.advance(5)

    do {
        _ = try registry.heartbeat(acquired.id)
        Issue.record("An expired lease accepted a heartbeat")
    } catch {
        #expect(error as? AgentLeaseRegistryError == .leaseNotActive(acquired.id))
    }

    #expect(store.state.leases.first?.state == .timeout)
    #expect(events.last?.kind == .timedOut)
    #expect(events.last?.timeoutCause == .ttl)
    #expect(!registry.shouldKeepAwake)
}

@MainActor
@Test func listAndStatusRefreshCrossProcessChanges() throws {
    let fixture = try temporaryLeaseFile()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let clock = LeaseClock()
    let firstRegistry = try AgentLeaseRegistry(
        persistence: FileAgentLeaseStore(fileURL: fixture.file),
        now: { clock.now }
    )
    let secondRegistry = try AgentLeaseRegistry(
        persistence: FileAgentLeaseStore(fileURL: fixture.file),
        now: { clock.now }
    )

    let first = try firstRegistry.acquire(owner: "first")
    let second = try secondRegistry.acquire(owner: "second")
    #expect(Set(try firstRegistry.list(includeTerminal: false).map(\.id)) == [first.id, second.id])

    _ = try firstRegistry.release(first.id)
    #expect(firstRegistry.shouldKeepAwake)
    #expect(try secondRegistry.status(for: first.id)?.state == .success)

    _ = try secondRegistry.release(second.id)
    #expect(!secondRegistry.shouldKeepAwake)
    let all = try firstRegistry.list()
    #expect(all.count == 2)
    #expect(all.allSatisfy { $0.state == .success })
}

@MainActor
@Test func refreshEmitsAuditableEventsForExternalLifecycleChanges() throws {
    let clock = LeaseClock()
    let store = MemoryAgentLeaseStore()
    let writer = try AgentLeaseRegistry(
        persistence: store,
        now: { clock.now }
    )
    var observed: [AgentLeaseLifecycleEvent] = []
    var snapshots: [AgentLeaseSnapshot] = []
    let observer = try AgentLeaseRegistry(
        persistence: store,
        now: { clock.now },
        onEvent: { observed.append($0) },
        onSnapshotChange: { snapshots.append($0) }
    )

    let acquired = try writer.acquire(owner: "codex-cli", ttl: 60, maxLifetime: 600)
    _ = try observer.refresh()
    clock.advance(5)
    _ = try writer.heartbeat(acquired.id)
    _ = try observer.refresh()
    clock.advance(5)
    _ = try writer.renew(acquired.id, ttl: 120)
    _ = try observer.refresh()
    clock.advance(5)
    _ = try writer.release(acquired.id, outcome: .failure(reason: "tool failed"))
    _ = try observer.refresh()

    #expect(observed.map(\.kind) == [.acquired, .heartbeat, .renewed, .released])
    #expect(observed.allSatisfy { $0.source == .external })
    #expect(observed.first?.previousState == nil)
    #expect(observed.dropFirst().allSatisfy { $0.previousState == .active })
    #expect(observed.last?.lease.state == .failure(reason: "tool failed"))
    #expect(snapshots.count == 5)
    #expect(snapshots.first?.activeCount == 0)
    #expect(snapshots.last?.shouldKeepAwake == false)
}

@MainActor
@Test func fileReloadDoesNotMistakeSubsecondDatesForExternalChanges() throws {
    let fixture = try temporaryLeaseFile()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let clock = LeaseClock(Date(timeIntervalSince1970: 1_800_000_000.1234567))
    var events: [AgentLeaseLifecycleEvent] = []
    var snapshots: [AgentLeaseSnapshot] = []
    let registry = try AgentLeaseRegistry(
        persistence: FileAgentLeaseStore(fileURL: fixture.file),
        now: { clock.now },
        onEvent: { events.append($0) },
        onSnapshotChange: { snapshots.append($0) }
    )
    _ = try registry.acquire(owner: "fractional-clock")
    events.removeAll()
    snapshots.removeAll()

    _ = try registry.refresh()

    #expect(events.isEmpty)
    #expect(snapshots.isEmpty)
}

@MainActor
@Test func refreshReconstructsExternalLifecycleCompletedBetweenPolls() throws {
    let clock = LeaseClock()
    let store = MemoryAgentLeaseStore()
    let writer = try AgentLeaseRegistry(persistence: store, now: { clock.now })
    var observed: [AgentLeaseLifecycleEvent] = []
    let observer = try AgentLeaseRegistry(
        persistence: store,
        now: { clock.now },
        onEvent: { observed.append($0) }
    )

    let item = try writer.acquire(owner: "fast-cli-task")
    clock.advance(1)
    _ = try writer.heartbeat(item.id)
    clock.advance(1)
    _ = try writer.release(item.id)
    _ = try observer.refresh()

    #expect(observed.map(\.kind) == [.acquired, .heartbeat, .released])
    #expect(observed.allSatisfy { $0.source == .external })
    #expect(observed.map(\.date) == [item.acquiredAt, item.acquiredAt.addingTimeInterval(1), clock.now])
}

@MainActor
@Test func terminalRetentionIsBoundedWithoutRemovingActiveLeases() throws {
    let clock = LeaseClock()
    let store = MemoryAgentLeaseStore()
    let registry = try AgentLeaseRegistry(
        persistence: store,
        terminalRetentionLimit: 2,
        now: { clock.now }
    )
    let active = try registry.acquire(owner: "still-running")
    var completedIDs: [UUID] = []

    for index in 0..<4 {
        clock.advance(1)
        let item = try registry.acquire(owner: "completed-\(index)")
        _ = try registry.release(item.id)
        completedIDs.append(item.id)
    }

    let saved = try registry.list(refreshFromDisk: false)
    #expect(saved.filter(\.isActive).map(\.id) == [active.id])
    #expect(saved.filter { $0.state.isTerminal }.map(\.id) == Array(completedIDs.suffix(2)))
    #expect(store.state.leases.count == 3)
}

@MainActor
@Test func registryRestoresActiveLeasesAndExpiresOverdueOnRelaunch() throws {
    let fixture = try temporaryLeaseFile()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let clock = LeaseClock()

    let firstRegistry = try AgentLeaseRegistry(
        persistence: FileAgentLeaseStore(fileURL: fixture.file),
        now: { clock.now }
    )
    let acquired = try firstRegistry.acquire(owner: "overnight", ttl: 10, maxLifetime: 100)

    clock.advance(5)
    var restoredEvents: [AgentLeaseLifecycleEvent] = []
    let restoredRegistry = try AgentLeaseRegistry(
        persistence: FileAgentLeaseStore(fileURL: fixture.file),
        now: { clock.now },
        onEvent: { restoredEvents.append($0) }
    )
    #expect(restoredRegistry.shouldKeepAwake)
    #expect(restoredEvents.map(\.kind) == [.restored])

    clock.advance(5)
    var recoveryEvents: [AgentLeaseLifecycleEvent] = []
    let recoveredAfterDeadline = try AgentLeaseRegistry(
        persistence: FileAgentLeaseStore(fileURL: fixture.file),
        now: { clock.now },
        onEvent: { recoveryEvents.append($0) }
    )
    #expect(!recoveredAfterDeadline.shouldKeepAwake)
    #expect(recoveryEvents.map(\.kind) == [.timedOut])
    #expect(recoveryEvents.first?.timeoutCause == .ttl)
    #expect(try recoveredAfterDeadline.status(for: acquired.id)?.state == .timeout)

    let finalReload = try AgentLeaseRegistry(
        persistence: FileAgentLeaseStore(fileURL: fixture.file),
        now: { clock.now }
    )
    #expect(try finalReload.status(for: acquired.id)?.state == .timeout)
}

@Test func fileStoreQuarantinesCorruptJSONBeforeRecovering() throws {
    let fixture = try temporaryLeaseFile()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try Data("{ definitely not valid JSON".utf8).write(to: fixture.file)
    let store = FileAgentLeaseStore(fileURL: fixture.file)

    #expect(try store.load() == .empty)
    #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    let quarantined = try FileManager.default.contentsOfDirectory(
        at: fixture.directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("agent-leases.corrupt-") }
    #expect(quarantined.count == 1)
    #expect(try Data(contentsOf: quarantined[0]) == Data("{ definitely not valid JSON".utf8))

    let wanted = lease(owner: "after-corruption")
    _ = try store.update { $0.leases.append(wanted) }
    #expect(try store.load().leases == [wanted])
}

@Test func fileStoreLeavesFutureSchemaUntouched() throws {
    let fixture = try temporaryLeaseFile()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let raw = Data(#"{"schemaVersion":999,"leases":[]}"#.utf8)
    try raw.write(to: fixture.file)
    let store = FileAgentLeaseStore(fileURL: fixture.file)

    do {
        _ = try store.load()
        Issue.record("A future schema was accepted")
    } catch {
        #expect(error as? FileAgentLeaseStoreError == .unsupportedSchemaVersion(999))
    }
    #expect(try Data(contentsOf: fixture.file) == raw)
}

@Test func concurrentFileTransactionsDoNotLoseLeases() throws {
    let fixture = try temporaryLeaseFile()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let ids = (0..<40).map { _ in UUID() }
    let errors = ConcurrentErrors()
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    DispatchQueue.concurrentPerform(iterations: ids.count) { index in
        do {
            let store = FileAgentLeaseStore(fileURL: fixture.file)
            let item = lease(
                id: ids[index],
                owner: "owner-\(index)",
                acquiredAt: start.addingTimeInterval(TimeInterval(index))
            )
            _ = try store.update { $0.leases.append(item) }
        } catch {
            errors.append(error)
        }
    }

    #expect(errors.values.isEmpty)
    let saved = try FileAgentLeaseStore(fileURL: fixture.file).load()
    #expect(saved.leases.count == ids.count)
    #expect(Set(saved.leases.map(\.id)) == Set(ids))
}

@MainActor
@Test func registryValidatesOwnerAndDurations() throws {
    let registry = try AgentLeaseRegistry(persistence: MemoryAgentLeaseStore())

    do {
        _ = try registry.acquire(owner: "  \n")
        Issue.record("A blank owner was accepted")
    } catch {
        #expect(error as? AgentLeaseRegistryError == .invalidOwner)
    }
    for ttl in [0, -1, .infinity, .nan] {
        do {
            _ = try registry.acquire(owner: "owner", ttl: ttl)
            Issue.record("An invalid TTL was accepted")
        } catch {
            #expect(error as? AgentLeaseRegistryError == .invalidTTL)
        }
    }
    do {
        _ = try registry.acquire(
            owner: "owner",
            ttl: AgentLeaseRegistry.maximumAllowedLifetime + 1
        )
        Issue.record("A TTL above the hard safety ceiling was accepted")
    } catch {
        #expect(error as? AgentLeaseRegistryError == .invalidTTL)
    }
    do {
        _ = try registry.acquire(owner: "owner", maxLifetime: 0)
        Issue.record("An invalid maximum lifetime was accepted")
    } catch {
        #expect(error as? AgentLeaseRegistryError == .invalidMaxLifetime)
    }
    do {
        _ = try registry.acquire(
            owner: "owner",
            maxLifetime: AgentLeaseRegistry.maximumAllowedLifetime + 1
        )
        Issue.record("A maximum lifetime above the hard safety ceiling was accepted")
    } catch {
        #expect(error as? AgentLeaseRegistryError == .invalidMaxLifetime)
    }
    do {
        _ = try AgentLeaseRegistry(
            persistence: MemoryAgentLeaseStore(),
            terminalRetentionLimit: -1
        )
        Issue.record("A negative terminal retention limit was accepted")
    } catch {
        #expect(error as? AgentLeaseRegistryError == .invalidTerminalRetentionLimit)
    }
}

@MainActor
@Test func duplicateAndMissingLeaseErrorsAreStable() throws {
    let registry = try AgentLeaseRegistry(persistence: MemoryAgentLeaseStore())
    let id = UUID()
    _ = try registry.acquire(id: id, owner: "owner")

    do {
        _ = try registry.acquire(id: id, owner: "retry")
        Issue.record("A duplicate id was accepted")
    } catch {
        #expect(error as? AgentLeaseRegistryError == .leaseAlreadyExists(id))
    }

    let missing = UUID()
    do {
        _ = try registry.heartbeat(missing)
        Issue.record("A missing lease accepted a heartbeat")
    } catch {
        #expect(error as? AgentLeaseRegistryError == .leaseNotFound(missing))
    }
}
