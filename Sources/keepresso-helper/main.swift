import Foundation
import KeepressoCore

/// The Keepresso privileged helper daemon.
///
/// A tiny root LaunchDaemon registered from the app via `SMAppService`
/// (approved once by the user, with administrator credentials, in System
/// Settings). It exposes exactly two reversible switches over XPC, sleep
/// (`pmset disablesleep`) and AWDL (`ifconfig awdl0 down`), so the app never
/// needs another password prompt for them. All behavior lives in
/// ``HelperEngine`` (KeepressoCore, unit-tested); this file is the XPC and
/// launchd wiring around it.
///
/// launchd launches it on demand (`MachServices`) and at boot (`RunAtLoad`,
/// so leftover state from a crash or power loss is restored); it exits again
/// once idle.

/// One XPC client connection. Holds are attributed to `clientID`, and the
/// connection's death releases them (see ``HelperEngine/clientDisconnected(_:)``).
final class HelperConnection: NSObject, HelperXPCProtocol {
    private let engine: HelperEngine
    private let clientID: Int
    private let sleepGenerations: SleepModeGenerationRegistry
    private let onTerminateRequest: @Sendable () -> Void
    private let legacySleepStreamID = UUID().uuidString.lowercased()
    private let legacySleepLock = NSLock()
    private var legacySleepGeneration: UInt64 = 0

    init(
        engine: HelperEngine,
        clientID: Int,
        sleepGenerations: SleepModeGenerationRegistry,
        onTerminateRequest: @escaping @Sendable () -> Void
    ) {
        self.engine = engine
        self.clientID = clientID
        self.sleepGenerations = sleepGenerations
        self.onTerminateRequest = onTerminateRequest
    }

    func ping(reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperService.protocolVersion)
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setSleepDisabled(disabled))
    }

    func setSleepHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        legacySleepLock.lock()
        legacySleepGeneration &+= 1
        let generation = legacySleepGeneration
        legacySleepLock.unlock()
        reply(sleepGenerations.apply(
            streamID: legacySleepStreamID,
            generation: generation
        ) {
            engine.setSleepHold(client: clientID, holding: holding)
        })
    }

    func setSleepHoldMode(
        _ rawMode: Int,
        streamID: String,
        generation: UInt64,
        reply: @escaping @Sendable (Bool) -> Void
    ) {
        guard let mode = SleepHoldMode(rawValue: rawMode) else {
            reply(false)
            return
        }
        reply(sleepGenerations.apply(
            streamID: streamID,
            generation: generation
        ) {
            engine.setSleepHoldMode(client: clientID, mode: mode)
        })
    }

    func setAWDLHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setAWDLHold(client: clientID, holding: holding))
    }

    func setFanHold(_ holding: Bool, percent: Int, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setFanHold(client: clientID, holding: holding, percent: percent))
    }

    func fanHoldDropped(reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.fanHoldDropped)
    }

    func sleepNow(reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.sleepNow())
    }

    func applyWakeSchedule(oneShot: String, repeatDays: String, repeatTime: String, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.applyWakeSchedule(
            oneShot: oneShot.isEmpty ? nil : oneShot,
            repeatDays: repeatDays.isEmpty ? nil : repeatDays,
            repeatTime: repeatTime.isEmpty ? nil : repeatTime
        ))
    }

    func terminateWhenIdle() {
        onTerminateRequest()
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let engine: HelperEngine
    private let sleepGenerations = SleepModeGenerationRegistry()
    private let lock = NSLock()
    private var nextClientID = 1
    private var liveConnections = 0
    private var terminateRequested = false

    init(engine: HelperEngine) {
        self.engine = engine
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only the Keepresso app may connect: Apple-issued signature, the
        // app's identifier, and the same Team ID as this helper (read from our
        // own signature at runtime, never hardcoded).
        newConnection.setCodeSigningRequirement(
            HelperService.peerRequirement(identifier: HelperService.appCodeSignIdentifier)
        )

        lock.lock()
        let clientID = nextClientID
        nextClientID += 1
        liveConnections += 1
        lock.unlock()

        newConnection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        newConnection.exportedObject = HelperConnection(
            engine: engine,
            clientID: clientID,
            sleepGenerations: sleepGenerations,
            onTerminateRequest: { [weak self] in self?.requestTerminate() }
        )
        // Invalidation is the connection's definitive end (interruption never
        // fires for a peer process exit on the daemon side of a mach service).
        newConnection.invalidationHandler = { [weak self, engine] in
            engine.clientDisconnected(clientID)
            self?.connectionEnded()
        }
        newConnection.resume()
        return true
    }

    /// Whether the daemon may exit right now: no clients, no holds.
    var isIdle: Bool {
        lock.lock()
        let clients = liveConnections
        lock.unlock()
        return clients == 0 && engine.isIdle
    }

    var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveConnections
    }

    var wantsTermination: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminateRequested
    }

    private func requestTerminate() {
        lock.lock()
        terminateRequested = true
        lock.unlock()
    }

    private func connectionEnded() {
        lock.lock()
        liveConnections -= 1
        lock.unlock()
    }
}

let engine = HelperEngine(
    runner: ProcessCommandRunner(),
    state: FileRestoreState(),
    fans: SMCFanController()
)
// Settle anything a previous life left behind (crash or reboot mid-hold)
// before accepting new work.
engine.restoreAtLaunch()

// Keep the bundled CLI on PATH for DMG installs (Homebrew does this itself
// via the cask's `binary` stanza). Our own executable path leads to the app
// bundle: .../Keepresso.app/Contents/MacOS/keepresso-helper.
let bundleContents = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()  // Contents/MacOS
    .deletingLastPathComponent()  // Contents
engine.ensureCLILink(
    cliPath: bundleContents.appendingPathComponent("Helpers/keepresso").path
)

let delegate = ListenerDelegate(engine: engine)
let listener = NSXPCListener(machServiceName: HelperService.machServiceLabel)
listener.delegate = delegate
listener.resume()

// While any AWDL or fan hold is live, keep re-asserting it (macOS re-raises
// the interface and re-takes fan control on its own); a no-op otherwise.
let holdTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "hold-tick"))
holdTimer.schedule(deadline: .now() + 3, repeating: 3)
holdTimer.setEventHandler {
    engine.sleepTick()
    engine.awdlTick()
    engine.fanTick()
}
holdTimer.resume()

// Exit when there's nothing to do (launchd relaunches us on the next XPC
// call), and promptly, skipping the idle grace, when the app asked us to
// retire after an update: this process is still the pre-update binary image
// no matter what was installed on disk, so lingering would keep old code
// serving the new app. The decision lives in `HelperShutdownPolicy`
// (unit-tested).
let idleTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "idle-check"))
nonisolated(unsafe) var idleChecks = 0
idleTimer.schedule(deadline: .now() + 60, repeating: 60)
idleTimer.setEventHandler {
    if delegate.isIdle { idleChecks += 1 } else { idleChecks = 0 }
    if HelperShutdownPolicy.shouldExit(
        clientCount: delegate.clientCount,
        holdsIdle: engine.isIdle,
        terminateRequested: delegate.wantsTermination,
        consecutiveIdleChecks: idleChecks
    ) {
        exit(0)
    }
}
idleTimer.resume()

RunLoop.main.run()
