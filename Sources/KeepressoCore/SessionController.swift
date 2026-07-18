import Foundation
import Observation

/// The heart of Keepresso: an observable state machine that owns the current
/// keep-awake session and reconciles it down to concrete power assertions.
///
/// The controller is intentionally UI-free and side-effect-light so it can be
/// driven from SwiftUI *and* exercised in tests. It does not run its own timer;
/// the host (the app, or a test) calls ``reconcile(now:systemIdleSeconds:)``
/// periodically, typically once a second, which is where timed sessions
/// expire and the screen-saver-yield is applied.
@MainActor
@Observable
public final class SessionController {
    /// Whether a session is currently keeping the Mac awake.
    public private(set) var isActive: Bool = false

    /// Duration policy for the active (or most recently configured) session.
    public private(set) var mode: SessionMode = .indefinite

    /// What to keep awake. Editable while idle or active; changes take effect on
    /// the next ``reconcile(now:systemIdleSeconds:)``.
    public var options: SleepPreventionOptions = .default

    /// When the active session began, or `nil` while idle.
    public private(set) var startedAt: Date?

    /// When set, live triggers own activation: every ``reconcile(now:systemIdleSeconds:)``
    /// turns the session on or off to match the gate, and manual ``toggle()`` /
    /// ``start(mode:options:)`` only hold until the next tick. While gated the
    /// timed-``mode`` cap is ignored, a condition-gated session isn't time-boxed.
    /// Leave `nil` for the classic manual toggle.
    public var triggerGate: TriggerEvaluating?

    /// Fire a "still brewing" reminder once the active session has run this long,
    /// or `nil` (the default) to never remind. Guards against a Mac left awake and
    /// forgotten. Resets with each new session.
    public var reminderAfter: TimeInterval?

    /// When true, the reminder repeats every ``reminderAfter`` (a recurring "your
    /// Mac is still awake" nudge); when false it fires once. Default false.
    public var reminderRepeats = false

    /// Whether the reminder also plays the system sound. Default true.
    public var reminderSound = true

    /// Post a notification when a session ends on its own (timed expiry, trigger
    /// drop, low-battery pause), not on a manual stop. Default false.
    public var notifyOnEnd = false

    /// Post a heads-up this many seconds before a timed session stops on its
    /// own, or `nil` (the default) for no heads-up. One-shot per session:
    /// ``start(mode:options:cause:)`` and ``stopIn(_:)`` arm it, and a session
    /// that begins already inside the window suppresses it (an instant "ends
    /// soon" right after picking a short duration would be noise).
    public var endingSoonNotice: TimeInterval?

    /// What to do to the Mac when a session ends on its own. Default none.
    /// Debounced by ``endActionDebounce`` so a trigger flap or an immediate
    /// restart cancels the pending action. Never runs on battery or thermal
    /// pauses (those manage sleep themselves).
    public var endAction: SessionEndAction = .none

    /// Seconds to wait after a natural session end before performing
    /// ``endAction``. A restart (manual, trigger, or command) within this
    /// window cancels the pending action. Three seconds absorbs a brief
    /// trigger flap without feeling slow when the Mac should actually sleep.
    public static let endActionDebounce: TimeInterval = 3

    /// When a timed session's deadline is noticed this many seconds late
    /// (typically because the Mac slept across it), the end action is
    /// suppressed: opening the lid after overnight sleep must not
    /// immediately sleep the display or lock the screen. Notifications still
    /// fire.
    public static let endActionStaleGrace: TimeInterval = 30

    /// When set, ``reconcile(now:systemIdleSeconds:battery:thermal:)`` force-stops
    /// an active session (releasing assertions and letting the Mac sleep) once
    /// the battery drops below this percentage, and holds off reactivating,
    /// manual or trigger-gated, until it's fed a reading at or above it again
    /// (or an on-AC reading). `nil` (the default) never overrides on battery
    /// level.
    public var pauseBelowBatteryPercent: Int?

