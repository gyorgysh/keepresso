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

private final class MCPLeaseStore: AgentLeasePersisting {
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
private final class SilentMCPAppSignaler: AgentLeaseAppSignaling {
    func leaseStateDidChange(launchIfNeeded: Bool) {}
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
        params: [
            "protocolVersion": version,
            "capabilities": [:],
            "clientInfo": ["name": "Keepresso Tests", "version": "1.0"],
        ]
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
            params: [
                "protocolVersion": version,
                "capabilities": [:],
                "clientInfo": ["name": "Keepresso Tests", "version": "1.0"],
            ]
        )
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == version)
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] as? [String: Any] != nil)
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "keepresso-mcp")
    }
}

@Test @MainActor func mcpInitializeRejectsIncompleteClientMetadata() throws {
    let cases: [[String: Any]] = [
        ["protocolVersion": "2025-11-25", "clientInfo": ["name": "Client", "version": "1"]],
        ["protocolVersion": "2025-11-25", "capabilities": [], "clientInfo": ["name": "Client", "version": "1"]],
        ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": [:]],
        ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Client"]],
    ]
    for parameters in cases {
        let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
        let response = try callMCP(server, method: "initialize", params: parameters)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
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

@Test @MainActor func idLessMCPNotificationsHaveNoResponse() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    for method in ["notifications/initialized", "notifications/cancelled", "notifications/progress"] {
        let notification = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": method,
        ])
        #expect(server.handle(notification) == nil)
    }
}

@Test @MainActor func requestNamedLikeNotificationStillGetsProtocolError() throws {
    let server = KeepressoMCPServer(commander: RecordingLeaseCommander())
    let response = try callMCP(server, id: 7, method: "notifications/progress", params: [:])
    let error = try #require(response["error"] as? [String: Any])
    #expect(error["code"] as? Int == -32601)
    #expect(response["id"] as? Int == 7)
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

@Test @MainActor func mcpStructuredContentCarriesLatestLifecycleMessage() throws {
    let adapter = try AgentLeaseCommandAdapter(
        persistence: MCPLeaseStore(),
        appSignaler: SilentMCPAppSignaler()
    )
    let server = KeepressoMCPServer(commander: adapter)
    try completeInitialization(server)

    let acquired = try callMCP(server, method: "tools/call", params: [
        "name": "acquire_wake_lease",
        "arguments": [
            "owner": "quasar", "agent": "codex", "task": "tests",
            "message": "starting",
        ],
    ])
    let acquiredResult = try #require(acquired["result"] as? [String: Any])
    let acquiredContent = try #require(acquiredResult["structuredContent"] as? [String: Any])
    let acquiredLease = try #require(acquiredContent["lease"] as? [String: Any])
    let leaseID = try #require(acquiredLease["id"] as? String)
    #expect(acquiredLease["message"] as? String == "starting")

    let heartbeat = try callMCP(server, method: "tools/call", params: [
        "name": "heartbeat_wake_lease",
        "arguments": ["lease_id": leaseID, "message": "running tests"],
    ])
    let heartbeatResult = try #require(heartbeat["result"] as? [String: Any])
    let heartbeatContent = try #require(
        heartbeatResult["structuredContent"] as? [String: Any]
    )
    let heartbeatLease = try #require(heartbeatContent["lease"] as? [String: Any])
    #expect(heartbeatLease["message"] as? String == "running tests")

    let released = try callMCP(server, method: "tools/call", params: [
        "name": "release_wake_lease",
        "arguments": [
            "lease_id": leaseID, "result": "success", "message": "complete",
        ],
    ])
    let releasedResult = try #require(released["result"] as? [String: Any])
    let releasedContent = try #require(releasedResult["structuredContent"] as? [String: Any])
    let releasedLease = try #require(releasedContent["lease"] as? [String: Any])
    #expect(releasedLease["message"] as? String == "complete")
}

@Test @MainActor func mcpArgumentErrorsAreToolResultsAndUnknownToolsAreProtocolErrors() throws {
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
    let unknownError = try #require(unknown["error"] as? [String: Any])
    #expect(unknownError["code"] as? Int == -32602)
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

@Test @MainActor func mcpBoundsMessageSizeAndToolInvocationRate() throws {
    let commander = RecordingLeaseCommander()
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let server = KeepressoMCPServer(commander: commander, now: { instant })
    try completeInitialization(server)

    for index in 0..<KeepressoMCPServer.maximumToolCallsPerMinute {
        let response = try callMCP(
            server,
            id: index,
            method: "tools/call",
            params: ["name": "wake_status", "arguments": [:]]
        )
        #expect(response["result"] != nil)
    }
    let limited = try callMCP(
        server,
        id: "limited",
        method: "tools/call",
        params: ["name": "wake_status", "arguments": [:]]
    )
    let rateError = try #require(limited["error"] as? [String: Any])
    #expect(rateError["code"] as? Int == -32000)
    #expect(commander.commands.count == KeepressoMCPServer.maximumToolCallsPerMinute)

    let oversized = Data(
        repeating: 0x20,
        count: KeepressoMCPServer.maximumMessageBytes + 1
    )
    let oversizedResponse = try #require(server.handle(oversized))
    let envelope = try #require(
        JSONSerialization.jsonObject(with: oversizedResponse) as? [String: Any]
    )
    let sizeError = try #require(envelope["error"] as? [String: Any])
    #expect(sizeError["code"] as? Int == -32600)
}
