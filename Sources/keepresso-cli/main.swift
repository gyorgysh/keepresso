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

Automation leases (bounded keep-awake grants for scripts and agents; the
app unions all live leases and lets the Mac sleep after the last one ends):
  keepresso lease acquire --id <uuid> --tool <name> --task <label>
                          --ttl <seconds> [--owner <name>]
                          [--max-lifetime <seconds>] [--json]
  keepresso lease heartbeat --id <uuid> [--ttl <seconds>] [--json]
  keepresso lease release --id <uuid> [--json]
  keepresso lease list [--json]

  Heartbeat before half the TTL elapses; the max lifetime (7 day cap) is a
  ceiling heartbeats cannot extend. Exit codes: 0 ok, 1 local failure,
  2 app not running or no acknowledgment, 3 lease not found or ended,
  4 leases disabled in Preferences, 64 usage.

Wake schedule (reading is always allowed; changing it works only while
"Allow automation to change the wake schedule" is on in Preferences):
  keepresso wake status [--json]
  keepresso wake set --at "2026-07-24 07:30" [--json]
  keepresso wake set --repeat MTWRF --time 07:30 [--json]
  keepresso wake clear [--json]

Other:
  keepresso help | version

Examples:
  keepresso start --for 90      brew a 90 minute session in the app
  keepresso -w $$ &              stay awake while this shell lives
  ffmpeg -i in.mov out.mp4 && keepresso stop
  ID=$(uuidgen); keepresso lease acquire --id "$ID" --tool render \\
    --task "overnight export" --ttl 600
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

// MARK: - Automation leases

/// `keepresso lease <verb> ...`: run the shared client and render its
/// outcome. The parent pid is recorded on acquired leases for `lease list`.
func runLease(_ command: CLIRequest.LeaseCommand) -> Never {
    let outcome = LeaseClient.real(ownerPid: getppid()).run(command)
    let json: Bool = {
        switch command {
        case .acquire(_, _, _, _, _, _, let json),
             .heartbeat(_, _, let json),
             .release(_, let json),
             .list(let json):
            return json
        }
    }()
    if json {
        print(outcome.json)
    } else if outcome.exitCode == 0 {
        print(outcome.human)
    } else {
        FileHandle.standardError.write(Data("keepresso: \(outcome.human)\n".utf8))
    }
    exit(outcome.exitCode)
}

// MARK: - Wake schedule

func runWake(_ command: CLIRequest.WakeCommand) -> Never {
    let client = WakeClient.real()
    let outcome: LeaseOutcome
    let json: Bool
    switch command {
    case .status(let wantsJSON):
        outcome = client.status()
        json = wantsJSON
    case .set(let oneShot, let repeatDays, let repeatTime, let wantsJSON):
        outcome = client.apply(oneShot: oneShot, repeatDays: repeatDays, repeatTime: repeatTime)
        json = wantsJSON
    case .clear(let wantsJSON):
        outcome = client.apply(oneShot: nil, repeatDays: nil, repeatTime: nil)
        json = wantsJSON
    }
    if json {
        print(outcome.json)
    } else if outcome.exitCode == 0 {
        print(outcome.human)
    } else {
        FileHandle.standardError.write(Data("keepresso: \(outcome.human)\n".utf8))
    }
    exit(outcome.exitCode)
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

/// The Codex variant. Codex fails open, so a silent no-op is safe here and
/// nothing needs printing.
func runCodexHook(event: String) -> Never {
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    CodexHooks.handle(event: event, payloadData: payload, parentPid: getppid())
    exit(0)
}

/// The Cursor variant. The installed hook command already printed `{}` before
/// invoking us and sends our output to /dev/null, so this writes nothing: the
/// response must be on stdout even when this binary is missing entirely.
func runCursorHook(event: String) -> Never {
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    CursorHooks.handle(event: event, payloadData: payload, parentPid: getppid())
    exit(0)
}

func runAntigravityHook(event: String) -> Never {
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    AntigravityHooks.handle(event: event, payloadData: payload, parentPid: getppid())
    exit(0)
}

// MARK: - Entry

let request: CLIRequest
do {
    request = try CLIRequest.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIUsageError {
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
case .agentHook(let event):
    runAgentHook(event: event)
case .cursorHook(let event):
    runCursorHook(event: event)
case .antigravityHook(let event):
    runAntigravityHook(event: event)
case .codexHook(let event):
    runCodexHook(event: event)
case .lease(let command):
    runLease(command)
case .wake(let command):
    runWake(command)
}
