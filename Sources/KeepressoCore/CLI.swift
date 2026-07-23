import Foundation

/// The parsed intent of a `keepresso` command-line invocation.
///
/// The CLI binary ships inside the app bundle (`Contents/Helpers/keepresso`,
/// symlinked onto PATH by the Homebrew cask) and covers what the
/// `keepresso://` URL scheme cannot: blocking holds in a pipeline, waiting on
/// a process, and scriptable status. Parsing and URL building live here in
/// Core so they are unit-tested; the executable target is thin glue around
/// the system calls.
public enum CLIRequest: Equatable, Sendable {
    case help
    case version
    /// Print the app-written status snapshot; `json` selects machine output.
    case status(json: Bool)
    /// Forward a command to the app through its `keepresso://` scheme.
    case remote(RemoteCommand)
    /// Hold this process's own power assertion, caffeinate-style.
    case hold(Hold)
    /// Record an agent-hook event delivered on stdin (Claude Code hooks).
    /// Hidden from the help text: installed hook commands are its only
    /// intended caller.
    case agentHook(event: String)
    /// Manage automation leases (bounded keep-awake grants for scripts and
    /// agents), executed by ``LeaseClient``.
    case lease(LeaseCommand)

    /// One `keepresso lease` operation, fully validated by the parser.
    public enum LeaseCommand: Equatable, Sendable {
        case acquire(
            id: String,
            owner: String?,
            tool: String,
            task: String,
            ttlSeconds: Int,
            maxLifetimeSeconds: Int?,
            json: Bool
        )
        case heartbeat(id: String, ttlSeconds: Int?, json: Bool)
        case release(id: String, json: Bool)
        case list(json: Bool)
    }

    /// A command delivered to the app (launching it if needed) via
    /// `open <url>`. Mirrors what ``URLCommand/parse(_:)`` accepts on the
    /// receiving side; ``urlString`` is round-trip-tested against it.
    public enum RemoteCommand: Equatable, Sendable {
        case start(durationMinutes: Double?, untilTime: String?)
        case stop
        case toggle
        /// The lease doorbell: rescan automation inputs, launching the app
        /// if needed. Parameterless by design.
        case syncLeases

        /// The `keepresso://` URL that carries this command.
        public var urlString: String {
            switch self {
            case .start(nil, nil):
                return "keepresso://start"
            case .start(let minutes?, _):
                return "keepresso://start?duration=\(Self.trimmed(minutes))"
            case .start(nil, let time?):
                return "keepresso://start?until=\(time)"
            case .stop:
                return "keepresso://stop"
            case .toggle:
                return "keepresso://toggle"
            case .syncLeases:
                return "keepresso://sync-leases"
            }
        }

        /// "90.0" reads worse than "90" in a URL; drop a whole-number's tail.
        private static func trimmed(_ minutes: Double) -> String {
            minutes == minutes.rounded() && minutes.magnitude < 1e15
                ? String(Int(minutes))
                : String(minutes)
        }
    }

    /// A caffeinate-style hold: the CLI process takes its own IOKit assertion
    /// and blocks until a bound is reached (or forever, until a signal).
    public struct Hold: Equatable, Sendable {
        /// Keep the display awake too (`-d`), not just the system.
        public var display = false
        /// Declare user activity once at start (`-u`): wakes the display and
        /// resets the idle timer, like `caffeinate -u`.
        public var declareUserActivity = false
        /// Release after this many seconds (`-t`).
        public var timeoutSeconds: Double?
        /// Release when this process exits (`-w`). Combined with `-t`,
        /// whichever bound is reached first wins.
        public var waitForPID: Int32?
        /// True when `-u` appeared with no hold flags at all: declare the
        /// activity once and exit instead of blocking.
        public var oneShot = false

        public init(
            display: Bool = false,
            declareUserActivity: Bool = false,
            timeoutSeconds: Double? = nil,
            waitForPID: Int32? = nil,
            oneShot: Bool = false
        ) {
            self.display = display
            self.declareUserActivity = declareUserActivity
            self.timeoutSeconds = timeoutSeconds
            self.waitForPID = waitForPID
            self.oneShot = oneShot
        }
    }

    /// Parses the arguments (without the executable name). Throws
    /// ``CLIUsageError`` with a user-facing message on bad input.
    public static func parse(_ arguments: [String]) throws -> CLIRequest {
        guard let first = arguments.first else { return .help }
        switch first {
        case "help", "--help", "-h":
            return .help
        case "version", "--version":
            return .version
        case "status":
            let rest = arguments.dropFirst()
            guard rest.isEmpty || rest == ["--json"] else {
                throw CLIUsageError("'status' takes only --json")
            }
            return .status(json: rest.first == "--json")
        case "start":
            return .remote(try parseStart(Array(arguments.dropFirst())))
        case "stop", "toggle":
            guard arguments.count == 1 else {
                throw CLIUsageError("'\(first)' takes no options")
            }
            return .remote(first == "stop" ? .stop : .toggle)
        case "agent-hook":
            guard arguments.count == 2 else {
                throw CLIUsageError("agent-hook takes exactly one event name")
            }
            return .agentHook(event: arguments[1])
        case "lease":
            return .lease(try parseLease(Array(arguments.dropFirst())))
        default:
            guard first.hasPrefix("-") else {
                throw CLIUsageError("unknown command '\(first)' (run 'keepresso help')")
            }
            return .hold(try parseHold(arguments))
        }
    }

    // MARK: - start options