    /// The power situation fed to ``reconcile(now:systemIdleSeconds:battery:thermal:)``.
    ///
    /// A three-way value, not an optional percentage, because the two "no
    /// number" cases must behave differently: on AC the pause is moot and the
    /// latch clears; with no information (internal reconciles, feature off)
    /// the latch must hold, otherwise any `start()` while battery-paused would
    /// clear it, activate for one tick, and die again with natural-end effects
    /// (notification, display sleep) the user never asked for.
    public enum BatteryReading: Equatable, Sendable {
        /// Discharging on battery at this charge percentage (0-100).
        case discharging(Int)
        /// Plugged in (charging or not): the battery cannot run flat.
        case onAC
        /// No reading this call; leaves the pause latch as it is.
        case unknown
    }

    /// Every session transition, with when and why (the awake-explainer's
    /// "why did Keepresso act?" half). In-memory only.
    public let log = DecisionLog()

    /// Supplies a description of the currently satisfied trigger conditions
    /// for the ``log`` when the gate flips the session on. The app wires this
    /// to the live rule labels; `nil` (or a `nil` return) falls back to a
    /// generic message.
    public var triggerDescriber: (() -> String?)?

    private let assertions: PowerAsserting
    private let reminder: ReminderNotifying?
    private let activity: ActivitySimulating
    private let endActor: SessionEndActing
    private let now: () -> Date

    /// When the keep-active poke last fired this session, so it runs on a slow
    /// cadence (``activityPokeInterval``) rather than every reconcile.
    private var lastActivityPokeAt: Date?

    /// How often ``options`` `simulateUserActivity` reports activity to the OS.
    /// Comfortably under the shortest common idle timeout (a minute or two).
    static let activityPokeInterval: TimeInterval = 30

    /// Only report synthetic activity once the user has been genuinely idle this
    /// long. While they're providing real input (typing, or gaming with constant
    /// mouse movement) they already read as active, so there's nothing to fake
    /// and a cursor nudge would just be the "weird mouse movement" to avoid.
    static let activityIdleThreshold: TimeInterval = 10

    /// How many reminder intervals have already been surfaced this session, so
    /// the per-second ``reconcile(now:systemIdleSeconds:)`` fires each at most
    /// once (and a recurring reminder advances one nudge per interval crossed).
    private var remindersFired = 0

    /// True once the ``endingSoonNotice`` heads-up has fired for the current
    /// countdown (or was suppressed at arming), so the per-second reconcile
    /// posts it at most once per arming.
    private var endingSoonFired = false

    /// True once ``pauseBelowBatteryPercent`` has force-stopped the session, so
    /// reactivation waits for a clear recovery instead of the exact cutoff. See
    /// ``batteryResumeMargin``. Public so the UI can explain why an otherwise
    /// satisfied session (manual or trigger-gated) isn't running: the battery is
    /// below the cutoff and Keepresso is deliberately letting the Mac sleep.
    public private(set) var pausedByBattery = false

    /// Extra charge (percentage points) above the cutoff required before a
    /// battery-paused session may reactivate. A dead-band: without it a reading
    /// bouncing 19/20/19/20 around a threshold of 20 would force-stop and
    /// immediately restart every second.
    public static let batteryResumeMargin = 3

    /// Bumped each time ``start(mode:options:cause:)`` is refused by the
    /// battery pause, so the UI can nudge its explanation: the user just asked
    /// to start and nothing visibly happened. Only user-initiated paths (menu,
    /// hotkey, widget, URL command) reach `start` while paused; the trigger
    /// gate activates through `reconcile`, which never counts.
    public private(set) var batteryRefusedStarts = 0

    /// Whether the thermal guard's stop-brewing stage is enabled: the host
    /// sets it from ``ThermalSafetyConfig/stopBrewing``. Off means any stale
    /// thermal latch is cleared on the next reconcile.
    public var pauseWhenHot = false

    /// True once the thermal guard force-stopped the session, so reactivation
    /// waits for the guard's all-clear (dwell and hysteresis live there, not
    /// here). Public for the same reason as ``pausedByBattery``: the UI must
    /// be able to say the Mac is deliberately being allowed to cool.
    public private(set) var pausedByThermal = false

    /// The thermal twin of ``batteryRefusedStarts``.
    public private(set) var thermalRefusedStarts = 0

    /// Refused start attempts across both safety pauses, for the menu's
    /// "that didn't work, and here's why" shake.
    public var refusedStarts: Int { batteryRefusedStarts + thermalRefusedStarts }

