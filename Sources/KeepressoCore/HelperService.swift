import Foundation
import Security
import Darwin

/// The contract between the app and the privileged helper daemon
/// (`keepresso-helper`), a `SMAppService` LaunchDaemon bundled inside the app
/// at `Contents/MacOS/keepresso-helper` and registered from Preferences.
///
/// Why it exists: the two privileged features (closed-display mode's
/// `pmset disablesleep` and the AWDL watchdog's `ifconfig awdl0 down`) used to
/// run through `osascript`'s "with administrator privileges", which asks for
/// the password on every app run, sometimes with no visible cue that a dialog
/// is waiting. The daemon moves that to a single approval: macOS asks for
/// administrator credentials once when the user enables it in System Settings
/// (Login Items, "Allow in the Background"), and every toggle after that, in
/// this run or any future one, is a silent XPC call. The old osascript path
/// stays as the fallback while the helper isn't installed.
public enum HelperService {
    /// launchd label, mach service name, and the plist's base name; all three
    /// must agree with `sh.gyorgy.keepresso.helper.plist` in the app bundle.
    public static let machServiceLabel = "sh.gyorgy.keepresso.helper"
    public static let plistName = "sh.gyorgy.keepresso.helper.plist"

    /// Code-signing identifiers the two sides verify on each other.
    public static let appCodeSignIdentifier = "sh.gyorgy.keepresso"
    public static let helperCodeSignIdentifier = "sh.gyorgy.keepresso.helper"

    /// Bumped whenever the XPC surface changes. The app compares the daemon's
    /// `ping` reply with this and asks a stale daemon to exit once idle
    /// (launchd relaunches the new binary from the bundle on the next call).
    /// 2: added `removeTrashedBundle` (the Trash sweep's TCC fallback).
    /// 3: removed it again. Tested live: even root can't delete from the
    /// TCC-protected Trash, so the app now tells the user instead of asking
    /// the daemon to try.
    /// 4: added `setFanHold` (the thermal safety net's fan boost) and
    /// `fanHoldDropped` (the app's view of a surrendered boost).
    /// 5: added `sleepNow` (`pmset sleepnow` for the session-end action).
    /// 6: added the wake-schedule verb (`applyWakeSchedule`, one composite
    ///    `pmset schedule` / `pmset repeat` step). Shipped in v1.16.1.
    /// 7: added the game priority boost's connection-scoped
    ///    `setPriorityHold`.
    /// 8: added `flushDNS` (the Public Wi-Fi assistant).
    /// 9: added `setKeyboardLock` (Keyboard Cleaner: root hidutil remap).
    /// 10: connection-scoped battery Low Power Mode.
    /// 11: dropped fan holds are reported per connection, so independent
    ///     floor and heat controllers cannot clear each other's status.
    /// 12: adapter Low Power Mode and fan floor requests down to ten percent.
    public static let protocolVersion = 12
    public static let adapterLowPowerMinProtocol = 12
    public static let lowPowerMinProtocol = 10
    /// First protocol that shipped `flushDNS`. Older daemons lack the verb.
    public static let flushDNSMinProtocol = 8

