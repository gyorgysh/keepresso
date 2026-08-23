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
    public static let protocolVersion = 9

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
    /// Take or release this connection's forced-fan hold at `percent` of the
    /// fans' range (the thermal safety net's boost). Boost only, never below
    /// what auto control had; while any hold is live the daemon re-writes the
    /// target every few seconds, since the system re-takes fan control.
    func setFanHold(_ holding: Bool, percent: Int, reply: @escaping @Sendable (Bool) -> Void)
    /// Whether the daemon surrendered a forced-fan hold on its own (repeated
    /// firmware refusals), so the app can stop claiming a boost the hardware
    /// no longer has and release its side of the hold.
    func fanHoldDropped(reply: @escaping @Sendable (Bool) -> Void)
    /// Take or release this connection's CPU-priority hold on `pid` (the
    /// game priority boost: renice needs root for negative values). Released
    /// automatically when the connection dies; priority itself dies with the
    /// target process, so there is no cross-reboot restore debt.
    func setPriorityHold(_ holding: Bool, pid: Int, reply: @escaping @Sendable (Bool) -> Void)
    /// Put the Mac to sleep immediately (`pmset sleepnow`). Fire-and-forget
    /// from the caller's perspective: the machine may sleep before the reply
    /// lands, so a missing reply is not a failure.
    func sleepNow(reply: @escaping @Sendable (Bool) -> Void)
    /// Apply the full desired wake schedule in one step: cancel previous
    /// schedules, then install the one-shot (`pmset schedule wake`) and the
    /// repeating pair (`pmset repeat wakeorpoweron`) as requested. Empty
    /// strings mean "not wanted"; all empty clears everything. One composite
    /// verb so the clear-then-install ordering runs inside the daemon and a
    /// mid-sequence restart can't leave a cleared-but-not-reinstalled state.
    func applyWakeSchedule(oneShot: String, repeatDays: String, repeatTime: String, reply: @escaping @Sendable (Bool) -> Void)
    /// Flush the system DNS cache (`dscacheutil -flushcache` plus
    /// `killall -HUP mDNSResponder`). No arguments: a captive portal that
    /// poisoned resolution is the only caller, and a generic shell verb is
    /// out of bounds for this protocol.
    func flushDNS(reply: @escaping @Sendable (Bool) -> Void)
    /// Take or release this connection's hold on the Keyboard Cleaner remap
    /// (baked-in `UserKeyMapping`, never a caller-supplied script). The
    /// daemon snapshots the live mapping, applies the disable table, and
    /// restores the snapshot when the last holder drops or the connection
    /// dies. No JSON in, so a compromised caller cannot remap arbitrary keys
    /// beyond the lock itself.
    func setKeyboardLock(_ holding: Bool, reply: @escaping @Sendable (Bool) -> Void)
    /// Ask the daemon to exit at its first fully idle moment, without the
    /// ordinary exit's extra grace period (see ``HelperShutdownPolicy``), so
    /// launchd relaunches the binary currently in the bundle on the next call.
    func terminateWhenIdle()
}

/// App-side seam over the daemon, synchronous because every caller already
/// runs on a detached task (the controllers hop off the main actor for all
/// launcher work). Tests use a fake; ``XPCHelperClient`` is the real one.
public protocol PrivilegedHelperCalling: AnyObject, Sendable {
    /// Whether a matching daemon answered the version handshake.
    func ping() -> Bool
    /// The protocol version the daemon answered with, or `nil` when no daemon
    /// replied at all. An old version is not a failure: right after an app
    /// update the pre-update daemon image can keep serving until it idles
    /// out, and callers must treat that as "answering, needs retirement",
    /// never as "broken" (repairing a live registration is what risks a
    /// fresh approval prompt).
    func pingVersion() -> Int?
    func setSleepDisabled(_ disabled: Bool) -> Bool
    func setSleepHold(_ holding: Bool) -> Bool
    func setAWDLHold(_ holding: Bool) -> Bool
    func setFanHold(_ holding: Bool, percent: Int) -> Bool
    /// Whether the daemon surrendered the forced-fan hold on its own, `nil`
    /// when no daemon answered.
    func fanHoldDropped() -> Bool?
    /// Take or release the CPU-priority hold on `pid` (see
    /// ``HelperXPCProtocol/setPriorityHold(_:pid:reply:)``).
    func setPriorityHold(_ holding: Bool, pid: Int) -> Bool
    /// Ask the daemon to put the Mac to sleep (`pmset sleepnow`).
    func sleepNow() -> Bool
    /// Apply the full desired wake schedule (see
    /// ``HelperXPCProtocol/applyWakeSchedule(oneShot:repeatDays:repeatTime:reply:)``).
    /// `nil` parts are not wanted; all `nil` clears everything.
    func applyWakeSchedule(oneShot: String?, repeatDays: String?, repeatTime: String?) -> Bool
    /// Flush the system DNS cache (see ``HelperXPCProtocol/flushDNS(reply:)``).
    func flushDNS() -> Bool
    /// Take or release the Keyboard Cleaner remap hold (see
    /// ``HelperXPCProtocol/setKeyboardLock(_:reply:)``).
    func setKeyboardLock(_ holding: Bool) -> Bool
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
    /// What we currently want held, for re-assertion after an interruption.
    private var wantsSleepHold = false
    private var wantsAWDLHold = false
    /// The wanted fan boost percent, or nil for no fan hold.
    private var wantsFanHold: Int?
    /// The pid whose priority we want raised, or nil for no priority hold.
    private var wantsPriorityHold: Int?
    /// Keyboard Cleaner remap hold. Kept for the life of a wipe so a daemon
    /// restart re-applies the disable table, and an app death restores keys.
    private var wantsKeyboardLock = false