    /// End action waiting out ``endActionDebounce``, or `nil` when none.
    private var pendingEndAction: SessionEndAction?
    /// When ``pendingEndAction`` should fire, wall-clock of the injected
    /// ``now`` source.
    private var pendingEndActionAt: Date?

    /// Last discharging battery percent fed to reconcile, for decision-log
    /// snapshots. Cleared on AC / unknown.
    private var lastBatteryPercent: Int?

    /// - Parameters:
    ///   - assertions: power-assertion backend; inject a fake in tests.
    ///   - reminder: reminder delivery backend; inject a fake in tests. `nil`
    ///     disables reminders entirely regardless of ``reminderAfter``.
    ///   - now: clock source; inject a controllable clock in tests.
    public init(
        assertions: PowerAsserting = IOKitPowerAssertionManager(),
        reminder: ReminderNotifying? = nil,
        activity: ActivitySimulating = IOKitActivitySimulator(),
        endActor: SessionEndActing = SystemEndActionPerformer(),
        now: @escaping () -> Date = Date.init
    ) {
        self.assertions = assertions
        self.reminder = reminder
        self.activity = activity
        self.endActor = endActor
        self.now = now
    }

    // MARK: - Lifecycle

    /// Begin (or restart) a session with the given policy.
    public func start(
        mode: SessionMode = .indefinite,
        options: SleepPreventionOptions? = nil,
        cause: SessionCause = .manual
    ) {
        // Honor the battery pause: activating here would only live until the
        // next tick's reading re-paused it, firing the natural-end effects at
        // the user seconds after they asked to start. The menu explains the
        // pause; raising the threshold or plugging in lifts it.
        if pausedByBattery {
            batteryRefusedStarts += 1
            log.record(
                began: false,
                reason: L("Not started, battery below %d%%", pauseBelowBatteryPercent ?? 0),
                kind: .startRefused,
                batteryPercent: lastBatteryPercent,
                at: now()
            )
            return
        }
        // Same contract for the thermal pause: the guard decides when the Mac
        // has cooled; a start now would just be re-stopped on the next tick.
        if pausedByThermal {
            thermalRefusedStarts += 1
            log.record(
                began: false,
                reason: L("Not started, the Mac is running hot"),
                kind: .startRefused,
                batteryPercent: lastBatteryPercent,
                at: now()
            )
            return
        }
        // A restart within the debounce window cancels a pending end action
        // (the session is back on, so sleep/lock would fight the user).
        cancelPendingEndAction()
        let restarted = isActive
        if let options { self.options = options }
        self.mode = mode
        self.startedAt = now()
        self.isActive = true
        remindersFired = 0
        lastActivityPokeAt = nil
        armEndingSoon(remaining: mode.duration)
        log.record(
            began: true,
            reason: Self.startReason(cause: cause, restarted: restarted),
            kind: .sessionStarted,
            batteryPercent: lastBatteryPercent,
            at: now()
        )
        reconcile(now: now())
    }

    /// Convert the running manual session to end `interval` from now, keeping
    /// `startedAt` and the reminder counters so the session continues rather
    /// than restarting. Works on indefinite and timed sessions alike:
    /// re-invoking replaces the countdown, shortening or extending it to
    /// exactly `interval` ahead. Ignored while idle or while triggers own
    /// activation (a gated session isn't time-boxed).
    public func stopIn(_ interval: TimeInterval) {
        guard isActive, triggerGate == nil, interval > 0, let startedAt else { return }
        let instant = now()
        mode = .timed(duration: instant.timeIntervalSince(startedAt) + interval)
        armEndingSoon(remaining: interval)
        reconcile(now: instant)
    }

    /// End the current session and release all assertions.
    public func stop(cause: SessionCause = .manual) {
        stop(reason: cause == .manual ? L("Stopped manually") : L("Stopped by a command"))
    }

    /// End work that was owned by an unattended scheduler or the active lease
    /// union. Unlike a manual stop, this is a natural completion, so the
    /// configured unattended end action runs after the debounce.
    public func finishUnattended(reason: String = "All unattended work finished") {
        stop(
            reason: L(reason),
            effects: .natural(kind: .sessionEnded)
        )
    }