    /// The code-signing requirement one side demands of the other: an
    /// Apple-issued certificate, the expected identifier, and the same team as
    /// this process. Nil when this process has no Team ID (an ad-hoc local dev
    /// build), where no cryptographic anchor exists at all.
    public static func anchoredPeerRequirement(identifier: String) -> String? {
        guard let team = selfTeamIdentifier() else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\""
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Best available requirement when a caller must have a string: the
    /// anchored one on signed builds, identifier-only on ad-hoc dev builds.
    /// Security-relevant callers should prefer ``anchoredPeerRequirement
    /// (identifier:)`` and, on ad-hoc builds, ``HelperPeerPolicy
    /// /pinnedPeerRequirement(identifier:executablePath:)`` instead: the
    /// identifier-only form accepts any local claimant.
    public static func peerRequirement(identifier: String) -> String {
        anchoredPeerRequirement(identifier: identifier) ?? "identifier \"\(identifier)\""
    }

    static func adHocDaemonRequirement() -> String? {
        guard let selfPath = HelperPeerPolicy.executablePath(ofPID: getpid()),
              let helperPath = HelperPeerPolicy.bundledHelperExecutablePath(for: selfPath)
        else { return nil }
        return HelperPeerPolicy.pinnedPeerRequirement(
            identifier: HelperService.helperCodeSignIdentifier, executablePath: helperPath)
    }

    /// The Team ID from this process's own code signature, or `nil` when
    /// unsigned or ad-hoc signed (local dev builds). Security.framework may
    /// synchronously evaluate timestamp certificate trust while reading this
    /// information. Call off the main thread, including for metadata checks.
    public static func selfTeamIdentifier() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef
        else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoRef
        ) == errSecSuccess,
            let info = infoRef as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Who may talk to the privileged daemon. The daemon is a system
/// LaunchDaemon: its verbs affect the whole Mac, so only the console (GUI)
/// user's Keepresso may connect. Testable without XPC.
public enum HelperPeerPolicy {
    /// `peerUID` is the connecting process's real uid. `consoleUID` is the
    /// current GUI session's uid, or nil when no console user is logged in
    /// (SSH-only). Root (uid 0) is never the app, so it is always refused.
    public static func shouldAccept(peerUID: uid_t, consoleUID: uid_t?) -> Bool {
        guard peerUID != 0 else { return false }
        if let consoleUID { return peerUID == consoleUID }
        return true
    }

    /// Real uid of `pid`, via `sysctl`. Nil when the process is gone.
    public static func uid(ofPID pid: pid_t) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let err = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, u_int(buf.count), &info, &size, nil, 0)
        }
        guard err == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    /// Real path of `pid`'s executable, via `proc_pidpath`. Nil when the
    /// process is gone or the path is unreadable.
    public static func executablePath(ofPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// A peer requirement pinning `identifier` to the exact code currently on
    /// disk at `executablePath`: that file's designated requirement (for an
    /// ad-hoc build, `cdhash H"..."`), narrowed to the expected identifier.
    /// This is the ad-hoc fallback where there is no Team ID to anchor to.
    /// Enforced by the kernel through `setCodeSigningRequirement`, so unlike
    /// a pid-based executable-path lookup it has no pid-reuse race: the
    /// check runs against the peer's actual code, not a path re-resolved
    /// from a recyclable pid. Nil when the file's requirement is unreadable,
    /// in which case the caller must refuse the peer (fail closed).
    public static func pinnedPeerRequirement(identifier: String, executablePath: String) -> String? {
        guard let designated = designatedRequirementText(executablePath: executablePath) else {
            return nil
        }
        return "identifier \"\(identifier)\" and (\(designated))"
    }

    /// Designated-requirement text of the executable at `path`, or nil when
    /// the file is unsigned or unreadable.
    public static func designatedRequirementText(executablePath: String) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: executablePath) as CFURL,
            [],
            &staticCode
        ) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            staticCode,
            [],
            &requirement
        ) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(
            requirement,
            [],
            &text
        ) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// Where the helper executable lives when `appExecutablePath` is the app
    /// inside its bundle (`.../Keepresso.app/Contents/MacOS/Keepresso`). The
    /// app-side counterpart of ``bundledAppExecutablePath(for:)``: lets an
    /// ad-hoc app pin its daemon to the helper in its own bundle. Nil outside
    /// an app bundle (e.g. a raw Xcode build), where no pinning is possible.
    public static func bundledHelperExecutablePath(for appExecutablePath: String) -> String? {
        let macos = URL(fileURLWithPath: appExecutablePath)
            .resolvingSymlinksInPath().standardizedFileURL
            .deletingLastPathComponent()
        guard macos.lastPathComponent == "MacOS",
              macos.deletingLastPathComponent().lastPathComponent == "Contents",
              macos.deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app"
        else { return nil }
        return macos.appendingPathComponent("keepresso-helper").standardizedFileURL.path
    }

    /// Where the app executable lives when `helperExecutablePath` is the
    /// bundled helper (`.../Keepresso.app/Contents/MacOS/keepresso-helper`).
    /// This is the fallback identity check for ad-hoc builds, where there is
    /// no Team ID to anchor a real code requirement: the only acceptable peer
    /// is the app inside the very bundle this daemon lives in. Nil when the
    /// path is not a nested app-bundle helper.
    public static func bundledAppExecutablePath(for helperExecutablePath: String) -> String? {
        let helper = URL(fileURLWithPath: helperExecutablePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let macos = helper.deletingLastPathComponent()
        guard macos.lastPathComponent == "MacOS",
              macos.deletingLastPathComponent().lastPathComponent == "Contents"
        else { return nil }
        let app = macos.deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app" else { return nil }
        return app.appendingPathComponent("Contents/MacOS/Keepresso")
            .standardizedFileURL.path
    }
}

