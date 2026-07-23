import Foundation

/// A minimal MCP (Model Context Protocol) server over newline-delimited
/// JSON-RPC 2.0, exposing automation leases and status to AI agents. Pure:
/// `handle(line:)` maps one request line to one response line (or nil for
/// notifications), with every effect injected, so the whole protocol surface
/// is golden-testable. The `keepresso-mcp` executable is a stdin loop around
/// this plus ``LeaseClient/real(ownerPid:)``.
///
/// Deliberately dependency-free and small: initialize, ping, tools/list, and
/// tools/call are all a lease-granting server needs. Every tool is a thin
/// adapter over the same ``LeaseClient`` the CLI uses, zero logic of its own.
public struct MCPServer {
    /// The protocol revision this server speaks.
    public static let protocolVersion = "2025-06-18"

    public var leaseClient: LeaseClient
    /// Wake set/clear operations; status reads go through `wakeState`.
    public var wakeClient: WakeClient
    /// The app's status snapshot plus liveness, as `keepresso status --json`.
    public var readStatus: () -> StatusSnapshot?
    public var isPidAlive: (Int32) -> Bool
    /// Unprivileged `pmset -g sched` read for `get_wake_schedule`.
    public var wakeState: () -> SystemWakeState
    /// Lease ids for `acquire_lease` calls that supply none.
    public var generateId: () -> String
    public var serverVersion: String