    /// What effects a stop may fire beyond releasing assertions.
    private enum StopEffects {
        /// Manual or command stop: silent.
        case none
        /// Natural end: notification (if configured) and a debounced end action.
        case natural(kind: SessionEventKind)
        /// Safety pause (battery / thermal): notification only, never the end
        /// action. Those pauses already manage sleep on their own.
        case safetyPause(kind: SessionEventKind)
    }

    /// The shared teardown: logs `reason` when a session was actually running
    /// (idempotent stops don't spam the log), then releases everything. When the
    /// session ended on its own, fire the end notification and (for natural
    /// ends) schedule the end action; a manual stop stays silent so it never
    /// surprise-sleeps the Mac. A `notice` replaces the generic end
    /// notification with a specific explanation (the battery pause), delivered
    /// even when ``notifyOnEnd`` is off: that stop is invisible otherwise,
    /// which is the notice's whole point.
    private func stop(
        reason: String,
        effects: StopEffects = .none,
        notice: (title: String, body: String)? = nil
    ) {
        let wasActive = isActive
        let kind: SessionEventKind? = {
            switch effects {
            case .none: return wasActive ? .sessionEnded : nil
            case .natural(let kind), .safetyPause(let kind): return kind
            }
        }()
        if isActive {
            log.record(
                began: false,
                reason: reason,
                kind: kind,
                batteryPercent: lastBatteryPercent,
                at: now()
            )
        }
        isActive = false
        startedAt = nil
        remindersFired = 0
        endingSoonFired = false
        lastActivityPokeAt = nil
        assertions.releaseAll()
        reminder?.cancelPending()
        guard wasActive else { return }
        switch effects {
        case .none:
            break
        case .natural:
            performEndEffects(notice: notice, scheduleAction: true)
        case .safetyPause:
            performEndEffects(notice: notice, scheduleAction: false)
        }
    }

    /// Notify (and optionally schedule the end action) when a session ends on
    /// its own. The cancelled reminder above is the mid-session nudge; this is
    /// a separate one-shot. The action is debounced so a flap can cancel it.
    private func performEndEffects(
        notice: (title: String, body: String)?,
        scheduleAction: Bool
    ) {
        if let notice {
            reminder?.notify(title: notice.title, body: notice.body, sound: reminderSound)
        } else if notifyOnEnd {
            reminder?.notify(
                title: L("Keepresso stopped"),
                body: L("Your keep-awake session has ended."),
                sound: reminderSound
            )
        }
        if scheduleAction, endAction != .none {
            scheduleEndAction(endAction, at: now())
        }
    }

    private func scheduleEndAction(_ action: SessionEndAction, at instant: Date) {
        pendingEndAction = action
        pendingEndActionAt = instant.addingTimeInterval(Self.endActionDebounce)
    }

    private func cancelPendingEndAction() {
        pendingEndAction = nil
        pendingEndActionAt = nil
    }

    /// Fire a due end action, unless it has gone stale. Called from
    /// ``reconcile`` so the host's 1 Hz tick drives the debounce without a
    /// separate timer. The staleness bound covers what the scheduling-time
    /// check can't see: a Mac that slept across the debounce window, or a
    /// safety pause that starved the flush for hours, must not have the
    /// action sleep or lock the just-woken Mac long after the session ended.
    private func flushPendingEndAction(at instant: Date) {
        guard let action = pendingEndAction,
              let due = pendingEndActionAt,
              instant >= due
        else { return }
        cancelPendingEndAction()
        guard instant.timeIntervalSince(due) <= Self.endActionStaleGrace else { return }
        endActor.perform(action)
    }

    static func startReason(cause: SessionCause, restarted: Bool) -> String {
        switch cause {
        case .manual:  return restarted ? L("Restarted manually") : L("Started manually")
        case .command: return restarted ? L("Restarted by a command") : L("Started by a command")
        }
    }

    /// Convenience for the menu bar quick-toggle.
    public func toggle() {
        isActive ? stop() : start(mode: mode)
    }

    // MARK: - Derived state

