import Foundation
import Testing
@testable import KeepressoCore

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
    return try #require(
        JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    )
}

@Test func mcpInitializeNegotiatesSupportedVersions() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    for version in ["2025-06-18", "2025-11-25"] {
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

@Test func mcpInitializedNotificationHasNoResponse() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    let notification = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
    ])
    #expect(server.handle(notification) == nil)
}

@Test func mcpListsExactlyTheWakeLeaseTools() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    let response = try callMCP(server, method: "tools/list", params: [:])
    let result = try #require(response["result"] as? [String: Any])
    let tools = try #require(result["tools"] as? [[String: Any]])
    let names = tools.compactMap { $0["name"] as? String }
    #expect(names == [
        "acquire_wake_lease",
        "renew_wake_lease",
        "release_wake_lease",
        "list_wake_leases",
        "wake_status",
    ])
    for tool in tools {
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
    }
}

@Test func mcpAcquireMapsArgumentsAndReturnsStructuredContent() throws {
    let commander = RecordingLeaseCommander()
    let server = KeepressoMCPServer(commander: commander)
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

@Test func mcpMapsRenewReleaseListAndStatus() throws {
    let commander = RecordingLeaseCommander()
    let server = KeepressoMCPServer(commander: commander)

    _ = try callMCP(server, method: "tools/call", params: [
        "name": "renew_wake_lease",
        "arguments": ["lease_id": "lease-1", "ttl": 180, "message": "progress"],
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
        .release(id: "lease-1", result: .cancelled, message: "stopped"),
        .list(LeaseListFilter(owner: "quasar", includeInactive: true)),
        .status(id: "lease-1"),
    ])
}

@Test func mcpArgumentErrorsAreVisibleToolResults() throws {
    let commander = RecordingLeaseCommander()
    let server = KeepressoMCPServer(commander: commander)
    let response = try callMCP(server, method: "tools/call", params: [
        "name": "acquire_wake_lease",
        "arguments": ["owner": "quasar", "agent": "codex", "task": "task", "ttl": "soon"],
    ])

    #expect(response["error"] == nil)
    #expect(commander.commands.isEmpty)
    let result = try #require(response["result"] as? [String: Any])
    #expect(result["isError"] as? Bool == true)
    let structured = try #require(result["structuredContent"] as? [String: Any])
    #expect(structured["code"] as? String == "invalid_arguments")
    #expect(structured["command"] as? String == "acquire")
}

@Test func mcpUnknownToolAndMalformedJSONUseProtocolErrors() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    let unknown = try callMCP(server, method: "tools/call", params: [
        "name": "make_coffee",
        "arguments": [:],
    ])
    let unknownError = try #require(unknown["error"] as? [String: Any])
    #expect(unknownError["code"] as? Int == -32602)

    let malformedData = try #require(server.handle(Data(#"{"jsonrpc": "2.0""#.utf8)))
    let malformed = try #require(
        JSONSerialization.jsonObject(with: malformedData) as? [String: Any]
    )
    let parseError = try #require(malformed["error"] as? [String: Any])
    #expect(parseError["code"] as? Int == -32700)
}
