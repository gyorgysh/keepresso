import Foundation

/// Daemon-backed and routing implementations of the existing privileged seams
/// (``SleepSettingControlling``, ``SleepWatchdogLaunching``,
/// ``AWDLWatchdogLaunching``), so ``ClosedDisplayController``,
/// ``ClosedDisplayAutoController`` and ``AWDLWatchdogController`` gain the
/// password-free path without changing a line: when the helper daemon is
/// installed the "spawn a root loop" step degrades to a prompt-free ping and
/// the flag file becomes an XPC hold; when it isn't, everything routes to the
/// original osascript backends.

// MARK: - Daemon-backed seams

/// ``SleepWatchdogLaunching`` over the helper daemon. The "flag" is the
/// client's connection-scoped sleep hold; `startHelper` is a version-checked
/// ping (the daemon is already installed and root, nothing to spawn and no
/// prompt to answer).
public final class HelperDaemonSleepWatchdog: SleepWatchdogLaunching, @unchecked Sendable {
    private let helper: PrivilegedHelperCalling
    private let lock = NSLock()
    private var mode: SleepHoldMode = .released

    public init(helper: PrivilegedHelperCalling) {
        self.helper = helper
    }

    public func isFlagPresent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mode != .released
    }

    public func createFlag() -> Bool {
        setMode(.active)
    }

    public func removeFlag() {
        _ = setMode(.released)
    }

    public func setMode(_ mode: SleepHoldMode) -> Bool {
        let ok = helper.setSleepHoldMode(mode)
        lock.lock()
        if ok { self.mode = mode }
        lock.unlock()
        return ok
    }

    public func startHelper(appPID: Int32) -> SleepSettingResult {
        helper.ping() ? .applied : .failed(L("The Keepresso helper isn't responding."))
    }

    public var engageFailureMessage: String {
        L("The Keepresso helper isn't responding.")
    }
}

/// ``AWDLWatchdogLaunching`` over the helper daemon; same shape as
/// ``HelperDaemonSleepWatchdog`` with the AWDL hold and result type.
public final class HelperDaemonAWDLWatchdog: AWDLWatchdogLaunching, @unchecked Sendable {
    private let helper: PrivilegedHelperCalling
    private let lock = NSLock()
    private var holding = false

    public init(helper: PrivilegedHelperCalling) {
        self.helper = helper
    }

    public func isFlagPresent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return holding
    }

    public func createFlag() -> Bool {
        let ok = helper.setAWDLHold(true)
        lock.lock()
        holding = ok
        lock.unlock()
        return ok
    }

    public func removeFlag() {
        _ = helper.setAWDLHold(false)
        lock.lock()
        holding = false
        lock.unlock()
    }

    public func startHelper(appPID: Int32) -> AWDLWatchdogStartResult {
        helper.ping() ? .started : .failed(L("The Keepresso helper isn't responding."))
    }

    public var engageFailureMessage: String {
        L("The Keepresso helper isn't responding.")
    }
}

// MARK: - Routing

/// Routes new scoped sleep transactions only to the daemon backend, whose
/// restore journal survives a reboot. The osascript fallback is release-only
/// here so upgrades can clean stale control files. A live transaction pins its
/// backend because only that backend owns the original sleep-setting snapshot.
public final class RoutedSleepWatchdog: SleepWatchdogLaunching, @unchecked Sendable {
    private enum Backend {
        case daemon
        case fallback
    }

    private let daemon: HelperDaemonSleepWatchdog
    private let fallback: SleepWatchdogLaunching
    private let helperInstalled: @Sendable () -> Bool
    private let lock = NSLock()
    /// The backend that owns the current snapshot. It cannot change until a
    /// released acknowledgement closes that transaction.
    private var pinnedBackend: Backend?

    public init(
        daemon: HelperDaemonSleepWatchdog,
        fallback: SleepWatchdogLaunching,
        helperInstalled: @escaping @Sendable () -> Bool
    ) {
        self.daemon = daemon
        self.fallback = fallback
        self.helperInstalled = helperInstalled
    }

    public func isFlagPresent() -> Bool {
        daemon.isFlagPresent() || fallback.isFlagPresent()
    }

    public func createFlag() -> Bool {
        setMode(.active)
    }

    public func removeFlag() {
        _ = setMode(.released)
    }