    /// Seconds the current session has been running, or 0 while idle.
    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now().timeIntervalSince(startedAt))
    }

    /// Seconds remaining in a timed session, or `nil` for indefinite/idle or a
    /// trigger-gated session (gating ignores the timed cap, so there's nothing
    /// counting down, see ``reconcile(now:systemIdleSeconds:battery:thermal:)``).
    public var remaining: TimeInterval? {
        guard triggerGate == nil, isActive, let total = mode.duration, let startedAt else { return nil }
        return max(0, total - now().timeIntervalSince(startedAt))
    }

    /// Whether ``reconcile(now:systemIdleSeconds:battery:thermal:)`` can currently
    /// use a HID idle reading. True when the screen-saver yield is configured, or
    /// when keep-active is on (it needs idle time to avoid nudging a user who is
    /// actively at the keyboard/mouse). The host skips the per-second IOKit idle
    /// read when this is false, which is the default.
    public var consumesIdleReading: Bool {
        (options.preventDisplaySleep && options.allowScreenSaverAfter != nil)
            || options.simulateUserActivity
    }

    /// Whether ``reconcile(now:systemIdleSeconds:battery:thermal:)`` can currently
    /// use a battery reading: battery auto-pause is on. The host skips the
    /// per-second power-source sweep when this is false (off by default).
    public var consumesBatteryReading: Bool {
        pauseBelowBatteryPercent != nil
    }

    /// Whether a thermal reading has any effect here: the guard's stop-brewing
    /// stage is on. (The guard itself still runs its other stages regardless.)
    public var consumesThermalReading: Bool {
        pauseWhenHot
    }

    // MARK: - Reconciliation

    /// Bring live power assertions in line with current state, expire timed
    /// sessions, and apply the screen-saver yield. Safe to call frequently.
    ///
    /// - Parameters:
    ///   - now: current time (defaults to the injected clock).
    ///   - systemIdleSeconds: how long the user has been idle (HID idle time).
    ///     The app supplies this; when omitted the screen-saver yield can't fire.
    ///   - battery: the power situation. The host passes ``BatteryReading/onAC``
    ///     whenever it's plugged in (auto-pause exists to stop the Mac running
    ///     flat, which can't happen on AC, even at a low charge) and
    ///     ``BatteryReading/discharging(_:)`` with the percentage otherwise;
    ///     internal reconciles default to ``BatteryReading/unknown``, which
    ///     leaves the pause latch untouched.
    ///   - batterySafetyRecoveryPending: true while the closed-display backend
    ///     is restoring its exact sleep snapshot after a battery pause. This
    ///     keeps Agent work stopped even if the user disables battery
    ///     auto-pause or plugs in before that restore is confirmed.
    ///   - thermal: the thermal guard's verdict, dwell and hysteresis already
    ///     applied there. `.unknown` (the internal-reconcile default) leaves
    ///     the thermal latch untouched, exactly like the battery reading.
    public func reconcile(
        now: Date? = nil,
        systemIdleSeconds: TimeInterval? = nil,
        battery: BatteryReading = .unknown,
        batterySafetyRecoveryPending: Bool = false,
        thermal: ThermalReading = .unknown
    ) {
        let instant = now ?? self.now()

        switch battery {
        case .discharging(let percent):
            lastBatteryPercent = percent
        case .onAC, .unknown:
            lastBatteryPercent = nil
        }

        // Closed-display safety and session activation are two halves of one
        // transaction. Never let a settings change or an AC edge clear the
        // session latch until the privileged backend has confirmed that its
        // exact pre-task sleep setting is restored.
        if batterySafetyRecoveryPending {
            pausedByBattery = true
            cancelPendingEndAction()
            if isActive {
                stop(
                    reason: L("Paused on low battery"),
                    effects: .safetyPause(kind: .batteryPaused)
                )
            }
            triggerGate?.tick()
            return
        }

        if pauseBelowBatteryPercent == nil {
            // Feature off: never leave a stale pause latched.
            pausedByBattery = false
        } else if let threshold = pauseBelowBatteryPercent, case .discharging(let percent) = battery {
            if pausedByBattery {
                // Stay paused until charge clears the cutoff by the resume margin,
                // so a reading hovering at the threshold doesn't restart every tick.
                guard percent >= threshold + Self.batteryResumeMargin else {
                    // Keep trigger state advancing so the rule list stays live
                    // and the first post-resume decision isn't hours stale.
                    triggerGate?.tick()
                    return
                }
                pausedByBattery = false
            } else if percent < threshold {
                pausedByBattery = true
                // The safety pause owns sleep from here: a pending end action
                // from a just-ended session must not fire when the pause
                // lifts, arbitrarily later.
                cancelPendingEndAction()
                if isActive {
                    stop(
                        reason: L("Paused, battery below %d%%", threshold),
                        effects: .safetyPause(kind: .batteryPaused),
                        notice: (
                            title: L("Paused on low battery"),
                            body: L("Battery is at %d%%. Keepresso is letting the Mac sleep until you plug in to charge.", percent)
                        )
                    )
                }
                return
            }
        } else if case .onAC = battery {
            // Plugged in: the pause is moot, resume normal control.
            pausedByBattery = false
        } else if pausedByBattery {
            // No reading (an internal reconcile from start/stop): hold the
            // latch rather than activating for one tick and dying on the next.
            triggerGate?.tick()
            return
        }

        // The thermal pause, mirroring the battery block above. The guard has
        // already applied dwell and hysteresis, so this only latches: `.hot`
        // stops and holds, `.clear` releases, `.unknown` changes nothing.
        if !pauseWhenHot {
            // Feature off: never leave a stale pause latched.
            pausedByThermal = false
        } else {
            switch thermal {
            case .hot:
                if !pausedByThermal {
                    pausedByThermal = true
                    // Same rule as the battery latch above.
                    cancelPendingEndAction()
                    if isActive {
                        stop(
                            reason: L("Paused, the Mac is running hot"),
                            effects: .safetyPause(kind: .thermalPaused),
                            notice: (
                                title: L("Paused on high temperature"),
                                body: L("Keepresso stopped the keep-awake session so the Mac can cool down. It resumes when temperatures recover.")
                            )
                        )
                    }
                }
                triggerGate?.tick()
                return
            case .clear:
                pausedByThermal = false
            case .unknown:
                if pausedByThermal {
                    triggerGate?.tick()
                    return
                }
            }
        }

        if let triggerGate {
            // Triggers fully own activation; the timed cap doesn't apply.
            triggerGate.tick()
            setActive(triggerGate.isSatisfied(), at: instant)
        } else if isActive, let total = mode.duration, let startedAt,
                  instant.timeIntervalSince(startedAt) >= total {
            // A deadline noticed long after it passed (Mac slept across it)
            // still ends the session and may notify, but must not fire the
            // end action: waking the lid would immediately re-sleep the
            // display or lock the screen.
            let overdue = instant.timeIntervalSince(startedAt) - total
            let fireAction = overdue <= Self.endActionStaleGrace
            stop(
                reason: L("Timed session ended"),
                effects: fireAction
                    ? .natural(kind: .sessionEnded)
                    : .safetyPause(kind: .sessionEnded)
            )
            flushPendingEndAction(at: instant)
            return
        }

        assertions.apply(
            desiredAssertions(systemIdleSeconds: systemIdleSeconds),
            reason: "Keepresso is brewing"
        )

        maybeRemind(at: instant)
        maybeNotifyEndingSoon(at: instant)
        maybePokeActivity(at: instant, systemIdleSeconds: systemIdleSeconds)
        flushPendingEndAction(at: instant)
    }

    /// Report user activity to the OS on a slow cadence while a keep-active
    /// session runs, so app-level and enterprise idle detectors don't mark the
    /// user away. Skipped while the user is actively providing input (real input
    /// already keeps them present, and nudging then is the mouse jitter to
    /// avoid); once idle past ``activityIdleThreshold`` it pokes, then repeats
    /// every ``activityPokeInterval``. No-op unless active and the option is on.
    private func maybePokeActivity(at instant: Date, systemIdleSeconds: TimeInterval?) {
        guard isActive, options.simulateUserActivity else { return }
        if let idle = systemIdleSeconds, idle < Self.activityIdleThreshold {
            // Actively in use: nothing to fake. Arm the next poke to fire
            // promptly once they step away rather than a full interval later.
            lastActivityPokeAt = nil
            return
        }
        if let last = lastActivityPokeAt,
           instant.timeIntervalSince(last) < Self.activityPokeInterval { return }
        lastActivityPokeAt = instant
        activity.poke()
    }

    /// Surface the reminder once an active session crosses an interval boundary.
    /// One-shot fires a single time at ``reminderAfter``; recurring fires once per
    /// interval (and never floods if several intervals elapse between ticks, e.g.
    /// across a sleep). No-op when reminders are off.
    private func maybeRemind(at instant: Date) {
        guard isActive, let after = reminderAfter, after > 0, let startedAt else { return }
        let intervalsPassed = Int(instant.timeIntervalSince(startedAt) / after)
        guard intervalsPassed >= 1 else { return }
        // Recurring tracks every interval; one-shot caps at the first.
        let target = reminderRepeats ? intervalsPassed : 1
        guard target > remindersFired else { return }
        remindersFired = target

        let elapsed = Self.humanDuration(TimeInterval(target) * after)
        let body = reminderRepeats
            ? L("Your Mac is still awake. It's been %@.", elapsed)
            : L("Your Mac has been kept awake for %@.", elapsed)
        reminder?.notify(title: L("Keepresso is still brewing"), body: body, sound: reminderSound)
    }

    /// Arm the one-shot ``endingSoonNotice`` for a countdown with this much
    /// time on it: starting already inside the window marks it fired, so the
    /// user isn't pinged moments after choosing a duration shorter than the
    /// notice. `nil` remaining (an indefinite session) simply re-arms.
    private func armEndingSoon(remaining: TimeInterval?) {
        guard let notice = endingSoonNotice, notice > 0, let remaining else {
            endingSoonFired = false
            return
        }
        endingSoonFired = remaining <= notice
    }

    /// Post the "ending soon" heads-up once a timed session's remaining time
    /// drops inside ``endingSoonNotice``. One-shot per arming (see
    /// ``armEndingSoon(remaining:)``); never fires for indefinite or
    /// trigger-gated sessions.
    private func maybeNotifyEndingSoon(at instant: Date) {
        guard isActive, triggerGate == nil, !endingSoonFired,
              let notice = endingSoonNotice, notice > 0,
              let total = mode.duration, let startedAt else { return }
        let remaining = total - instant.timeIntervalSince(startedAt)
        guard remaining <= notice else { return }
        endingSoonFired = true
        // Round up to a whole minute for display: the first tick inside the
        // window sees remaining just under the lead time, and the formatter
        // truncates, so a 5-minute notice would read "4 minutes" as often
        // as not.
        let display = (remaining / 60).rounded(.up) * 60
        reminder?.notify(
            title: L("Keepresso stops soon"),
            body: L("Your keep-awake session ends in about %@.", Self.humanDuration(display)),
            sound: reminderSound
        )
    }

    /// A short, localized human duration like "30 minutes", "1 hour", or
    /// "2 hours, 15 minutes". `DateComponentsFormatter` follows the app's
    /// language and each language's plural rules, so no per-unit strings table.
    static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = total >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        // At least a minute, so a just-crossed one-shot never reads "0 minutes".
        return formatter.string(from: TimeInterval(max(60, total))) ?? ""
    }

    /// Drive `isActive` toward `want` without disturbing it when already there,
    /// so a trigger-held session keeps its original `startedAt`.
    private func setActive(_ want: Bool, at instant: Date) {
        if want, !isActive {
            // Trigger re-satisfied within the debounce: cancel a pending
            // end action so a flap doesn't sleep the Mac mid-session.
            cancelPendingEndAction()
            isActive = true
            startedAt = instant
            remindersFired = 0
            lastActivityPokeAt = nil
            let detail = triggerDescriber?().map { L("Triggers: %@", $0) }
            log.record(
                began: true,
                reason: detail ?? L("Trigger conditions met"),
                kind: .triggerFired,
                batteryPercent: lastBatteryPercent,
                at: instant
            )
        } else if !want, isActive {
            stop(
                reason: L("Trigger conditions ended"),
                effects: .natural(kind: .triggerReleased)
            )
        }
    }

    /// The assertion set implied by the current session and options.
    func desiredAssertions(systemIdleSeconds: TimeInterval?) -> Set<PowerAssertionKind> {
        guard isActive else { return [] }
        var kinds: Set<PowerAssertionKind> = []
        if options.preventSystemSleep { kinds.insert(.system) }
        if options.preventDisplaySleep {
            let yielded: Bool = {
                guard let threshold = options.allowScreenSaverAfter,
                      let idle = systemIdleSeconds else { return false }
                return idle >= threshold
            }()
            if !yielded { kinds.insert(.display) }
        }
        return kinds
    }
}
