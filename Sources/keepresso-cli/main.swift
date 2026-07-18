import Foundation
import KeepressoCore

// The `keepresso` command-line tool. Ships inside the app bundle
// (Contents/Helpers/keepresso) and is symlinked onto PATH by the Homebrew cask.
// Deliberately AppKit-free so `swift build` works with Command Line Tools only.
//
// Exit codes: 0 success (for `status`: keeping awake), 1 failure (for
// `status`: not keeping awake), 2 app not running / no status, 64 usage.

let helpText = """
keepresso: keep the Mac awake from the command line.

App commands (delivered to the Keepresso app, launching it if needed):
  keepresso start [--for <minutes>] [--until <HH:MM>]
  keepresso stop
  keepresso toggle
  keepresso status [--json]     exit 0 awake, 1 not, 2 app not running

Standalone holds (this process holds the assertion, caffeinate-style):
  keepresso -i                  hold until Ctrl-C
  keepresso -t <seconds>        hold for a number of seconds
  keepresso -w <pid>            hold until a process exits
  keepresso -d                  also keep the display awake (combinable)
  keepresso -u                  declare user activity: wake the display now

Agent wake leases (stable JSON output):
  keepresso lease acquire --owner <owner> --agent <agent> --task <task>
      [--ttl <seconds>] [--max-lifetime <seconds>] [--message <text>]
  keepresso lease renew <id> [--ttl <seconds>] [--message <text>]
  keepresso lease heartbeat <id> [--ttl <seconds>] [--message <text>]
  keepresso lease release <id> [--result <result>] [--message <text>]
  keepresso lease list [--owner <owner>] [--agent <agent>] [--task <task>] [--all]
  keepresso lease status [id]

Other:
  keepresso help | version

Examples:
  keepresso start --for 90      brew a 90 minute session in the app
  keepresso -w $$ &              stay awake while this shell lives
  ffmpeg -i in.mov out.mp4 && keepresso stop
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("keepresso: \(message)\n".utf8))
    exit(code)
}

/// The app's marketing version. The binary lives in Contents/Helpers (and is
/// reached through a Homebrew symlink), where `Bundle.main` does not resolve
/// to the app bundle, so read Contents/Info.plist relative to the real
/// executable path instead.
func appVersion() -> String? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let plistURL = executable
        .deletingLastPathComponent()               // Helpers
        .deletingLastPathComponent()               // Contents
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let info = plist as? [String: Any]
    else { return nil }
    return info["CFBundleShortVersionString"] as? String
}

// MARK: - App commands over the URL scheme

func runRemote(_ command: CLIRequest.RemoteCommand) -> Never {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // -g: deliver in the background, a menu-bar app has nothing to bring forward.
    open.arguments = ["-g", command.urlString]
    do {
        try open.run()
    } catch {
        fail("could not run /usr/bin/open: \(error.localizedDescription)", code: 1)
    }
    open.waitUntilExit()
    guard open.terminationStatus == 0 else {
        fail("could not deliver the command. Is the Keepresso app installed?", code: 2)
    }
    exit(0)
}

// MARK: - Status

/// What `status --json` prints: the app's snapshot plus whether that app
/// process is still alive (a crash leaves a stale but well-formed file).
struct StatusReport: Codable {
    var appRunning: Bool
    var status: StatusSnapshot
}

func runStatus(json: Bool) -> Never {
    guard let snapshot = StatusFile.read() else {
        fail("no status recorded yet. Launch the Keepresso app once.", code: 2)
    }
    let appRunning = kill(snapshot.pid, 0) == 0 || errno == EPERM

    if json {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(StatusReport(appRunning: appRunning, status: snapshot))) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else if !appRunning {
        print("Keepresso is not running.")
    } else if snapshot.isActive {
        var line = "Keeping the Mac awake"
        if let endsAt = snapshot.endsAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            line += " until \(formatter.string(from: endsAt))"
        }
        line += "."
        if snapshot.triggersPaused { line += " Triggers are paused." }
        print(line)
    } else {
        var line = "Not keeping awake."
        if snapshot.triggersEnabled {
            line += snapshot.triggersPaused
                ? " Triggers are paused."
                : " Triggers are watching."
        }
        print(line)
    }

    if !appRunning { exit(2) }
    exit(snapshot.isActive ? 0 : 1)
}

// MARK: - Standalone holds

/// Keeps the dispatch sources alive for the lifetime of `dispatchMain()`.
var retainedSources: [DispatchSourceProtocol] = []

func runHold(_ hold: CLIRequest.Hold) -> Never {
    if hold.declareUserActivity {
        IOKitActivitySimulator().poke()
    }
    if hold.oneShot { exit(0) }

    let manager = IOKitPowerAssertionManager()
    var kinds: Set<PowerAssertionKind> = [.system]
    if hold.display { kinds.insert(.display) }
    manager.apply(kinds, reason: "keepresso CLI")
    guard manager.held == kinds else {
        fail("could not take the power assertion", code: 1)
    }

    // Assertions die with the process anyway (powerd cleans up), but release
    // deliberately on the signals a pipeline actually sends.
    let releaseAndExit: (Int32) -> Void = { code in
        manager.releaseAll()
        exit(code)
    }
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { releaseAndExit(0) }
        source.resume()
        retainedSources.append(source)
    }

    if let timeout = hold.timeoutSeconds {
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { releaseAndExit(0) }
    }

    if let pid = hold.waitForPID {
        if kill(pid, 0) != 0 && errno == ESRCH {
            fail("no process with pid \(pid)", code: 1)
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { releaseAndExit(0) }
        source.resume()
        retainedSources.append(source)
        // The process may have exited between the liveness check and the
        // source arming; a dead pid would then never fire. Re-check.
        if kill(pid, 0) != 0 && errno == ESRCH { releaseAndExit(0) }
    }

    dispatchMain()
}

// MARK: - Agent hooks

/// `keepresso agent-hook <event>`: reduce the JSON payload on stdin to a
/// per-session state file. Exits 0 no matter what and prints nothing: a
/// broken hook must never disturb or slow an agent session.
func runAgentHook(event: String) -> Never {
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    AgentHooks.handle(event: event, payloadData: payload, parentPid: getppid())
    exit(0)
}

// MARK: - Agent wake leases

func writeLeaseResponse(_ response: LeaseCommandResponse, exitCode: Int32? = nil) -> Never {
    guard let data = LeaseJSON.encode(response) else {
        fail("could not encode the lease response", code: 1)
    }
    FileHandle.standardOutput.write(data)
    exit(exitCode ?? (response.ok ? 0 : 1))
}

func runLease(_ command: LeaseCommand) -> Never {
    writeLeaseResponse(FileLeaseCommander().execute(command))
}

// MARK: - Entry

let cliArguments = Array(CommandLine.arguments.dropFirst())
let request: CLIRequest
do {
    request = try CLIRequest.parse(cliArguments)
} catch let error as CLIUsageError {
    if cliArguments.first == "lease" {
        let command = cliArguments.dropFirst().first ?? "lease"
        writeLeaseResponse(
            .failure(command: command, code: "usage_error", message: error.message),
            exitCode: 64
        )
    }
    fail(error.message, code: 64)
}

switch request {
case .help:
    print(helpText)
case .version:
    print("keepresso \(appVersion() ?? "(unpackaged development build)")")
case .status(let json):
    runStatus(json: json)
case .remote(let command):
    runRemote(command)
case .hold(let hold):
    runHold(hold)
case .lease(let command):
    runLease(command)
case .agentHook(let event):
    runAgentHook(event: event)
}