    public func setMode(_ mode: SleepHoldMode) -> Bool {
        lock.lock()
        let pinned = pinnedBackend
        let selected: Backend
        if let pinned {
            selected = pinned
        } else {
            // A scoped global sleep transaction needs the daemon's durable
            // root-owned restore journal. The legacy osascript loop remains
            // release-only so an upgrade can clean its stale control file,
            // but it cannot safely promise reboot recovery for new work.
            if mode != .released, !helperInstalled() {
                lock.unlock()
                return false
            }
            selected = helperInstalled() ? .daemon : .fallback
            if mode != .released { pinnedBackend = selected }
        }
        lock.unlock()

        let ok: Bool
        switch selected {
        case .daemon: ok = daemon.setMode(mode)
        case .fallback: ok = fallback.setMode(mode)
        }
        guard mode == .released, ok else { return ok }

        // The owning backend confirmed restoration. Clear the pin, then
        // remove any stale control artifact on the inactive side.
        lock.lock()
        pinnedBackend = nil
        lock.unlock()
        switch selected {
        case .daemon: fallback.removeFlag()
        case .fallback:
            if helperInstalled() || daemon.isFlagPresent() {
                daemon.removeFlag()
            }
        }
        return true
    }

    public func startHelper(appPID: Int32) -> SleepSettingResult {
        lock.lock()
        let pinned = pinnedBackend
        if pinned == nil, !helperInstalled() {
            lock.unlock()
            return .failed(L("The Keepresso helper isn't responding."))
        }
        let selected = pinned ?? Backend.daemon
        lock.unlock()
        let result: SleepSettingResult
        switch selected {
        case .daemon: result = daemon.startHelper(appPID: appPID)
        case .fallback: result = fallback.startHelper(appPID: appPID)
        }
        if result != .applied {
            let hasTransaction: Bool
            switch selected {
            case .daemon: hasTransaction = daemon.isFlagPresent()
            case .fallback: hasTransaction = fallback.isFlagPresent()
            }
            if !hasTransaction {
                lock.lock()
                pinnedBackend = nil
                lock.unlock()
            }
        }
        return result
    }

    public var engageFailureMessage: String {
        lock.lock()
        let pinned = pinnedBackend
        lock.unlock()
        switch pinned {
        case .daemon: return daemon.engageFailureMessage
        case .fallback: return fallback.engageFailureMessage
        case nil: return daemon.engageFailureMessage
        }
    }
}

/// The AWDL twin of ``RoutedSleepWatchdog``.
public final class RoutedAWDLWatchdog: AWDLWatchdogLaunching, @unchecked Sendable {
    private let daemon: HelperDaemonAWDLWatchdog
    private let fallback: AWDLWatchdogLaunching
    private let helperInstalled: @Sendable () -> Bool

    public init(
        daemon: HelperDaemonAWDLWatchdog,
        fallback: AWDLWatchdogLaunching,
        helperInstalled: @escaping @Sendable () -> Bool
    ) {
        self.daemon = daemon
        self.fallback = fallback
        self.helperInstalled = helperInstalled
    }

    public func isFlagPresent() -> Bool {
        daemon.isFlagPresent() || fallback.isFlagPresent()
    }

    public func createFlag() -> Bool {
        helperInstalled() ? daemon.createFlag() : fallback.createFlag()
    }

    public func removeFlag() {
        if helperInstalled() || daemon.isFlagPresent() {
            daemon.removeFlag()
        }
        fallback.removeFlag()
    }

    public func startHelper(appPID: Int32) -> AWDLWatchdogStartResult {
        helperInstalled() ? daemon.startHelper(appPID: appPID) : fallback.startHelper(appPID: appPID)
    }

    public var engageFailureMessage: String {
        helperInstalled() ? daemon.engageFailureMessage : fallback.engageFailureMessage
    }
}

/// ``SleepSettingControlling`` that reads through the plain `pmset -g` backend
/// (no privileges needed to read) and writes through the daemon when
/// installed, falling back to the osascript admin prompt when not.
public final class RoutedSleepControl: SleepSettingControlling, @unchecked Sendable {
    private let helper: PrivilegedHelperCalling
    private let fallback: SleepSettingControlling
    private let helperInstalled: @Sendable () -> Bool

    public init(
        helper: PrivilegedHelperCalling,
        fallback: SleepSettingControlling,
        helperInstalled: @escaping @Sendable () -> Bool
    ) {
        self.helper = helper
        self.fallback = fallback
        self.helperInstalled = helperInstalled
    }

    public func isSleepDisabled() -> Bool? {
        fallback.isSleepDisabled()
    }

    public func setSleepDisabled(_ disabled: Bool) -> SleepSettingResult {
        guard helperInstalled() else {
            return fallback.setSleepDisabled(disabled)
        }
        return helper.setSleepDisabled(disabled)
            ? .applied
            : .failed(L("The Keepresso helper couldn't change the setting."))
    }
}
