import Foundation

/// Sequences closed-display mode's "only while brewing" automation: what to do
/// on each tick, and the latches that keep those decisions from repeating.
///
/// Host-driven like ``SessionController``. It owns no timer, spawns no task and
/// never touches the system: the host samples a ``Conditions`` snapshot, hands
/// it in, and runs the ``Action``s that come back. That keeps the delicate part
/// testable without a running app, since the bugs here are all in the
/// sequencing: edge detection, the once-per-run password prompt, and the
/// re-read latch that stops enforcement from acting on a stale setting.
///
/// The decision of whether a foreign hold should be cleared at all stays in
/// ``ClosedDisplayAuthority``; this type decides *when* to ask, and remembers
/// the answer.
@MainActor
public final class ClosedDisplayCoordinator {
    /// Everything the decisions read, sampled once per call so no decision
    /// races a value changing underneath it.
    public struct Conditions: Equatable, Sendable {
        /// Whether the "only while brewing" feature is on.
        public var onlyWhileBrewing: Bool
        /// Whether a keep-awake session is running.
        public var brewing: Bool
        /// With the root helper installed every flip is silent; without it a
        /// flip needs an administrator password.
        public var helperInstalled: Bool
        /// Whether the automation currently holds the setting itself.
        public var automationHolding: Bool
        /// Whether the fallback's authorization was already granted this run.
        public var automationAuthorized: Bool
        /// Whether the automation's last engage attempt failed.
        public var automationFailed: Bool
        /// Last read of the system setting: `true` on, `false` off, `nil` when
        /// never read or unreadable.
        public var settingIsOn: Bool?
        /// Whether an administrator prompt for the setting is already on screen.
        public var settingIsBusy: Bool

        public init(
            onlyWhileBrewing: Bool,
            brewing: Bool,
            helperInstalled: Bool,
            automationHolding: Bool,
            automationAuthorized: Bool,
            automationFailed: Bool,
            settingIsOn: Bool?,
            settingIsBusy: Bool
        ) {
            self.onlyWhileBrewing = onlyWhileBrewing
            self.brewing = brewing
            self.helperInstalled = helperInstalled
            self.automationHolding = automationHolding
            self.automationAuthorized = automationAuthorized
            self.automationFailed = automationFailed
            self.settingIsOn = settingIsOn
            self.settingIsBusy = settingIsBusy
        }
    }

    /// A side effect for the host to run, in the order returned.
    public enum Action: Equatable, Sendable {
        case announceEngagePrompt
        case verifyHelper
        case runAutoTick(brewing: Bool)
        case refreshThenEnforce(delay: Int?)
        case clearForeignHold(announce: Bool)
    }

    /// Seconds to wait before mirroring an engage or release into the setting's
    /// live state, so the helper has had a cycle to apply it.
    public static let mirrorDelay = 3

    nonisolated public static let defaultPollInterval = 30

    private let pollInterval: Int
    private var sawBrewing = false
    private var sawHolding = false
    private var sawAutomationFailure = false
    private var clearedForeignHold = false
    private var askedToClearForeignHold = false
    private var refreshPending = false
    private var refreshGeneration = 0
    private var pollTicks = 0

    public init(pollInterval: Int = ClosedDisplayCoordinator.defaultPollInterval) {
        self.pollInterval = pollInterval
    }

    /// Once-a-second pulse. Returns the actions to run, in order.
    ///
    /// The host must run them before the next ``tick(_:)``: a
    /// ``Action/refreshThenEnforce(delay:)`` only latches enforcement out once
    /// the host claims it with ``beginRefresh()``, so a tick that drops the
    /// action, or defers it past another tick, would leave enforcement free to
    /// act on the reading that refresh is about to replace.
    public func tick(_ conditions: Conditions) -> [Action] {
        guard conditions.onlyWhileBrewing else { return [] }
        var actions: [Action] = []
        let brewing = conditions.brewing
        if brewing, !sawBrewing, !conditions.automationAuthorized, !conditions.helperInstalled {
            actions.append(.announceEngagePrompt)
        }
        sawBrewing = brewing
        if brewing { clearedForeignHold = false }
        if conditions.automationFailed, !sawAutomationFailure, conditions.helperInstalled {
            actions.append(.verifyHelper)
        }
        sawAutomationFailure = conditions.automationFailed
        actions.append(.runAutoTick(brewing: brewing))
        if conditions.automationHolding != sawHolding {
            sawHolding = conditions.automationHolding
            pollTicks = 0
            actions.append(.refreshThenEnforce(delay: Self.mirrorDelay))
            return actions
        }
        pollTicks += 1
        if !brewing, pollTicks >= pollInterval, !conditions.settingIsBusy, !refreshPending {
            pollTicks = 0
            actions.append(.refreshThenEnforce(delay: nil))
        } else if let action = enforce(conditions) {
            actions.append(action)
        }
        return actions
    }

    /// Enforce the feature's authority: with it on, idle means the sleep setting
    /// is off, even when the hold was taken outside the automation.
    ///
    /// `allowPrompt` marks the paths where the user is already at the keyboard
    /// answering dialogs, which need no notification first and don't spend the
    /// run's one unattended prompt.
    public func enforce(_ conditions: Conditions, allowPrompt: Bool = false) -> Action? {
        guard !conditions.settingIsBusy, !clearedForeignHold else { return nil }
        guard !refreshPending else { return nil }
        let needsPassword = !conditions.helperInstalled
        guard ClosedDisplayAuthority.shouldClearForeignHold(
            onlyWhileBrewing: conditions.onlyWhileBrewing,
            brewing: conditions.brewing,
            automationHolding: conditions.automationHolding,
            settingIsOn: conditions.settingIsOn == true,
            canApply: !needsPassword || allowPrompt || !askedToClearForeignHold
        ) else { return nil }
        if needsPassword { askedToClearForeignHold = true }
        clearedForeignHold = true
        return .clearForeignHold(announce: needsPassword && !allowPrompt)
    }

    /// Claim the next re-read, latching enforcement out until it lands.
    public func beginRefresh() -> Int {
        refreshGeneration += 1
        refreshPending = true
        return refreshGeneration
    }

    /// Whether `token` is still the newest claim. A superseded read must not
    /// clear the latch or enforce on a value a newer one is about to replace.
    public func refreshIsCurrent(_ token: Int) -> Bool { token == refreshGeneration }

    @discardableResult
    public func endRefresh(_ token: Int, settingIsOn: Bool?) -> Bool {
        guard refreshIsCurrent(token) else { return false }
        refreshPending = false
        if settingIsOn == false { clearedForeignHold = false }
        return true
    }

    /// Arm the foreign-hold clear again, for the user toggling the feature.
    public func rearmForeignHoldClear() { clearedForeignHold = false }
}
