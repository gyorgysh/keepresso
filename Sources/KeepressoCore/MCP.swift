import CoreFoundation
import Foundation

public enum BoundedJSONLineFrame: Equatable, Sendable {
    case message(Data)
    case oversized
}

/// Incremental newline framing for the stdio MCP transport. Once a message
/// crosses the byte limit, its buffered bytes are released and subsequent
/// input is discarded through the next newline, so a missing newline cannot
/// make the server grow memory without bound.
public struct BoundedJSONLineFramer: Sendable {
    public let maximumMessageBytes: Int
    public private(set) var bufferedByteCount = 0
    public private(set) var isDiscardingOversizedMessage = false

    private var buffer = Data()

    public init(maximumMessageBytes: Int) {
        precondition(maximumMessageBytes > 0)
        self.maximumMessageBytes = maximumMessageBytes
        buffer.reserveCapacity(min(maximumMessageBytes, 4_096))
    }

    public mutating func append(_ chunk: Data) -> [BoundedJSONLineFrame] {
        var frames: [BoundedJSONLineFrame] = []
        for byte in chunk {
            if byte == 0x0A {
                if isDiscardingOversizedMessage {
                    frames.append(.oversized)
                } else {
                    frames.append(.message(buffer))
                }
                resetLine()
                continue
            }
            guard !isDiscardingOversizedMessage else { continue }
            if bufferedByteCount < maximumMessageBytes {
                buffer.append(byte)
                bufferedByteCount += 1
            } else {
                buffer.removeAll(keepingCapacity: false)
                bufferedByteCount = 0
                isDiscardingOversizedMessage = true
            }
        }
        return frames
    }

    public mutating func finish() -> BoundedJSONLineFrame? {
        guard isDiscardingOversizedMessage || bufferedByteCount > 0 else { return nil }
        let frame: BoundedJSONLineFrame = isDiscardingOversizedMessage
            ? .oversized
            : .message(buffer)
        resetLine()
        return frame
    }

    private mutating func resetLine() {
        buffer.removeAll(keepingCapacity: true)
        bufferedByteCount = 0
        isDiscardingOversizedMessage = false
    }
}

/// A small JSON-RPC handler for the wake-lease MCP server.
/// Transport framing stays in the executable so this type is unit-testable.
@MainActor
public final class KeepressoMCPServer {
    public static let protocolVersion = "2025-11-25"
    public static let maximumMessageBytes = 1_048_576
    public static let maximumToolCallsPerMinute = 120

    private static let supportedProtocolVersions = [
        "2025-11-25",
        "2025-06-18",
    ]

    private let commander: LeaseCommanding
    private let now: () -> Date
    private var lifecycle = MCPLifecycle.awaitingInitialize
    private var toolWindowStartedAt: Date?
    private var toolCallsInWindow = 0

    public init(
        commander: LeaseCommanding,
        now: @escaping () -> Date = Date.init
    ) {
        self.commander = commander
        self.now = now
    }

    public convenience init() throws {
        try self.init(commander: AgentLeaseCommandAdapter())
    }

    public static func messageTooLargeResponse() -> Data {
        encode(errorEnvelope(
            id: NSNull(),
            code: -32600,
            message: "Request exceeds the maximum message size"
        )) ?? Data()
    }