    private static func parseStart(_ options: [String]) throws -> RemoteCommand {
        var minutes: Double?
        var until: String?
        var index = 0
        while index < options.count {
            let option = options[index]
            switch option {
            case "--for", "--duration":
                guard index + 1 < options.count else {
                    throw CLIUsageError("\(option) needs a value in minutes")
                }
                guard let value = Double(options[index + 1]), value > 0 else {
                    throw CLIUsageError("'\(options[index + 1])' is not a positive number of minutes")
                }
                minutes = value
                index += 2
            case "--until":
                guard index + 1 < options.count else {
                    throw CLIUsageError("--until needs a 24-hour time like 18:30")
                }
                let raw = options[index + 1]
                guard Self.isValidClockTime(raw) else {
                    throw CLIUsageError("'\(raw)' is not a 24-hour time like 18:30")
                }
                until = raw
                index += 2
            default:
                throw CLIUsageError("unknown start option '\(option)'")
            }
        }
        guard minutes == nil || until == nil else {
            throw CLIUsageError("use either --for or --until, not both")
        }
        return .start(durationMinutes: minutes, untilTime: until)
    }

    // MARK: - lease options

    private static func parseLease(_ arguments: [String]) throws -> LeaseCommand {
        guard let verb = arguments.first else {
            throw CLIUsageError("lease needs a verb: acquire, heartbeat, release, or list")
        }
        var flags = try leaseFlags(Array(arguments.dropFirst()))
        let json = flags.removeValue(forKey: "--json") != nil

        func take(_ name: String) -> String? { flags.removeValue(forKey: name) }
        func requireId() throws -> String {
            guard let raw = take("--id") else {
                throw CLIUsageError("lease \(verb) needs --id <uuid>")
            }
            guard let id = AutomationLease.canonicalId(raw) else {
                throw CLIUsageError("'\(raw)' is not a UUID (try: uuidgen)")
            }
            return id
        }
        func seconds(_ name: String) throws -> Int? {
            guard let raw = take(name) else { return nil }
            guard let value = Int(raw), value > 0 else {
                throw CLIUsageError("'\(raw)' is not a positive number of seconds")
            }
            return value
        }

        let command: LeaseCommand
        switch verb {
        case "acquire":
            let id = try requireId()
            guard let tool = take("--tool"), !tool.isEmpty else {
                throw CLIUsageError("lease acquire needs --tool <name>")
            }
            guard let task = take("--task"), !task.isEmpty else {
                throw CLIUsageError("lease acquire needs --task <label>")
            }
            guard let ttl = try seconds("--ttl") else {
                throw CLIUsageError("lease acquire needs --ttl <seconds>")
            }
            command = .acquire(
                id: id,
                owner: take("--owner"),
                tool: tool,
                task: task,
                ttlSeconds: ttl,
                maxLifetimeSeconds: try seconds("--max-lifetime"),
                json: json
            )
        case "heartbeat":
            command = .heartbeat(id: try requireId(), ttlSeconds: try seconds("--ttl"), json: json)
        case "release":
            command = .release(id: try requireId(), json: json)
        case "list":
            command = .list(json: json)
        default:
            throw CLIUsageError("unknown lease verb '\(verb)' (acquire, heartbeat, release, list)")
        }
        guard flags.isEmpty else {
            throw CLIUsageError("unknown lease option '\(flags.keys.sorted().first!)'")
        }
        return command
    }

    /// Collects `--flag value` pairs (and the value-less `--json`), rejecting
    /// anything that is not a recognised flag shape.
    private static func leaseFlags(_ arguments: [String]) throws -> [String: String] {
        var flags: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--") else {
                throw CLIUsageError("unexpected argument '\(name)'")
            }
            if name == "--json" {
                flags[name] = ""
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw CLIUsageError("\(name) needs a value")
            }
            guard flags[name] == nil else {
                throw CLIUsageError("\(name) given twice")
            }
            flags[name] = arguments[index + 1]
            index += 2
        }
        return flags
    }

    /// HH:MM, 24-hour, the same shape ``URLCommand`` accepts in `until=`.
    static func isValidClockTime(_ raw: String) -> Bool {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour),
              parts[1].count == 2,
              let minute = Int(parts[1]), (0...59).contains(minute)
        else { return false }
        return true
    }

    // MARK: - hold flags

    private static func parseHold(_ arguments: [String]) throws -> Hold {
        var hold = Hold()
        var sawBoundless = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-t", "--timeout":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("-t needs a value in seconds")
                }
                guard let seconds = Double(arguments[index + 1]), seconds > 0 else {
                    throw CLIUsageError("'\(arguments[index + 1])' is not a positive number of seconds")
                }
                hold.timeoutSeconds = seconds
                index += 2
            case "-w", "--waitfor":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("-w needs a process id")
                }
                guard let pid = Int32(arguments[index + 1]), pid > 0 else {
                    throw CLIUsageError("'\(arguments[index + 1])' is not a process id")
                }
                hold.waitForPID = pid
                index += 2
            default:
                // A cluster of value-less flags, caffeinate-style: -diu.
                guard argument.hasPrefix("-"), argument.count > 1 else {
                    throw CLIUsageError("unknown option '\(argument)'")
                }
                for flag in argument.dropFirst() {
                    switch flag {
                    case "d": hold.display = true
                    case "i": sawBoundless = true
                    case "u": hold.declareUserActivity = true
                    case "t", "w":
                        throw CLIUsageError("-\(flag) takes a value, give it separately: -\(flag) <value>")
                    default:
                        throw CLIUsageError("unknown flag '-\(flag)' (run 'keepresso help')")
                    }
                }
                index += 1
            }
        }
        // `-u` alone is a one-shot wake; anything else without a bound holds
        // until a signal, like bare `caffeinate`.
        hold.oneShot = hold.declareUserActivity
            && hold.timeoutSeconds == nil && hold.waitForPID == nil
            && !sawBoundless && !hold.display
        return hold
    }
}

/// A bad command line; `message` is printed to stderr as-is.
public struct CLIUsageError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
