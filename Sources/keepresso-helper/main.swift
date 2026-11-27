import Foundation
import KeepressoCore
import SystemConfiguration

final class HelperConnection: NSObject, HelperXPCProtocol {
    private let engine: HelperEngine
    private let clientID: Int
    private let onTerminateRequest: @Sendable () -> Void

    init(
        engine: HelperEngine,
        clientID: Int,
        onTerminateRequest: @escaping @Sendable () -> Void
    ) {
        self.engine = engine
        self.clientID = clientID
        self.onTerminateRequest = onTerminateRequest
    }

    func ping(reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperService.protocolVersion)
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setSleepDisabled(disabled))
    }

    func setSleepHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setSleepHold(client: clientID, holding: holding))
    }

    func setAWDLHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setAWDLHold(client: clientID, holding: holding))
    }

    func setFanHold(_ holding: Bool, percent: Int, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setFanHold(client: clientID, holding: holding, percent: percent))
    }

    func fanHoldDropped(reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.fanHoldWasDropped(client: clientID))
    }

    func setPriorityHold(_ holding: Bool, pid: Int, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setPriorityHold(client: clientID, holding: holding, pid: pid))
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

    func flushDNS(reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.flushDNS())
    }

    func setLowPowerHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setLowPowerHold(client: clientID, holding: holding))
    }

    func setAdapterLowPowerHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setAdapterLowPowerHold(client: clientID, holding: holding))
    }

    func setKeyboardLock(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(engine.setKeyboardLock(client: clientID, holding: holding))
    }

    func terminateWhenIdle() {
        onTerminateRequest()
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let engine: HelperEngine
    private let lock = NSLock()
    private var nextClientID = 1
    private var liveConnections = 0
    private var terminateRequested = false

    init(engine: HelperEngine) {
        self.engine = engine
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if let requirement = HelperService.anchoredPeerRequirement(
            identifier: HelperService.appCodeSignIdentifier
        ) {
            newConnection.setCodeSigningRequirement(requirement)
        } else {
            // Ad-hoc build: there is no Team ID to anchor a requirement to,
            // so an identifier-only requirement would let any local process
            // claim the app's identifier and drive root verbs. Pin the peer
            // to the exact app binary inside this daemon's own bundle,
            // kernel-enforced: unlike a pid-based path lookup this has no
            // pid-reuse race. Fail closed when the pin cannot be built.
            guard let selfPath = HelperPeerPolicy.executablePath(ofPID: getpid()),
                  let appPath = HelperPeerPolicy.bundledAppExecutablePath(for: selfPath),
                  let requirement = HelperPeerPolicy.pinnedPeerRequirement(
                      identifier: HelperService.appCodeSignIdentifier,
                      executablePath: appPath)
            else { return false }
            newConnection.setCodeSigningRequirement(requirement)
        }
        // The uid comes from the connection itself, not from a pid lookup,
        // so a recycled pid cannot smuggle a different user past this check.
        guard HelperPeerPolicy.shouldAccept(
            peerUID: newConnection.effectiveUserIdentifier, consoleUID: consoleUserID())
        else { return false }

        lock.lock()
        let clientID = nextClientID
        nextClientID += 1
        liveConnections += 1
        lock.unlock()

        newConnection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        newConnection.exportedObject = HelperConnection(
            engine: engine,
            clientID: clientID,
            onTerminateRequest: { [weak self] in self?.requestTerminate() }
        )
        newConnection.invalidationHandler = { [weak self, engine] in
            engine.clientDisconnected(clientID)
            self?.connectionEnded()
        }
        newConnection.resume()
        return true
    }

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

/// The GUI session's uid, or nil when nobody is sitting at the console.
///
/// At the login window (a logout, a lock, or a fast user switch away from the
/// desk) `SCDynamicStoreCopyConsoleUser` reports the name "loginwindow" with
/// uid 0. That is not a console user: reporting it as one would make every
/// peer fail the uid match and cut the still-running app off from the daemon
/// mid-session.
private func consoleUserID() -> uid_t? {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          !name.isEmpty, name != "loginwindow", uid != 0
    else { return nil }
    return uid
}

let engine = HelperEngine(
    runner: ProcessCommandRunner(),
    state: FileRestoreState(),
    fans: SMCFanController(),
    sleepDisabledReader: HelperEngine.readSleepDisabled,
    lowPower: PMSetBatteryLowPowerControl()
)
engine.restoreAtLaunch()

let bundleContents = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
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