    public init(
        leaseClient: LeaseClient,
        wakeClient: WakeClient,
        readStatus: @escaping () -> StatusSnapshot? = { StatusFile.read() },
        isPidAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM },
        wakeState: @escaping () -> SystemWakeState = { PMSetWakeScheduleReader().current() },
        generateId: @escaping () -> String = { UUID().uuidString.lowercased() },
        serverVersion: String = "dev"
    ) {
        self.leaseClient = leaseClient
        self.wakeClient = wakeClient
        self.readStatus = readStatus
        self.isPidAlive = isPidAlive
        self.wakeState = wakeState
        self.generateId = generateId
        self.serverVersion = serverVersion
    }

    // MARK: - Dispatch

    /// One request line in, one response line out; nil for notifications and
    /// unparseable-but-ignorable input. Never throws, never blocks beyond the
    /// tool call itself.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return encode(error: (-32700, "parse error"), id: NSNull())
        }
        let id = object["id"]
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]

        // Notifications get no response, including when a client stamps one
        // with an explicit null id. A null id on a regular request is
        // accepted and echoed back as null in the response.
        guard let id, !method.hasPrefix("notifications/") else { return nil }

        switch method {
        case "initialize":
            return encode(result: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "keepresso", "version": serverVersion],
            ], id: id)
        case "ping":
            return encode(result: [String: Any](), id: id)
        case "tools/list":
            return encode(result: ["tools": Self.toolList], id: id)
        case "tools/call":
            guard let name = params["name"] as? String else {
                return encode(error: (-32602, "tools/call needs a tool name"), id: id)
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let outcome = call(tool: name, arguments: arguments) else {
                return encode(error: (-32602, "unknown tool '\(name)'"), id: id)
            }
            return encode(result: [
                "content": [["type": "text", "text": outcome.json]],
                "isError": outcome.exitCode != 0,
            ], id: id)
        default:
            return encode(error: (-32601, "method '\(method)' not found"), id: id)
        }
    }

    // MARK: - Tools

    private func call(tool: String, arguments: [String: Any]) -> LeaseOutcome? {
        func string(_ key: String) -> String? { arguments[key] as? String }
        func seconds(_ key: String) -> Int? {
            (arguments[key] as? Int) ?? (arguments[key] as? Double).map(Int.init)
        }
        func argumentError(_ message: String) -> LeaseOutcome {
            LeaseOutcome(exitCode: 64, json: "{\"error\": \"\(message)\"}", human: message)
        }

        switch tool {
        case "acquire_lease":
            let rawId = string("id") ?? generateId()
            guard let id = AutomationLease.canonicalId(rawId) else {
                return argumentError("id must be a UUID")
            }
            guard let toolName = string("tool"), !toolName.isEmpty else {
                return argumentError("acquire_lease needs a tool name")
            }
            guard let task = string("task"), !task.isEmpty else {
                return argumentError("acquire_lease needs a task label")
            }
            guard let ttl = seconds("ttl_seconds"), ttl > 0 else {
                return argumentError("acquire_lease needs a positive ttl_seconds")
            }
            return leaseClient.acquire(
                id: id, owner: string("owner"), tool: toolName, task: task,
                ttlSeconds: ttl, maxLifetimeSeconds: seconds("max_lifetime_seconds")
            )
        case "heartbeat_lease":
            guard let id = string("id").flatMap(AutomationLease.canonicalId) else {
                return argumentError("heartbeat_lease needs a UUID id")
            }
            return leaseClient.heartbeat(id: id, ttlSeconds: seconds("ttl_seconds"))
        case "release_lease":
            guard let id = string("id").flatMap(AutomationLease.canonicalId) else {
                return argumentError("release_lease needs a UUID id")
            }
            return leaseClient.release(id: id)
        case "list_leases":
            return leaseClient.list()
        case "get_status":
            return statusOutcome()
        case "get_wake_schedule":
            return wakeOutcome()
        case "set_wake_schedule":
            var oneShot: Date?
            if let raw = string("one_shot") {
                guard let parsed = ISO8601DateFormatter().date(from: raw) else {
                    return argumentError("one_shot must be an ISO 8601 date")
                }
                oneShot = parsed
            }
            let days = string("repeat_days")
            let time = string("repeat_time")
            guard oneShot != nil || (days != nil && time != nil) else {
                return argumentError("set_wake_schedule needs one_shot, or repeat_days with repeat_time")
            }
            return wakeClient.apply(oneShot: oneShot, repeatDays: days, repeatTime: time)
        case "clear_wake_schedule":
            return wakeClient.apply(oneShot: nil, repeatDays: nil, repeatTime: nil)
        default:
            return nil
        }
    }

    /// The same shape as `keepresso status --json`: the snapshot plus
    /// whether the writing app is still alive.
    private func statusOutcome() -> LeaseOutcome {
        struct Report: Codable {
            var appRunning: Bool
            var status: StatusSnapshot
        }
        guard let snapshot = readStatus() else {
            let message = "no status recorded yet. Launch the Keepresso app once."
            return LeaseOutcome(exitCode: 2, json: "{\"error\": \"\(message)\"}", human: message)
        }
        let report = Report(appRunning: isPidAlive(snapshot.pid), status: snapshot)
        return LeaseOutcome(exitCode: 0, json: encodeJSON(report), human: "")
    }

    private func wakeOutcome() -> LeaseOutcome {
        struct Report: Codable {
            var scheduledWakes: [Date]
            var repeatingSummary: String?
        }
        let state = wakeState()
        let report = Report(
            scheduledWakes: state.scheduledWakes,
            repeatingSummary: state.repeatingSummary
        )
        return LeaseOutcome(exitCode: 0, json: encodeJSON(report), human: "")
    }

    // MARK: - Tool schemas

    static let toolList: [[String: Any]] = [
        [
            "name": "acquire_lease",
            "description": "Acquire a bounded keep-awake lease so the Mac stays awake while a task runs. Returns the lease id; heartbeat it before half the TTL elapses and release it when the task ends. The Mac may sleep (and the user's end-of-session action may run) after the last lease ends.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Lease UUID; omit to have one generated. Reusing a live lease's id renews it."],
                    "owner": ["type": "string", "description": "Who asked, for display; defaults to the current user."],
                    "tool": ["type": "string", "description": "The tool holding the lease, e.g. an agent name."],
                    "task": ["type": "string", "description": "One-line task label shown in the Keepresso menu."],
                    "ttl_seconds": ["type": "integer", "description": "Seconds until the lease expires without a heartbeat (10 to 86400)."],
                    "max_lifetime_seconds": ["type": "integer", "description": "Hard ceiling heartbeats cannot extend; capped at 7 days."],
                ],
                "required": ["tool", "task", "ttl_seconds"],
            ],
        ],
        [
            "name": "heartbeat_lease",
            "description": "Extend a live lease's TTL. Fails when the lease expired or the user revoked it; acquire a new lease then, and do not assume the Mac stayed awake.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "ttl_seconds": ["type": "integer", "description": "Optional new TTL in seconds."],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "release_lease",
            "description": "Release a lease when its task finishes. Idempotent. The user's configured end action (sleep, lock) may run after the last lease releases.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
            ],
        ],
        [
            "name": "list_leases",
            "description": "List every lease record: live, expired, released, and revoked.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "get_status",
            "description": "Keepresso's session status: whether the Mac is being kept awake, trigger state, acknowledged lease ids, and whether the lease API is enabled.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "get_wake_schedule",
            "description": "The system's scheduled wakes (pmset -g sched): one-shot wake times and the repeating event, if any.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "set_wake_schedule",
            "description": "Schedule the Mac to wake: a one-shot instant, a repeating time, or both. Works only while the user has enabled \"Allow automation to change the wake schedule\" in Keepresso's preferences; a disabled or invalid request is reported as an error.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "one_shot": ["type": "string", "description": "ISO 8601 wake instant, at least 30 seconds out and less than a year away."],
                    "repeat_days": ["type": "string", "description": "Weekday letters MTWRFSU (subset) for a repeating wake."],
                    "repeat_time": ["type": "string", "description": "24-hour HH:MM local time for the repeating wake."],
                ],
            ],
        ],
        [
            "name": "clear_wake_schedule",
            "description": "Clear Keepresso's wake schedule. Honored only while the same preference is enabled.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
    ]

    // MARK: - Encoding

    private func encode(result: [String: Any], id: Any) -> String {
        encodeEnvelope(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error: (code: Int, message: String), id: Any) -> String {
        encodeEnvelope([
            "jsonrpc": "2.0", "id": id,
            "error": ["code": error.code, "message": error.message],
        ])
    }

    private func encodeEnvelope(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return #"{"jsonrpc": "2.0", "id": null, "error": {"code": -32603, "message": "internal error"}}"# }
        return String(decoding: data, as: UTF8.self)
    }

    private func encodeJSON<T: Encodable>(_ payload: T) -> String {
        AutomationJSON.encode(payload)
    }
}
