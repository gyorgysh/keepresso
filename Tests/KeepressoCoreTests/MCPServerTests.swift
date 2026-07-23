import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Fixtures

private let base = Date(timeIntervalSince1970: 3_000_000)
private let idA = "aaaaaaaa-1111-2222-3333-444444444444"

private final class MemoryStore: LeaseRecordStoring {
    var records: [String: AutomationLeaseRecord] = [:]
    func loadAll() -> [AutomationLeaseRecord] { Array(records.values) }
    func write(_ record: AutomationLeaseRecord) { records[record.id] = record }
    func delete(id: String) { records[id] = nil }
}

/// A server over a fully scripted world: acquire acks instantly, the clock
/// never really advances, and the wake state is canned.
private func makeServer(
    store: MemoryStore = MemoryStore(),
    snapshot: StatusSnapshot? = nil,
    ackIds: [String] = [idA]
) -> (MCPServer, MemoryStore) {
    let effective = snapshot ?? StatusSnapshot(
        isActive: true, pid: 77, writtenAt: base, leaseIDs: ackIds, leasesEnabled: true
    )
    let client = LeaseClient(
        store: store,
        now: { base },
        readStatus: { effective },
        nudgeApp: { true },
        sleep: { _ in },
        isPidAlive: { $0 == 77 },
        defaultOwner: "tester"
    )
    let wakeClient = WakeClient(
        now: { base },
        writeRequest: { _ in },
        readStatus: { effective },
        nudgeApp: { true },
        sleep: { _ in },
        isPidAlive: { $0 == 77 },
        readSched: { SystemWakeState() },
        generateId: { idA }
    )
    let server = MCPServer(
        leaseClient: client,
        wakeClient: wakeClient,
        readStatus: { effective },
        isPidAlive: { $0 == 77 },
        wakeState: { SystemWakeState(scheduledWakes: [base], repeatingSummary: "wakeorpoweron at 4:00AM every day") },
        generateId: { idA },
        serverVersion: "1.17.0-test"
    )
    return (server, store)
}

private func json(_ line: String?) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data((line ?? "").utf8))
    return try #require(object as? [String: Any])
}

// MARK: - Protocol surface

@Test func initializeHandshakes() throws {
    let (server, _) = makeServer()
    let response = try json(server.handle(
        line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
    ))
    #expect(response["id"] as? Int == 1)
    let result = try #require(response["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == MCPServer.protocolVersion)
    let info = try #require(result["serverInfo"] as? [String: Any])
    #expect(info["name"] as? String == "keepresso")
    #expect(info["version"] as? String == "1.17.0-test")
}

@Test func notificationsAndBlankLinesGetNoResponse() {
    let (server, _) = makeServer()
    #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    #expect(server.handle(line: "") == nil)
    #expect(server.handle(line: "   ") == nil)
}

@Test func protocolErrorsAreWellFormed() throws {
    let (server, _) = makeServer()

    let garbage = try json(server.handle(line: "not json at all"))
    #expect((garbage["error"] as? [String: Any])?["code"] as? Int == -32700)

    let unknown = try json(server.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#))
    #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    #expect(unknown["id"] as? Int == 5)

    let badTool = try json(server.handle(
        line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"frobnicate"}}"#
    ))
    #expect((badTool["error"] as? [String: Any])?["code"] as? Int == -32602)
}

@Test func toolsListNamesTheWholeSurface() throws {
    let (server, _) = makeServer()
    let response = try json(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
    let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String } == [
        "acquire_lease", "heartbeat_lease", "release_lease",
        "list_leases", "get_status", "get_wake_schedule",
        "set_wake_schedule", "clear_wake_schedule",
    ])
    // Every tool carries a JSON Schema for its input.
    #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
}

// MARK: - Tool calls

@Test func acquireLeaseGeneratesAnIdWhenNoneGiven() throws {
    let (server, store) = makeServer()
    let response = try json(server.handle(
        line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"acquire_lease","arguments":{"tool":"agent","task":"work","ttl_seconds":300}}}"#
    ))
    let result = try #require(response["result"] as? [String: Any])
    #expect(result["isError"] as? Bool == false)
    let content = try #require(result["content"] as? [[String: Any]])
    let text = try #require(content.first?["text"] as? String)
    #expect(text.contains(idA)) // the injected generator's id
    #expect(store.records[idA]?.tool == "agent")
}

@Test func toolCallFailuresRenderAsToolErrors() throws {
    let (server, _) = makeServer()

    // Missing required arguments never touch the store.
    let missing = try json(server.handle(
        line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"acquire_lease","arguments":{"task":"x","ttl_seconds":60}}}"#
    ))
    #expect((missing["result"] as? [String: Any])?["isError"] as? Bool == true)

    // A heartbeat against nothing is the lease-lost signal.
    let lost = try json(server.handle(
        line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"heartbeat_lease","arguments":{"id":"\#(idA)"}}}"#
    ))
    let result = try #require(lost["result"] as? [String: Any])
    #expect(result["isError"] as? Bool == true)
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
    #expect(text?.contains("no lease") == true)
}

@Test func statusAndWakeToolsReport() throws {
    let (server, _) = makeServer()

    let status = try json(server.handle(
        line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#
    ))
    let statusText = try #require(
        ((status["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(statusText.contains("\"appRunning\" : true"))
    #expect(statusText.contains("\"isActive\" : true"))

    let wake = try json(server.handle(
        line: #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_wake_schedule","arguments":{}}}"#
    ))
    let wakeText = try #require(
        ((wake["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(wakeText.contains("wakeorpoweron at 4:00AM every day"))
}

@Test func releaseAndListRoundTripOverMCP() throws {
    let (server, store) = makeServer()
    store.records[idA] = AutomationLeaseRecord(
        id: idA, owner: "o", tool: "agent", task: "work",
        createdAt: base, updatedAt: base, ttlSeconds: 300, maxLifetimeSeconds: 3_600
    )

    let release = try json(server.handle(
        line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"release_lease","arguments":{"id":"\#(idA)"}}}"#
    ))
    #expect((release["result"] as? [String: Any])?["isError"] as? Bool == false)
    #expect(store.records[idA]?.state == .released)

    let list = try json(server.handle(
        line: #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"list_leases","arguments":{}}}"#
    ))
    let text = ((list["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    #expect(text?.contains("\"state\" : \"released\"") == true)
}