    /// How long a call may wait on the daemon before counting as failed.
    /// Generous enough for launchd to spawn it on first contact.
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
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
        if holding {
            lock.lock()
            wantsSleepHold = true
            lock.unlock()
            let ok = call { proxy, done in proxy.setSleepHold(true, reply: done) }
            if !ok {
                lock.lock()
                wantsSleepHold = false
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setSleepHold(false, reply: done) }
        // Clear the want only once release is confirmed. On failure keep it
        // so the connection stays open for a retry (and an interruption
        // re-assert keeps the hold until that release lands).
        if ok {
            lock.lock()
            wantsSleepHold = false
            lock.unlock()
        }
        return ok
    }

    public func setAWDLHold(_ holding: Bool) -> Bool {
        if holding {
            lock.lock()
            wantsAWDLHold = true
            lock.unlock()
            let ok = call { proxy, done in proxy.setAWDLHold(true, reply: done) }
            if !ok {
                lock.lock()
                wantsAWDLHold = false
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setAWDLHold(false, reply: done) }
        if ok {
            lock.lock()
            wantsAWDLHold = false
            lock.unlock()
        }
        return ok
    }

    public func setFanHold(_ holding: Bool, percent: Int) -> Bool {
        if holding {
            lock.lock()
            wantsFanHold = percent
            lock.unlock()
            let ok = call { proxy, done in proxy.setFanHold(true, percent: percent, reply: done) }
            if !ok {
                lock.lock()
                wantsFanHold = nil
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setFanHold(false, percent: percent, reply: done) }
        if ok {
            lock.lock()
            wantsFanHold = nil
            lock.unlock()
        }
        return ok
    }

    public func setPriorityHold(_ holding: Bool, pid: Int) -> Bool {
        if holding {
            lock.lock()
            wantsPriorityHold = pid
            lock.unlock()
            let ok = call { proxy, done in proxy.setPriorityHold(true, pid: pid, reply: done) }
            if !ok {
                lock.lock()
                wantsPriorityHold = nil
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setPriorityHold(false, pid: pid, reply: done) }
        if ok {
            lock.lock()
            wantsPriorityHold = nil
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
        // Once sleep starts the reply may never arrive. The regular call
        // timeout bounds the wait; a missing reply is treated as failure and
        // the composite sleeper falls through to IOKit / System Events.
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

    public func setKeyboardLock(_ holding: Bool) -> Bool {
        if holding {
            lock.lock()
            wantsKeyboardLock = true
            lock.unlock()
            let ok = call { proxy, done in proxy.setKeyboardLock(true, reply: done) }
            if !ok {
                lock.lock()
                wantsKeyboardLock = false
                lock.unlock()
            }
            return ok
        }
        let ok = call { proxy, done in proxy.setKeyboardLock(false, reply: done) }
        if ok {
            lock.lock()
            wantsKeyboardLock = false
            lock.unlock()
        }
        return ok
    }

    /// Fire the version-handshake-and-retire nudge: if the daemon on the other
    /// end predates this app's protocol, or the app itself just updated (the
    /// daemon can't tell; its in-memory image predates the swap either way),
    /// ask it to exit once nothing is held. Called in the background at app
    /// launch; best-effort.
    public func retireStaleDaemon(appUpdated: Bool = false) {
        guard let proxy = proxyForAsyncUse() else { return }
        proxy.ping { [weak self] version in
            if version != HelperService.protocolVersion || appUpdated {
                proxy.terminateWhenIdle()
            }
            // The retire message is one-way: give it a beat to land, then
            // release the connection so the daemon is free to exit.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                self?.releaseConnectionUnlessHeld()
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
            releaseConnectionUnlessHeld()
            return false
        }
        releaseConnectionUnlessHeld()
        return outcome.value
    }

    /// Drop the connection when no hold is wanted. With nothing held there is
    /// no claim to keep alive, and holding on would pin the daemon: it can't
    /// idle-exit (or retire after an update) while a client is connected, and
    /// launchd only picks up a newly installed binary on a fresh connection.
    private func releaseConnectionUnlessHeld() {
        lock.lock()
        let held = wantsSleepHold || wantsAWDLHold || wantsFanHold != nil
            || wantsPriorityHold != nil || wantsKeyboardLock
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
        let fan = wantsFanHold
        let priority = wantsPriorityHold
        let keyboard = wantsKeyboardLock
        lock.unlock()
        guard sleep || awdl || fan != nil || priority != nil || keyboard,
              let proxy = proxyForAsyncUse() else { return }
        if sleep { proxy.setSleepHold(true) { _ in } }
        if awdl { proxy.setAWDLHold(true) { _ in } }
        if let fan { proxy.setFanHold(true, percent: fan) { _ in } }
        if let priority { proxy.setPriorityHold(true, pid: priority) { _ in } }
        if keyboard { proxy.setKeyboardLock(true) { _ in } }
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
