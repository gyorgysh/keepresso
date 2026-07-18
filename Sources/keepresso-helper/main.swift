import Foundation
import KeepressoCore

/// The Keepresso privileged helper daemon.
///
/// A tiny root LaunchDaemon registered from the app via `SMAppService`
/// (approved once by the user, with administrator credentials, in System
/// Settings). It exposes fixed reversible sleep, AWDL, and fan controls over
/// XPC, so the app never needs another password prompt for them. All behavior
/// lives in ``HelperEngine`` (KeepressoCore, unit-tested); this file is the
/// XPC and launchd wiring around it.
///
/// launchd launches it on demand (`MachServices`) and at boot (`RunAtLoad`,
/// so leftover state from a crash or power loss is restored); it exits again
/// once idle.

/// One XPC client connection. Logical stream ownership migrates across
/// reconnects, and only the current owner connection may release each hold.
final class HelperConnection: NSObject, HelperXPCProtocol {
    private let engine: HelperEngine
    private let clientID: Int
    private let sleepGenerations: SleepModeGenerationRegistry
    private let awdlGenerations: SleepModeGenerationRegistry
    private let fanGenerations: SleepModeGenerationRegistry
    private let wakeGenerations: SleepModeGenerationRegistry
    private let onTerminateRequest: @Sendable () -> Void
    private let legacySleepStreamID = UUID().uuidString.lowercased()
    private let legacySleepLock = NSLock()
    private var legacySleepGeneration: UInt64 = 0

    init(
        engine: HelperEngine,
        clientID: Int,
        sleepGenerations: SleepModeGenerationRegistry,
        awdlGenerations: SleepModeGenerationRegistry,
        fanGenerations: SleepModeGenerationRegistry,
        wakeGenerations: SleepModeGenerationRegistry,
        onTerminateRequest: @escaping @Sendable () -> Void
    ) {
        self.engine = engine
        self.clientID = clientID
        self.sleepGenerations = sleepGenerations
        self.awdlGenerations = awdlGenerations
        self.fanGenerations = fanGenerations
        self.wakeGenerations = wakeGenerations
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
            generation: generation,
            clientID: clientID
        ) { previousClientID in
            engine.setSleepHoldMode(
                client: clientID,
                replacing: previousClientID,
                mode: holding ? .active : .released
            )
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
            generation: generation,
            clientID: clientID
        ) { previousClientID in
            engine.setSleepHoldMode(
                client: clientID,
                replacing: previousClientID,
                mode: mode
            )
        })
    }

    func setAWDLHold(
        _ holding: Bool,
        streamID: String,
        generation: UInt64,
        reply: @escaping @Sendable (Bool) -> Void
    ) {
        reply(awdlGenerations.apply(
            streamID: streamID,
            generation: generation,
            clientID: clientID
        ) { previousClientID in
            engine.setAWDLHold(
                client: clientID,
                replacing: previousClientID,
                holding: holding
            )
        })
    }

    func setFanHold(
        _ holding: Bool,
        percent: Int,
        streamID: String,
        generation: UInt64,
        reply: @escaping @Sendable (Bool) -> Void
    ) {
        reply(fanGenerations.apply(
            streamID: streamID,
            generation: generation,
            clientID: clientID
        ) { previousClientID in
            engine.setFanHold(
                client: clientID,
                replacing: previousClientID,
                holding: holding,
                percent: percent
            )
        })
    }

    func fanHoldDropped(reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.fanHoldDropped(client: clientID))
    }

    func sleepNow(reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.sleepNow())
    }

    func applyWakeSchedule(
        oneShot: String,
        repeatDays: String,
        repeatTime: String,
        streamID: String,
        generation: UInt64,
        reply: @escaping @Sendable (Bool) -> Void
    ) {
        reply(wakeGenerations.apply(
            streamID: streamID,
            generation: generation,
            clientID: clientID
        ) { _ in
            // Keep the registry lock through the full clear-and-install
            // transaction. Whichever generation enters second therefore
            // determines the final system schedule.
            engine.applyWakeSchedule(
                oneShot: oneShot.isEmpty ? nil : oneShot,
                repeatDays: repeatDays.isEmpty ? nil : repeatDays,
                repeatTime: repeatTime.isEmpty ? nil : repeatTime
            )
        })
    }

    func terminateWhenIdle() {
        onTerminateRequest()
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let engine: HelperEngine
    private let sleepGenerations = SleepModeGenerationRegistry()
    private let awdlGenerations = SleepModeGenerationRegistry()
    private let fanGenerations = SleepModeGenerationRegistry()
    private let wakeGenerations = SleepModeGenerationRegistry()
    private let shutdownGate = HelperShutdownGate()

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

        guard let clientID = shutdownGate.acceptConnection() else {
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        newConnection.exportedObject = HelperConnection(
            engine: engine,
            clientID: clientID,
            sleepGenerations: sleepGenerations,
            awdlGenerations: awdlGenerations,
            fanGenerations: fanGenerations,
            wakeGenerations: wakeGenerations,
            onTerminateRequest: { [weak self] in self?.requestTerminate() }
        )
        // Invalidation is the connection's definitive end (interruption never
        // fires for a peer process exit on the daemon side of a mach service).
        newConnection.invalidationHandler = { [weak self, engine] in
            self?.sleepGenerations.clientDisconnected(clientID) {
                engine.sleepClientDisconnected(clientID)
            }
            self?.awdlGenerations.clientDisconnected(clientID) {
                engine.awdlClientDisconnected(clientID)
            }
            self?.fanGenerations.clientDisconnected(clientID) {
                engine.fanClientDisconnected(clientID)
            }
            // Wake schedules outlive a connection, so there is no engine
            // cleanup. Clearing only the live registry owner preserves the
            // generation tombstone and fences requests from this connection.
            self?.wakeGenerations.clientDisconnected(clientID) {}
            self?.connectionEnded()
        }
        newConnection.resume()
        return true
    }

    /// Atomically close connection acceptance once the engine is idle and the
    /// shutdown policy allows exit.
    func claimShutdownIfAllowed() -> Bool {
        shutdownGate.claimExitIfAllowed { engine.isIdle }
    }

    private func requestTerminate() {
        shutdownGate.requestTermination()
    }

    private func connectionEnded() {
        shutdownGate.connectionEnded()
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
// serving the new app. `HelperShutdownGate` closes connection acceptance and
// makes the final idle decision atomically (unit-tested).
let idleTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "idle-check"))
idleTimer.schedule(deadline: .now() + 60, repeating: 60)
idleTimer.setEventHandler {
    if delegate.claimShutdownIfAllowed() {
        exit(0)
    }
}
idleTimer.resume()

RunLoop.main.run()