/// The daemon's XPC surface. Deliberately tiny and fixed-verb: two reversible
/// power/radio switches and nothing generic (no "run this command"), so a
/// compromised caller can't do more than the features themselves.
///
/// Holds versus sets: a *hold* is scoped to the XPC connection that took it;
/// the daemon releases it (restoring the system default) when that connection
/// dies, so an app crash fails safe exactly like the old pid-watching loops.
/// The plain `setSleepDisabled` is the manual closed-display toggle, which is
/// meant to outlive the app, so it is not connection-scoped.
@objc public protocol HelperXPCProtocol {
    func ping(reply: @escaping @Sendable (Int) -> Void)
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void)
    func setSleepHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void)
    func setAWDLHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void)
    func setFanHold(_ holding: Bool, percent: Int, reply: @escaping @Sendable (Bool) -> Void)
    func fanHoldDropped(reply: @escaping @Sendable (Bool) -> Void)
    func setPriorityHold(_ holding: Bool, pid: Int, reply: @escaping @Sendable (Bool) -> Void)
    func sleepNow(reply: @escaping @Sendable (Bool) -> Void)
    func applyWakeSchedule(oneShot: String, repeatDays: String, repeatTime: String, reply: @escaping @Sendable (Bool) -> Void)
    func flushDNS(reply: @escaping @Sendable (Bool) -> Void)
    func setKeyboardLock(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void)
    func setLowPowerHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void)
    func setAdapterLowPowerHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void)
    func terminateWhenIdle()
}

/// App-side seam over the daemon, synchronous because every caller already
/// runs on a detached task (the controllers hop off the main actor for all
/// launcher work). Tests use a fake; ``XPCHelperClient`` is the real one.
public protocol PrivilegedHelperCalling: AnyObject, Sendable {
    func ping() -> Bool
    func pingVersion() -> Int?
    func setSleepDisabled(_ disabled: Bool) -> Bool
    func setSleepHold(_ holding: Bool) -> Bool
    func setAWDLHold(_ holding: Bool) -> Bool
    func setFanHold(_ holding: Bool, percent: Int) -> Bool
    func fanHoldDropped() -> Bool?
    func setPriorityHold(_ holding: Bool, pid: Int) -> Bool
    func sleepNow() -> Bool
    func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool
    func flushDNS() -> Bool
    func setKeyboardLock(_ holding: Bool) -> Bool
    func setLowPowerHold(_ holding: Bool) -> Bool
    func setAdapterLowPowerHold(_ holding: Bool) -> Bool
}

public extension PrivilegedHelperCalling {
    func setLowPowerHold(_ holding: Bool) -> Bool { false }
    func setAdapterLowPowerHold(_ holding: Bool) -> Bool { false }
}

