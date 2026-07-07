import Foundation
import Security

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
    public static let protocolVersion = 1

    /// The code-signing requirement one side demands of the other: an
    /// Apple-issued certificate, the expected identifier, and the same team as
    /// this process. The Team ID is read from our own signature at runtime,
    /// never hardcoded (see `WidgetBridge.appGroupID` for the same rule). The
    /// team clause is dropped only when we have no team ourselves (an ad-hoc
    /// local dev build), where the anchor clause wouldn't hold either.
    public static func peerRequirement(identifier: String) -> String {
        guard let team = selfTeamIdentifier() else {
            return "identifier \"\(identifier)\""
        }
        return "anchor apple generic and identifier \"\(identifier)\""
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The Team ID from this process's own code signature, or `nil` when
    /// unsigned or ad-hoc signed (local dev builds).
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
    /// Liveness and version handshake; replies with ``HelperService/protocolVersion``.
    func ping(reply: @escaping @Sendable (Int) -> Void)
    /// Set the persistent `pmset disablesleep` flag (the manual toggle).
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void)
    /// Take or release this connection's hold on `disablesleep` (the
    /// "only while brewing" automation).
    func setSleepHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void)
    /// Take or release this connection's hold on `awdl0 down` (the AWDL
    /// watchdog). While any hold is live the daemon re-downs the interface
    /// every few seconds, since macOS re-raises it on its own.
    func setAWDLHold(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void)
    /// Ask the daemon to exit once it has no clients and no holds, so launchd
    /// relaunches the (possibly newer) binary on the next call.
    func terminateWhenIdle()
}

/// App-side seam over the daemon, synchronous because every caller already
/// runs on a detached task (the controllers hop off the main actor for all
/// launcher work). Tests use a fake; ``XPCHelperClient`` is the real one.
public protocol PrivilegedHelperCalling: AnyObject, Sendable {
    /// Whether a matching daemon answered the version handshake.
    func ping() -> Bool
    func setSleepDisabled(_ disabled: Bool) -> Bool
    func setSleepHold(_ holding: Bool) -> Bool
    func setAWDLHold(_ holding: Bool) -> Bool
}

/// Real client over `NSXPCConnection`. Keeps one long-lived connection on
/// purpose: the daemon scopes holds to the connection, so this object's
/// connection *is* the app's claim on them. If the daemon is killed or updated
/// mid-hold the interruption handler re-asserts the desired holds on the
/// relaunched daemon, so a hold survives a daemon restart but never an app
/// death.
public final class XPCHelperClient: PrivilegedHelperCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// What we currently want held, for re-assertion after an interruption.
    private var wantsSleepHold = false
    private var wantsAWDLHold = false

    /// How long a call may wait on the daemon before counting as failed.
    /// Generous enough for launchd to spawn it on first contact.
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    public func ping() -> Bool {
        let version = LockedBox(-1)
        let replied = call { proxy, done in
            proxy.ping { replyVersion in
                version.value = replyVersion
                done(true)
            }
        }
        return replied && version.value == HelperService.protocolVersion
    }

    public func setSleepDisabled(_ disabled: Bool) -> Bool {
        call { proxy, done in proxy.setSleepDisabled(disabled, reply: done) }
    }

    public func setSleepHold(_ holding: Bool) -> Bool {
        lock.lock()
        wantsSleepHold = holding
        lock.unlock()
        return call { proxy, done in proxy.setSleepHold(holding, reply: done) }
    }

    public func setAWDLHold(_ holding: Bool) -> Bool {
        lock.lock()
        wantsAWDLHold = holding
        lock.unlock()
        return call { proxy, done in proxy.setAWDLHold(holding, reply: done) }
    }

    /// Fire the version-handshake-and-retire nudge: if the daemon on the other
    /// end predates this app's protocol, ask it to exit once idle. Called in
    /// the background at app launch; best-effort.
    public func retireStaleDaemon() {
        guard let proxy = proxyForAsyncUse() else { return }
        proxy.ping { version in
            if version != HelperService.protocolVersion {
                proxy.terminateWhenIdle()
            }
        }
    }

    // MARK: - Connection plumbing

    /// Run one remote call synchronously with a timeout. `done(false)` is also
    /// invoked by the connection's error handler, so a missing daemon (not
    /// installed, denied, or crashed) fails cleanly instead of hanging.
    private func call(_ body: (HelperXPCProtocol, @escaping @Sendable (Bool) -> Void) -> Void) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = LockedOutcome()
        let done: @Sendable (Bool) -> Void = { ok in
            if outcome.settle(ok) { semaphore.signal() }
        }
        guard let proxy = proxy(errorHandler: { done(false) }) else { return false }
        body(proxy, done)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            _ = outcome.settle(false)
            return false
        }
        return outcome.value
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
        defer { lock.unlock() }
        if let connection { return connection }
        let fresh = NSXPCConnection(
            machServiceName: HelperService.machServiceLabel,
            options: .privileged
        )
        fresh.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        // Only talk to our own daemon: same team, the helper's identifier.
        fresh.setCodeSigningRequirement(
            HelperService.peerRequirement(identifier: HelperService.helperCodeSignIdentifier)
        )
        fresh.interruptionHandler = { [weak self] in self?.reassertHolds() }
        fresh.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connection = nil
            self.lock.unlock()
        }
        fresh.resume()
        connection = fresh
        return fresh
    }

    /// The daemon went away (killed, updated, crashed) and dropped our
    /// connection-scoped holds with it. Re-take whatever we still want, on the
    /// relaunched daemon, without blocking whoever's runloop we're on.
    private func reassertHolds() {
        lock.lock()
        let sleep = wantsSleepHold
        let awdl = wantsAWDLHold
        lock.unlock()
        guard sleep || awdl, let proxy = proxyForAsyncUse() else { return }
        if sleep { proxy.setSleepHold(true) { _ in } }
        if awdl { proxy.setAWDLHold(true) { _ in } }
    }
}

/// A lock-guarded value a reply block can write from its XPC queue.
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

/// A once-settable boolean shared between a reply block and its waiter, so a
/// late reply after a timeout can't signal a semaphore nobody holds anymore.
private final class LockedOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private(set) var value = false

    /// Record the first outcome; returns whether this call was the first.
    func settle(_ ok: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return false }
        settled = true
        value = ok
        return true
    }
}
