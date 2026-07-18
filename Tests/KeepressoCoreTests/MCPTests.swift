import Foundation
import Testing
@testable import KeepressoCore

@MainActor
private final class RecordingLeaseCommander: LeaseCommanding {
    var commands: [LeaseCommand] = []
    var nextResponse: LeaseCommandResponse?

    func execute(_ command: LeaseCommand) -> LeaseCommandResponse {
        commands.append(command)
        return nextResponse ?? LeaseCommandResponse(
            ok: true,
            command: command.operation,
            code: "ok",
            message: "recorded"
        )
    }
}

@MainActor
private func callMCP(
    _ server: KeepressoMCPServer,
    id: Any = 1,
    method: String,
    params: [String: Any]? = nil
) throws -> [String: Any] {
    var request: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
    ]
    if let params { request["params"] = params }
    let requestData = try JSONSerialization.data(withJSONObject: request)
    let responseData = try #require(server.handle(requestData))
    return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
}

@MainActor
private func completeInitialization(
    _ server: KeepressoMCPServer,
    version: String = "2025-11-25"
) throws {
    _ = try callMCP(
        server,
        method: "initialize",
        params: ["protocolVersion": version, "capabilities": [:], "clientInfo": [:]]
    )
    let notification = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
    ])
    #expect(server.handle(notification) == nil)
}

@Test @MainActor func mcpInitializeNegotiatesSupportedVersions() throws {
    for version in ["2025-06-18", "2025-11-25"] {
        let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
        let response = try callMCP(
            server,
            method: "initialize",
            params: ["protocolVersion": version, "capabilities": [:], "clientInfo": [:]]
        )
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == version)
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] as? [String: Any] != nil)
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "keepresso-mcp")
    }
}

@Test @MainActor func mcpRequiresInitializationLifecycle() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    let tooEarly = try callMCP(server, method: "tools/list", params: [:])
    let error = try #require(tooEarly["error"] as? [String: Any])
    #expect(error["code"] as? Int == -32002)

    try completeInitialization(server)
    let response = try callMCP(server, method: "tools/list", params: [:])
    #expect(response["result"] as? [String: Any] != nil)
}

@Test @MainActor func allMCPNotificationsHaveNoResponse() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    for method in ["notifications/initialized", "notifications/cancelled", "notifications/progress"] {
        let notification = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 7,
            "method": method,
        ])
        #expect(server.handle(notification) == nil)
    }
}

@Test @MainActor func mcpListsExactlyTheWakeLeaseTools() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    try completeInitialization(server)
    let response = try callMCP(server, method: "tools/list", params: [:])
    let result = try #require(response["result"] as? [String: Any])
    let tools = try #require(result["tools"] as? [[String: Any]])
    let names = tools.compactMap { $0["name"] as? String }
    #expect(names == [
        "acquire_wake_lease",
        "renew_wake_lease",
        "heartbeat_wake_lease",
        "release_wake_lease",
        "list_wake_leases",
        "wake_status",
    ])
    for tool in tools {
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
    }
}

@Test @MainActor func mcpAcquireMapsArgumentsAndReturnsStructuredContent() throws {
    let commander = RecordingLeaseCommander()
    let server = KeepressoMCPServer(commander: commander)
    try completeInitialization(server)
    let response = try callMCP(
        server,
        id: "call-1",
        method: "tools/call",
        params: [
            "name": "acquire_wake_lease",
            "arguments": [
                "owner": "quasar",
                "agent": "codex",
                "task": "fix-tests",
                "ttl": 300,
                "max_lifetime": 7_200,
                "message": "working",
            ],
        ]
    )
    #expect(commander.commands == [.acquire(
        owner: "quasar",
        agent: "codex",
        task: "fix-tests",
        ttlSeconds: 300,
        maxLifetimeSeconds: 7_200,
        message: "working"
    )])
    #expect(response["id"] as? String == "call-1")
    let result = try #require(response["result"] as? [String: Any])
    #expect(result["isError"] as? Bool == false)
    let structured = try #require(result["structuredContent"] as? [String: Any])
    #expect(structured["command"] as? String == "acquire")
    let content = try #require(result["content"] as? [[String: Any]])
    #expect(content.first?["type"] as? String == "text")
}

@Test @MainActor func mcpMapsRenewHeartbeatReleaseListAndStatus() throws {
    let commander = RecordingLeaseCommander()
    let server = KeepressoMCPServer(commander: commander)
    try completeInitialization(server)

    _ = try callMCP(server, method: "tools/call", params: [
        "name": "renew_wake_lease",
        "arguments": ["lease_id": "lease-1", "ttl": 180, "message": "progress"],
    ])
    _ = try callMCP(server, method: "tools/call", params: [
        "name": "heartbeat_wake_lease",
        "arguments": ["lease_id": "lease-1"],
    ])
    _ = try callMCP(server, method: "tools/call", params: [
        "name": "release_wake_lease",
        "arguments": ["lease_id": "lease-1", "result": "cancelled", "message": "stopped"],
    ])
    _ = try callMCP(server, method: "tools/call", params: [
        "name": "list_wake_leases",
        "arguments": ["owner": "quasar", "include_inactive": true],
    ])
    _ = try callMCP(server, method: "tools/call", params: [
        "name": "wake_status",
        "arguments": ["lease_id": "lease-1"],
    ])

    #expect(commander.commands == [
        .renew(id: "lease-1", ttlSeconds: 180, message: "progress"),
        .heartbeat(id: "lease-1", ttlSeconds: nil, message: nil),
        .release(id: "lease-1", result: .cancelled, message: "stopped"),
        .list(LeaseListFilter(owner: "quasar", includeInactive: true)),
        .status(id: "lease-1"),
    ])
}

@Test @MainActor func mcpArgumentAndUnknownToolErrorsAreToolResults() throws {
    let commander = RecordingLeaseCommander()
    let server = KeepressoMCPServer(commander: commander)
    try completeInitialization(server)
    let invalid = try callMCP(server, method: "tools/call", params: [
        "name": "acquire_wake_lease",
        "arguments": ["owner": "quasar", "agent": "codex", "task": "task", "ttl": "soon"],
    ])
    let invalidResult = try #require(invalid["result"] as? [String: Any])
    #expect(invalidResult["isError"] as? Bool == true)
    let invalidStructured = try #require(invalidResult["structuredContent"] as? [String: Any])
    #expect(invalidStructured["code"] as? String == "invalid_arguments")

    let unknown = try callMCP(server, method: "tools/call", params: [
        "name": "make_coffee",
        "arguments": [:],
    ])
    #expect(unknown["error"] == nil)
    let unknownResult = try #require(unknown["result"] as? [String: Any])
    #expect(unknownResult["isError"] as? Bool == true)
    let unknownStructured = try #require(unknownResult["structuredContent"] as? [String: Any])
    #expect(unknownStructured["code"] as? String == "unknown_tool")
    #expect(commander.commands.isEmpty)
}

@Test @MainActor func unknownMethodAndMalformedJSONUseProtocolErrors() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    let unknown = try callMCP(server, method: "make/coffee", params: [:])
    let unknownError = try #require(unknown["error"] as? [String: Any])
    #expect(unknownError["code"] as? Int == -32601)

    let malformedData = try #require(server.handle(Data(#"{"jsonrpc": "2.0""#.utf8)))
    let malformed = try #require(JSONSerialization.jsonObject(with: malformedData) as? [String: Any])
    let parseError = try #require(malformed["error"] as? [String: Any])
    #expect(parseError["code"] as? Int == -32700)
}