/// Real client over `NSXPCConnection`. The connection *is* the app's claim on
/// its holds: the daemon scopes holds to the connection, so it stays open
/// exactly as long as a hold is wanted, and is released after any call made
/// with nothing held. Letting go matters for updates: launchd only spawns the
/// binary currently in the app bundle on the *next* connection, so a client
/// that never disconnects would keep the pre-update daemon image serving
/// forever. If the daemon is killed, retired, or updated mid-hold the
/// interruption handler re-asserts the desired holds on the relaunched (new)
/// daemon, so a hold survives a daemon restart but never an app death.
public final class XPCHelperClient: PrivilegedHelperCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var callsInFlight = 0
    private var wantsSleepHold = false
    private var wantsAWDLHold = false
    private var wantsFanHold: Int?
    private var wantsPriorityHold: Int?
    private var wantsKeyboardLock = false
    private var wantsLowPowerHold = false
    private var wantsAdapterLowPowerHold = false
    private enum HoldKind: Hashable { case sleep, awdl, fan, priority, keyboard, lowPower, adapterLowPower }
    private var holdGeneration: [HoldKind: Int] = [:]

    private func bumpGeneration(_ kind: HoldKind) {
        holdGeneration[kind, default: 0] += 1
    }

    private let timeout: TimeInterval
    private let connectionFactory: @Sendable () -> NSXPCConnection
    private let verifiesDaemonSignature: Bool

    convenience init(timeout: TimeInterval, connectionFactory: @escaping @Sendable () -> NSXPCConnection) {
        self.init(timeout: timeout, connectionFactory: connectionFactory, verifiesDaemonSignature: false)
    }

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
        self.connectionFactory = {
            NSXPCConnection(machServiceName: HelperService.machServiceLabel, options: .privileged)
        }
        self.verifiesDaemonSignature = true
    }

    private init(
        timeout: TimeInterval,
        connectionFactory: @escaping @Sendable () -> NSXPCConnection,
        verifiesDaemonSignature: Bool
    ) {
        self.timeout = timeout
        self.connectionFactory = connectionFactory
        self.verifiesDaemonSignature = verifiesDaemonSignature
    }

    public func ping() -> Bool {
        pingVersion() == HelperService.protocolVersion
    }

    public func pingVersion() -> Int? {
        let version = LockedBox(-1)
        let replied = call { proxy, done in
            proxy.ping { replyVersion in
                version.value = replyVersion
                done(true)
            }
        }
        return replied ? version.value : nil
    }

    public func setSleepDisabled(_ disabled: Bool) -> Bool {
        call { proxy, done in proxy.setSleepDisabled(disabled, reply: done) }
    }

    public func setSleepHold(_ holding: Bool) -> Bool {
        defer { releaseConnectionUnlessHeld() }
        if holding {
            lock.lock()
            wantsSleepHold = true
            lock.unlock()
            let ok = call { proxy, done in proxy.setSleepHold(true, reply: done) }
            if !ok {
                lock.lock()
                wantsSleepHold = false
                bumpGeneration(.sleep)
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setSleepHold(false, reply: done) }
        if ok {
            lock.lock()
            wantsSleepHold = false
            bumpGeneration(.sleep)
            lock.unlock()
        }
        return ok
    }

    public func setAWDLHold(_ holding: Bool) -> Bool {
        defer { releaseConnectionUnlessHeld() }
        if holding {
            lock.lock()
            wantsAWDLHold = true
            lock.unlock()
            let ok = call { proxy, done in proxy.setAWDLHold(true, reply: done) }
            if !ok {
                lock.lock()
                wantsAWDLHold = false
                bumpGeneration(.awdl)
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setAWDLHold(false, reply: done) }
        if ok {
            lock.lock()
            wantsAWDLHold = false
            bumpGeneration(.awdl)
            lock.unlock()
        }
        return ok
    }

    public func setFanHold(_ holding: Bool, percent: Int) -> Bool {
        defer { releaseConnectionUnlessHeld() }
        if holding {
            lock.lock()
            wantsFanHold = percent
            lock.unlock()
            let ok = call { proxy, done in proxy.setFanHold(true, percent: percent, reply: done) }
            if !ok {
                lock.lock()
                wantsFanHold = nil
                bumpGeneration(.fan)
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setFanHold(false, percent: percent, reply: done) }
        if ok {
            lock.lock()
            wantsFanHold = nil
            bumpGeneration(.fan)
            lock.unlock()
        }
        return ok
    }

    public func setPriorityHold(_ holding: Bool, pid: Int) -> Bool {
        defer { releaseConnectionUnlessHeld() }
        if holding {
            lock.lock()
            wantsPriorityHold = pid
            lock.unlock()
            let ok = call { proxy, done in proxy.setPriorityHold(true, pid: pid, reply: done) }
            if !ok {
                lock.lock()
                wantsPriorityHold = nil
                bumpGeneration(.priority)
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setPriorityHold(false, pid: pid, reply: done) }
        if ok {
            lock.lock()
            wantsPriorityHold = nil
            bumpGeneration(.priority)
            lock.unlock()
        }
        return ok
    }

    public func fanHoldDropped() -> Bool? {
        let dropped = LockedBox(false)
        let replied = call { proxy, done in
            proxy.fanHoldDropped { value in
                dropped.value = value
                done(true)
            }
        }
        return replied ? dropped.value : nil
    }

    public func sleepNow() -> Bool {
        call { proxy, done in proxy.sleepNow(reply: done) }
    }

    public func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool {
        call { proxy, done in
            proxy.applyWakeSchedule(
                oneShot: oneShot ?? "",
                repeatDays: repeatDays ?? "",
                repeatTime: repeatTime ?? "",
                reply: done
            )
        }
    }

    public func flushDNS() -> Bool {
        call { proxy, done in proxy.flushDNS(reply: done) }
    }

    public func setLowPowerHold(_ holding: Bool) -> Bool {
        setProfileHold(
            holding, kind: .lowPower, minProtocol: HelperService.lowPowerMinProtocol,
            want: \.wantsLowPowerHold
        ) { proxy, holding, done in proxy.setLowPowerHold(holding, reply: done) }
    }

    public func setAdapterLowPowerHold(_ holding: Bool) -> Bool {
        setProfileHold(
            holding, kind: .adapterLowPower, minProtocol: HelperService.adapterLowPowerMinProtocol,
            want: \.wantsAdapterLowPowerHold
        ) { proxy, holding, done in proxy.setAdapterLowPowerHold(holding, reply: done) }
    }

    private func setProfileHold(
        _ holding: Bool,
        kind: HoldKind,
        minProtocol: Int,
        want: ReferenceWritableKeyPath<XPCHelperClient, Bool>,
        send: (HelperXPCProtocol, Bool, @escaping @Sendable (Bool) -> Void) -> Void
    ) -> Bool {
        guard let version = pingVersion() else { return false }
        defer { releaseConnectionUnlessHeld() }
        func dropWant() {
            lock.lock()
            self[keyPath: want] = false
            bumpGeneration(kind)
            lock.unlock()
        }
        guard version >= minProtocol else {
            if !holding { dropWant() }
            return false
        }
        if holding {
            lock.lock()
            self[keyPath: want] = true
            lock.unlock()
            let ok = call { proxy, done in send(proxy, true, done) }
            if !ok { dropWant() }
            return ok
        }
        let ok = call { proxy, done in send(proxy, false, done) }
        if ok { dropWant() }
        return ok
    }

    public func setKeyboardLock(_ holding: Bool) -> Bool {
        defer { releaseConnectionUnlessHeld() }
        if holding {
            lock.lock()
            wantsKeyboardLock = true
            lock.unlock()
            let ok = call { proxy, done in proxy.setKeyboardLock(true, reply: done) }
            if !ok {
                lock.lock()
                wantsKeyboardLock = false
                bumpGeneration(.keyboard)
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setKeyboardLock(false, reply: done) }
        if ok {
            lock.lock()
            wantsKeyboardLock = false
            bumpGeneration(.keyboard)
            lock.unlock()
        }
        return ok
    }

    /// Fire the version-handshake-and-retire nudge: if the daemon on the other
    /// end predates this app's protocol, or the app itself just updated (the
    /// daemon can't tell; its in-memory image predates the swap either way),
    /// ask it to exit once nothing is held.
    ///
    /// Synchronous: blocks up to ``timeout`` plus a 2s delivery grace when a
    /// retire is sent (longer when no daemon answers). Every caller already
    /// runs on a detached task; never call this on the main thread.
    /// Best-effort.
    public func retireStaleDaemon(appUpdated: Bool = false) {
        _ = call { proxy, done in
            proxy.ping { version in
                guard version != HelperService.protocolVersion || appUpdated else {
                    done(true)
                    return
                }
                proxy.terminateWhenIdle()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { done(true) }
            }
        }
    }


    private func call(_ body: (HelperXPCProtocol, @escaping @Sendable (Bool) -> Void) -> Void) -> Bool {
        lock.lock()
        callsInFlight += 1
        lock.unlock()
        defer {
            lock.lock()
            callsInFlight -= 1
            lock.unlock()
            releaseConnectionUnlessHeld()
        }
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = LockedOutcome()
        let done: @Sendable (Bool) -> Void = { ok in
            if outcome.settle(ok) { semaphore.signal() }
        }
        guard let proxy = proxy(errorHandler: { done(false) }) else { return false }
        body(proxy, done)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            _ = outcome.settle(false)
            NSLog("Keepresso: helper XPC call timed out after %.0f seconds", timeout)
            return false
        }
        return outcome.value
    }

    private func releaseConnectionUnlessHeld() {
        lock.lock()
        let held = callsInFlight > 0 || wantsSleepHold || wantsAWDLHold || wantsFanHold != nil
            || wantsPriorityHold != nil || wantsKeyboardLock || wantsLowPowerHold || wantsAdapterLowPowerHold
        let stale = held ? nil : connection
        if !held { connection = nil }
        lock.unlock()
        stale?.invalidate()
    }

    private func proxy(errorHandler: @escaping @Sendable () -> Void) -> HelperXPCProtocol? {
        currentConnection()?
            .remoteObjectProxyWithErrorHandler { _ in errorHandler() } as? HelperXPCProtocol
    }

    private func proxyForAsyncUse() -> HelperXPCProtocol? {
        currentConnection()?
            .remoteObjectProxyWithErrorHandler { _ in } as? HelperXPCProtocol
    }

    private func currentConnection() -> NSXPCConnection? {
        lock.lock()
        if let connection { lock.unlock(); return connection }
        lock.unlock()
        let factory = connectionFactory
        let verifies = verifiesDaemonSignature
        let fresh = factory()
        fresh.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        if verifies {
            if let anchored = HelperService.anchoredPeerRequirement(
                identifier: HelperService.helperCodeSignIdentifier
            ) {
                fresh.setCodeSigningRequirement(anchored)
            } else if let pinned = HelperService.adHocDaemonRequirement() {
                fresh.setCodeSigningRequirement(pinned)
            } else {
                fresh.invalidate()
                lock.lock()
                defer { lock.unlock() }
                if let connection { return connection }
                return nil
            }
        }
        fresh.interruptionHandler = { [weak self, weak fresh] in
            guard let fresh else { return }
            self?.reassertHolds(from: fresh)
        }
        fresh.invalidationHandler = { [weak self, weak fresh] in
            guard let self, let fresh else { return }
            self.lock.lock()
            if self.connection === fresh { self.connection = nil }
            self.lock.unlock()
        }
        fresh.resume()
        lock.lock()
        defer { lock.unlock() }
        if let connection { fresh.invalidate(); return connection }
        connection = fresh
        return fresh
    }

    private func reassertHolds(from interrupted: NSXPCConnection) {
        lock.lock()
        guard connection === interrupted else { lock.unlock(); return }
        var generations: [HoldKind: Int] = [:]
        for kind in [HoldKind.sleep, .awdl, .fan, .priority, .keyboard, .lowPower, .adapterLowPower] {
            bumpGeneration(kind)
            generations[kind] = holdGeneration[kind]
        }
        let gen = generations
        let sleep = wantsSleepHold
        let awdl = wantsAWDLHold
        let fan = wantsFanHold
        let priority = wantsPriorityHold
        let keyboard = wantsKeyboardLock
        let lowPower = wantsLowPowerHold
        let adapterLowPower = wantsAdapterLowPowerHold
        let stale = connection
        connection = nil
        lock.unlock()
        stale?.invalidate()
        guard sleep || awdl || fan != nil || priority != nil || keyboard || lowPower || adapterLowPower,
              let proxy = proxyForAsyncUse() else { return }
        if sleep, holdStillWanted(kind: .sleep, generation: gen, { wantsSleepHold }) {
            proxy.setSleepHold(true) { [weak self] _ in
                guard let self,
                      !self.holdStillWanted(kind: .sleep, generation: gen, { self.wantsSleepHold })
                else { return }
                proxy.setSleepHold(false) { _ in }
            }
        }
        if awdl, holdStillWanted(kind: .awdl, generation: gen, { wantsAWDLHold }) {
            proxy.setAWDLHold(true) { [weak self] _ in
                guard let self,
                      !self.holdStillWanted(kind: .awdl, generation: gen, { self.wantsAWDLHold })
                else { return }
                proxy.setAWDLHold(false) { _ in }
            }
        }
        if let fan, holdStillWanted(kind: .fan, generation: gen, { wantsFanHold != nil }) {
            proxy.setFanHold(true, percent: fan) { [weak self] _ in
                guard let self,
                      !self.holdStillWanted(
                          kind: .fan, generation: gen, { self.wantsFanHold != nil })
                else { return }
                proxy.setFanHold(false, percent: fan) { _ in }
            }
        }
        if let priority,
           holdStillWanted(kind: .priority, generation: gen, { wantsPriorityHold != nil }) {
            proxy.setPriorityHold(true, pid: priority) { [weak self] _ in
                guard let self,
                      !self.holdStillWanted(
                          kind: .priority, generation: gen, { self.wantsPriorityHold != nil })
                else { return }
                proxy.setPriorityHold(false, pid: priority) { _ in }
            }
        }
        if keyboard, holdStillWanted(kind: .keyboard, generation: gen, { wantsKeyboardLock }) {
            proxy.setKeyboardLock(true) { [weak self] _ in
                guard let self,
                      !self.holdStillWanted(
                          kind: .keyboard, generation: gen, { self.wantsKeyboardLock })
                else { return }
                proxy.setKeyboardLock(false) { _ in }
            }
        }
        if lowPower, holdStillWanted(kind: .lowPower, generation: gen, { wantsLowPowerHold }) {
            proxy.setLowPowerHold(true) { [weak self] _ in
                guard let self,
                      !self.holdStillWanted(
                          kind: .lowPower, generation: gen, { self.wantsLowPowerHold })
                else { return }
                proxy.setLowPowerHold(false) { _ in }
            }
        }
        if adapterLowPower, holdStillWanted(kind: .adapterLowPower, generation: gen, { wantsAdapterLowPowerHold }) {
            proxy.setAdapterLowPowerHold(true) { [weak self] _ in
                guard let self,
                      !self.holdStillWanted(
                          kind: .adapterLowPower, generation: gen, { self.wantsAdapterLowPowerHold })
                else { return }
                proxy.setAdapterLowPowerHold(false) { _ in }
            }
        }
    }

    private func holdStillWanted(
        kind: HoldKind, generation: [HoldKind: Int], _ check: () -> Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return holdGeneration[kind] == generation[kind] && check()
    }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ initial: Value) {
        stored = initial
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private final class LockedOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private(set) var value = false

    func settle(_ ok: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return false }
        settled = true
        value = ok
        return true
    }
}
