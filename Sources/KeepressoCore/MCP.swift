import CoreFoundation
import Foundation

/// A small JSON-RPC handler for the wake-lease MCP server.
/// Transport framing stays in the executable so this type is unit-testable.
public final class KeepressoMCPServer {
    public static let protocolVersion = "2025-11-25"

    private static let supportedProtocolVersions = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    private let commander: LeaseCommanding

    public init(commander: LeaseCommanding = FileLeaseCommander()) {
        self.commander = commander
    }

    /// Handle one newline-delimited JSON-RPC message.
    /// Notifications deliberately return nil because they have no response.
    public func handle(_ data: Data) -> Data? {
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
        let id = request["id"]
        if hasID, !Self.isValidRequestID(id) {
            return Self.encode(Self.errorEnvelope(id: NSNull(), code: -32600, message: "Invalid Request"))
        }

        let outcome = dispatch(method: method, params: request["params"])
        guard hasID, let id else { return nil }
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
            guard let parameters = Self.parameters(params),
                  let requestedVersion = parameters["protocolVersion"] as? String
            else { return .error(-32602, "initialize requires protocolVersion") }
            let selectedVersion = Self.supportedProtocolVersions.contains(requestedVersion)
                ? requestedVersion
                : Self.protocolVersion
            return .result([
                "protocolVersion": selectedVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "keepresso-mcp", "version": "1.0.0"],
                "instructions": "Acquire a wake lease before unattended work, renew it before expiry, and release it when work ends.",
            ])
        case "notifications/initialized":
            return .result([:])
        case "ping":
            guard Self.parameters(params, allowMissing: true) != nil else {
                return .error(-32602, "ping params must be an object")
            }
            return .result([:])
        case "tools/list":
            guard Self.parameters(params, allowMissing: true) != nil else {
                return .error(-32602, "tools/list params must be an object")
            }
            return .result(["tools": Self.toolDefinitions])
        case "tools/call":
            return callTool(params: params)
        default:
            return .error(-32601, "Method not found: \(method)")
        }
    }

    private func callTool(params: Any?) -> MCPMethodOutcome {
        guard let parameters = Self.parameters(params),
              let name = parameters["name"] as? String,
              !name.isEmpty
        else { return .error(-32602, "tools/call requires a tool name") }

        let arguments: [String: Any]
        if let value = parameters["arguments"] {
            guard !(value is NSNull), let object = value as? [String: Any] else {
                return .error(-32602, "tool arguments must be an object")
            }
            arguments = object
        } else {
            arguments = [:]
        }

        guard let operation = Self.operationName(for: name) else {
            return .error(-32602, "Unknown tool: \(name)")
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
        case "release_wake_lease":
            try rejectUnknown(arguments, allowed: ["lease_id", "result", "message"])
            let rawResult = try optionalString("result", arguments) ?? LeaseCompletionResult.success.rawValue
            guard let result = LeaseCompletionResult(rawValue: rawResult) else {
                throw MCPToolInputError("result must be success, failure, cancelled, or timeout")
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
            "name": "release_wake_lease",
            "description": "Release a wake lease when its AI task ends.",
            "inputSchema": objectSchema(
                properties: [
                    "lease_id": stringSchema("Identifier returned by acquire_wake_lease."),
                    "result": [
                        "type": "string",
                        "enum": LeaseCompletionResult.allCases.map(\.rawValue),
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
        ["type": "integer", "minimum": 1, "description": description]
    }

    private static func parameters(_ value: Any?, allowMissing: Bool = false) -> [String: Any]? {
        if value == nil || value is NSNull { return allowMissing ? [:] : nil }
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

private struct MCPToolInputError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}