    /// Handle one newline-delimited JSON-RPC message.
    /// Notifications deliberately return nil because they have no response.
    public func handle(_ data: Data) -> Data? {
        guard data.count <= Self.maximumMessageBytes else {
            return Self.messageTooLargeResponse()
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            return Self.encode(Self.errorEnvelope(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let request = value as? [String: Any] else {
            return Self.encode(Self.errorEnvelope(id: NSNull(), code: -32600, message: "Invalid Request"))
        }

        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String,
              !method.isEmpty
        else {
            return Self.encode(Self.errorEnvelope(
                id: Self.validResponseID(from: request) ?? NSNull(),
                code: -32600,
                message: "Invalid Request"
            ))
        }

        let hasID = request.keys.contains("id")
        guard hasID else {
            if method == "notifications/initialized",
               lifecycle == .awaitingInitialized,
               Self.parameters(request["params"], allowMissing: true) != nil {
                lifecycle = .ready
            }
            return nil
        }
        let id = request["id"]
        guard Self.isValidRequestID(id) else {
            return Self.encode(Self.errorEnvelope(id: NSNull(), code: -32600, message: "Invalid Request"))
        }

        let outcome = dispatch(method: method, params: request["params"])
        guard let id else { return nil }
        switch outcome {
        case .result(let result):
            return Self.encode([
                "jsonrpc": "2.0",
                "id": id,
                "result": result,
            ])
        case .error(let code, let message):
            return Self.encode(Self.errorEnvelope(id: id, code: code, message: message))
        }
    }

    private func dispatch(method: String, params: Any?) -> MCPMethodOutcome {
        switch method {
        case "initialize":
            guard lifecycle == .awaitingInitialize else {
                return .error(-32600, "Server is already initialized")
            }
            guard let parameters = Self.parameters(params),
                  let requestedVersion = parameters["protocolVersion"] as? String,
                  !requestedVersion.isEmpty,
                  Self.validClientCapabilities(parameters["capabilities"]),
                  let clientInfo = parameters["clientInfo"] as? [String: Any],
                  Self.validClientInfo(clientInfo)
            else {
                return .error(
                    -32602,
                    "initialize requires protocolVersion, capabilities, and clientInfo name/version"
                )
            }
            let selectedVersion = Self.supportedProtocolVersions.contains(requestedVersion)
                ? requestedVersion
                : Self.protocolVersion
            lifecycle = .awaitingInitialized
            return .result([
                "protocolVersion": selectedVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "keepresso-mcp", "version": "1.0.0"],
                "instructions": "Acquire a wake lease before unattended work, renew it before expiry, and release it when work ends.",
            ])
        case "ping":
            guard Self.parameters(params, allowMissing: true) != nil else {
                return .error(-32602, "ping params must be an object")
            }
            return .result([:])
        case "tools/list":
            guard lifecycle == .ready else { return .error(-32002, "Server is not initialized") }
            guard Self.parameters(params, allowMissing: true) != nil else {
                return .error(-32602, "tools/list params must be an object")
            }
            return .result(["tools": Self.toolDefinitions])
        case "tools/call":
            guard lifecycle == .ready else { return .error(-32002, "Server is not initialized") }
            guard admitToolCall() else {
                return .error(-32000, "Tool invocation rate limit exceeded")
            }
            return callTool(params: params)
        default:
            return .error(-32601, "Method not found: \(method)")
        }
    }

    private func admitToolCall() -> Bool {
        let instant = now()
        if let start = toolWindowStartedAt,
           instant >= start,
           instant.timeIntervalSince(start) < 60 {
            guard toolCallsInWindow < Self.maximumToolCallsPerMinute else { return false }
            toolCallsInWindow += 1
            return true
        }
        toolWindowStartedAt = instant
        toolCallsInWindow = 1
        return true
    }

    private func callTool(params: Any?) -> MCPMethodOutcome {
        guard let parameters = Self.parameters(params),
              let name = parameters["name"] as? String,
              !name.isEmpty
        else { return .error(-32602, "tools/call requires a tool name") }

        guard let operation = Self.operationName(for: name) else {
            return .error(-32602, "Unknown tool: \(name)")
        }

        let arguments: [String: Any]
        if let value = parameters["arguments"] {
            guard !(value is NSNull), let object = value as? [String: Any] else {
                return .error(-32602, "tools/call arguments must be an object")
            }
            arguments = object
        } else {
            arguments = [:]
        }
        do {
            let command = try Self.command(tool: name, arguments: arguments)
            return .result(Self.toolResult(commander.execute(command)))
        } catch let error as MCPToolInputError {
            return .result(Self.toolResult(.failure(
                command: operation,
                code: "invalid_arguments",
                message: error.message
            )))
        } catch {
            return .error(-32603, "Internal error")
        }
    }

    private static func operationName(for tool: String) -> String? {
        switch tool {
        case "acquire_wake_lease": return "acquire"
        case "renew_wake_lease": return "renew"
        case "heartbeat_wake_lease": return "heartbeat"
        case "release_wake_lease": return "release"
        case "list_wake_leases": return "list"
        case "wake_status": return "status"
        default: return nil
        }
    }

    private static func command(tool name: String, arguments: [String: Any]) throws -> LeaseCommand {
        switch name {
        case "acquire_wake_lease":
            try rejectUnknown(
                arguments,
                allowed: ["owner", "agent", "task", "ttl", "max_lifetime", "message"]
            )
            return .acquire(
                owner: try requiredString("owner", arguments),
                agent: try requiredString("agent", arguments),
                task: try requiredString("task", arguments),
                ttlSeconds: try positiveInteger("ttl", arguments),
                maxLifetimeSeconds: try positiveInteger("max_lifetime", arguments),
                message: try optionalString("message", arguments)
            )
        case "renew_wake_lease":
            try rejectUnknown(arguments, allowed: ["lease_id", "ttl", "message"])
            return .renew(
                id: try requiredString("lease_id", arguments),
                ttlSeconds: try positiveInteger("ttl", arguments),
                message: try optionalString("message", arguments)
            )
        case "heartbeat_wake_lease":
            try rejectUnknown(arguments, allowed: ["lease_id", "ttl", "message"])
            return .heartbeat(
                id: try requiredString("lease_id", arguments),
                ttlSeconds: try positiveInteger("ttl", arguments),
                message: try optionalString("message", arguments)
            )
        case "release_wake_lease":
            try rejectUnknown(arguments, allowed: ["lease_id", "result", "message"])
            let rawResult = try optionalString("result", arguments) ?? LeaseCompletionResult.success.rawValue
            guard let result = LeaseCompletionResult(rawValue: rawResult), result != .timeout else {
                throw MCPToolInputError("result must be success, failure, or cancelled")
            }
            return .release(
                id: try requiredString("lease_id", arguments),
                result: result,
                message: try optionalString("message", arguments)
            )
        case "list_wake_leases":
            try rejectUnknown(
                arguments,
                allowed: ["owner", "agent", "task", "include_inactive"]
            )
            return .list(LeaseListFilter(
                owner: try optionalString("owner", arguments),
                agent: try optionalString("agent", arguments),
                task: try optionalString("task", arguments),
                includeInactive: try optionalBoolean("include_inactive", arguments) ?? false
            ))
        case "wake_status":
            try rejectUnknown(arguments, allowed: ["lease_id"])
            return .status(id: try optionalString("lease_id", arguments))
        default:
            preconditionFailure("Unknown tools are rejected before argument parsing")
        }
    }

    private static func toolResult(_ response: LeaseCommandResponse) -> [String: Any] {
        guard let data = LeaseJSON.encode(response, prettyPrinted: false),
              let structured = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [
                "content": [["type": "text", "text": "Could not encode the lease response."]],
                "isError": true,
            ]
        }
        return [
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "structuredContent": structured,
            "isError": !response.ok,
        ]
    }

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": "acquire_wake_lease",
            "description": "Acquire an expiring wake lease before an unattended AI task starts.",
            "inputSchema": objectSchema(
                properties: [
                    "owner": stringSchema("Human or automation owner of the task."),
                    "agent": stringSchema("Agent implementation, such as codex or claude-code."),
                    "task": stringSchema("Stable task name or task identifier."),
                    "ttl": integerSchema("Seconds until the lease expires without renewal."),
                    "max_lifetime": integerSchema("Maximum total lease lifetime in seconds."),
                    "message": stringSchema("Optional human-readable context."),
                ],
                required: ["owner", "agent", "task"]
            ),
        ],
        [
            "name": "renew_wake_lease",
            "description": "Renew an active wake lease before its TTL expires.",
            "inputSchema": objectSchema(
                properties: [
                    "lease_id": stringSchema("Identifier returned by acquire_wake_lease."),
                    "ttl": integerSchema("New TTL in seconds, capped by the maximum lifetime."),
                    "message": stringSchema("Optional progress context."),
                ],
                required: ["lease_id"]
            ),
        ],
        [
            "name": "heartbeat_wake_lease",
            "description": "Heartbeat an active wake lease using its current TTL.",
            "inputSchema": objectSchema(
                properties: [
                    "lease_id": stringSchema("Identifier returned by acquire_wake_lease."),
                    "ttl": integerSchema("Optional replacement TTL in seconds."),
                    "message": stringSchema("Optional progress context."),
                ],
                required: ["lease_id"]
            ),
        ],
        [
            "name": "release_wake_lease",
            "description": "Release a wake lease when its AI task ends.",
            "inputSchema": objectSchema(
                properties: [
                    "lease_id": stringSchema("Identifier returned by acquire_wake_lease."),
                    "result": [
                        "type": "string",
                        "enum": ["success", "failure", "cancelled"],
                        "description": "Terminal task result. Defaults to success.",
                    ],
                    "message": stringSchema("Optional completion details."),
                ],
                required: ["lease_id"]
            ),
        ],
        [
            "name": "list_wake_leases",
            "description": "List active wake leases, with optional exact-match filters.",
            "inputSchema": objectSchema(properties: [
                "owner": stringSchema("Filter by owner."),
                "agent": stringSchema("Filter by agent."),
                "task": stringSchema("Filter by task."),
                "include_inactive": [
                    "type": "boolean",
                    "description": "Include released and expired leases.",
                ],
            ]),
        ],
        [
            "name": "wake_status",
            "description": "Report aggregate wake demand or inspect one lease.",
            "inputSchema": objectSchema(properties: [
                "lease_id": stringSchema("Optional lease identifier to inspect."),
            ]),
        ],
    ]

    private static func objectSchema(
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "minLength": 1, "description": description]
    }

    private static func integerSchema(_ description: String) -> [String: Any] {
        [
            "type": "integer",
            "minimum": 1,
            "maximum": Int(AgentLeaseRegistry.maximumAllowedLifetime),
            "description": description,
        ]
    }

    private static func validClientCapabilities(_ value: Any?) -> Bool {
        guard let capabilities = value as? [String: Any] else { return false }
        for key in ["experimental", "roots", "sampling", "elicitation"] {
            if let value = capabilities[key], !(value is [String: Any]) { return false }
        }
        if let roots = capabilities["roots"] as? [String: Any],
           let listChanged = roots["listChanged"],
           !(listChanged is Bool) {
            return false
        }
        return true
    }

    private static func validClientInfo(_ clientInfo: [String: Any]) -> Bool {
        guard clientInfo["name"] is String,
              clientInfo["version"] is String
        else { return false }
        if let title = clientInfo["title"], !(title is String) { return false }
        if let website = clientInfo["websiteUrl"] {
            guard let raw = website as? String, isAbsoluteURI(raw) else { return false }
        }
        if let rawIcons = clientInfo["icons"] {
            guard let icons = rawIcons as? [[String: Any]] else { return false }
            for icon in icons {
                guard let src = icon["src"] as? String, isAbsoluteURI(src) else { return false }
                if let mimeType = icon["mimeType"], !(mimeType is String) { return false }
                if let sizes = icon["sizes"], !(sizes is [String]) { return false }
                if let rawTheme = icon["theme"] {
                    guard let theme = rawTheme as? String,
                          ["light", "dark"].contains(theme)
                    else { return false }
                }
            }
        }
        return true
    }

    private static func isAbsoluteURI(_ raw: String) -> Bool {
        URLComponents(string: raw)?.scheme?.isEmpty == false
    }

    private static func parameters(_ value: Any?, allowMissing: Bool = false) -> [String: Any]? {
        if value == nil { return allowMissing ? [:] : nil }
        if value is NSNull { return nil }
        return value as? [String: Any]
    }

    private static func requiredString(
        _ name: String,
        _ arguments: [String: Any]
    ) throws -> String {
        guard let value = try optionalString(name, arguments) else {
            throw MCPToolInputError("\(name) is required")
        }
        return value
    }

    private static func optionalString(
        _ name: String,
        _ arguments: [String: Any]
    ) throws -> String? {
        guard let raw = arguments[name], !(raw is NSNull) else { return nil }
        guard let value = raw as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MCPToolInputError("\(name) must be a non-empty string") }
        return value
    }

    private static func positiveInteger(
        _ name: String,
        _ arguments: [String: Any]
    ) throws -> Int? {
        guard let raw = arguments[name], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber,
              !isBoolean(number),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 1,
              number.doubleValue <= Double(Int.max)
        else { throw MCPToolInputError("\(name) must be a positive whole number of seconds") }
        return number.intValue
    }

    private static func optionalBoolean(
        _ name: String,
        _ arguments: [String: Any]
    ) throws -> Bool? {
        guard let raw = arguments[name], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, isBoolean(number) else {
            throw MCPToolInputError("\(name) must be a boolean")
        }
        return number.boolValue
    }

    private static func rejectUnknown(
        _ arguments: [String: Any],
        allowed: Set<String>
    ) throws {
        if let unknown = Set(arguments.keys).subtracting(allowed).sorted().first {
            throw MCPToolInputError("unknown argument: \(unknown)")
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isValidRequestID(_ value: Any?) -> Bool {
        if value is String { return true }
        guard let number = value as? NSNumber else { return false }
        return !isBoolean(number)
            && number.doubleValue.isFinite
            && number.doubleValue.rounded() == number.doubleValue
    }

    private static func validResponseID(from request: [String: Any]) -> Any? {
        guard let id = request["id"], isValidRequestID(id) else { return nil }
        return id
    }

    private static func errorEnvelope(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

private enum MCPMethodOutcome {
    case result([String: Any])
    case error(Int, String)
}

private enum MCPLifecycle {
    case awaitingInitialize
    case awaitingInitialized
    case ready
}

private struct MCPToolInputError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}
