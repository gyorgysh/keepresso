import Foundation



/// ``SleepWatchdogLaunching`` over the helper daemon. The "flag" is the
/// client's connection-scoped sleep hold; `startHelper` is a version-checked
/// ping (the daemon is already installed and root, nothing to spawn and no
/// prompt to answer).
public final class HelperDaemonSleepWatchdog: SleepWatchdogLaunching, @unchecked Sendable {
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
        let ok = helper.setSleepHold(true)
        lock.lock()
        holding = ok
        lock.unlock()
        return ok
    }

    public func removeFlag() {
        let ok = helper.setSleepHold(false)
        guard ok else { return }
        lock.lock()
        holding = false
        lock.unlock()
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
        let ok = helper.setAWDLHold(false)
        guard ok else { return }
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


/// Routes ``SleepWatchdogLaunching`` calls to the daemon backend while the
/// helper is installed and to the osascript fallback otherwise. The choice is
/// re-made at each activation (`createFlag`), so installing the helper from
/// Preferences takes effect on the next engage without a relaunch; releases go
/// to whichever side could be holding (both are idempotent no-ops when idle).
public final class RoutedSleepWatchdog: SleepWatchdogLaunching, @unchecked Sendable {
    private let daemon: HelperDaemonSleepWatchdog
    private let fallback: SleepWatchdogLaunching
    private let helperInstalled: @Sendable () -> Bool

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
        helperInstalled() ? daemon.createFlag() : fallback.createFlag()
    }

    public func removeFlag() {
        if helperInstalled() || daemon.isFlagPresent() {
            daemon.removeFlag()
        }
        fallback.removeFlag()
    }

    public func startHelper(appPID: Int32) -> SleepSettingResult {
        helperInstalled() ? daemon.startHelper(appPID: appPID) : fallback.startHelper(appPID: appPID)
    }

    public var engageFailureMessage: String {
        helperInstalled() ? daemon.engageFailureMessage : fallback.engageFailureMessage
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
