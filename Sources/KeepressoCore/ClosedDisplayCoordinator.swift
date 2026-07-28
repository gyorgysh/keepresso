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
        /// Session start with no authorization and no helper: the first engage
        /// is about to prompt, so focus the app and say what the dialog is for.
        case announceEngagePrompt
        /// An engage failed with the helper installed, which should not happen:
        /// suspect a stale daemon registration and check it.
        case verifyHelper
        /// Pulse the automation with the session's live state.
        case runAutoTick(brewing: Bool)
        /// Re-read the system setting, then enforce on what comes back. `delay`
        /// is in seconds and non-nil only where the helper needs a cycle to
        /// apply a change first.
        case refreshThenEnforce(delay: Int?)
        /// Clear a hold taken outside the automation. `announce` asks for the
        /// notification that must precede an otherwise unexplained password
        /// dialog.
        case clearForeignHold(announce: Bool)
    }

    /// Seconds to wait before mirroring an engage or release into the setting's
    /// live state, so the helper has had a cycle to apply it.
    public static let mirrorDelay = 3

    /// Ticks between unattended re-reads while the automation owns the setting.
    /// Each read shells out to `pmset -g`, so this stays slow: it is there to
    /// notice a change made behind the app's back (`pmset` by hand, another
    /// tool), not to drive the UI.
    public static let defaultPollInterval = 30

    private let pollInterval: Int
    private var sawBrewing = false
    private var sawHolding = false
    private var sawAutomationFailure = false
    /// Whether a foreign hold was already cleared, so a write that doesn't take
    /// (a failing helper, a cancelled prompt) isn't retried every second.
    private var clearedForeignHold = false
    /// Whether the password prompt for such a clear was already shown this app
    /// run, so a cancelled one isn't re-offered every second.
    private var askedToClearForeignHold = false
    /// Whether a re-read is still in flight. The setting's state is a cache, and
    /// acting on it between an engage/release and its re-read would enforce
    /// against a stale value (and without the helper, spend this run's one
    /// password prompt on a no-op).
    private var refreshPending = false
    private var refreshGeneration = 0
    private var pollTicks = 0

    public init(pollInterval: Int = ClosedDisplayCoordinator.defaultPollInterval) {
        self.pollInterval = pollInterval
    }

    /// Once-a-second pulse. Returns the actions to run, in order.
    public func tick(_ conditions: Conditions) -> [Action] {
        guard conditions.onlyWhileBrewing else { return [] }
        var actions: [Action] = []
        let brewing = conditions.brewing
        if brewing, !sawBrewing, !conditions.automationAuthorized, !conditions.helperInstalled {
            actions.append(.announceEngagePrompt)
        }
        sawBrewing = brewing
        // A session hands the setting back to the automation: let the next idle
        // stretch clear a foreign hold again (the release may restore one).
        if brewing { clearedForeignHold = false }
        if conditions.automationFailed, !sawAutomationFailure, conditions.helperInstalled {
            actions.append(.verifyHelper)
        }
        sawAutomationFailure = conditions.automationFailed
        actions.append(.runAutoTick(brewing: brewing))
        // Mirror an engage or release into the setting's live state. Ticks in
        // between stay out of the way, since the cached state is the pre-change
        // one until that read lands.
        if conditions.automationHolding != sawHolding {
            sawHolding = conditions.automationHolding
            pollTicks = 0
            actions.append(.refreshThenEnforce(delay: Self.mirrorDelay))
            return actions
        }
        // Nothing to mirror, so the cached setting only goes stale from the
        // outside. Re-read it now and then, and enforce on what comes back.
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
        // Never act on a value a pending re-read is about to replace.
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

    /// Land a completed re-read. Returns false when superseded, in which case
    /// the latch stays in place for the newer claim.
    @discardableResult
    public func endRefresh(_ token: Int, settingIsOn: Bool?) -> Bool {
        guard refreshIsCurrent(token) else { return false }
        refreshPending = false
        // A confirmed-off setting means an earlier clear took: arm again, so a
        // hold taken later in this idle stretch is still caught.
        if settingIsOn == false { clearedForeignHold = false }
        return true
    }

    /// Arm the foreign-hold clear again, for the user toggling the feature.
    public func rearmForeignHoldClear() { clearedForeignHold = false }
}
