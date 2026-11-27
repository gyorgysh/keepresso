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

    /// The selected lid-shut panel policy. Zero-brightness mode keeps the
    /// display assertion when ``options`` requests it, so a dark panel does
    /// not idle-sleep underneath a remote session. Applied on the next reconcile.
    public var closedLidDisplayPolicy: ClosedLidDisplayPolicy = .displayOff

    /// When the active session began, or `nil` while idle.
    public private(set) var startedAt: Date?

    /// When set, live triggers own activation: every ``reconcile(now:systemIdleSeconds:)``
    /// turns the session on or off to match the gate, and manual ``toggle()`` /
    /// ``start(mode:options:)`` only hold until the next tick. While gated the
    /// timed-``mode`` cap is ignored, a condition-gated session isn't time-boxed.
    /// Leave `nil` for the classic manual toggle.
    public var triggerGate: TriggerEvaluating? {
        didSet {
            if triggerGate != nil { safetyPausedManual = nil }
        }
    }

    /// When set, automation leases are one more demand source, considered in
    /// both manual and trigger mode: any live lease keeps the Mac awake, and
    /// the last lease ending is a natural session end (so ``endAction``
    /// applies). Leave `nil` (the default) and the feature is invisible.
    public var leases: LeaseProviding?

    /// The leases counting as demand as of the last reconcile, for the menu.
    public private(set) var liveLeases: [LeaseSummary] = []

    private var leaseHeld = false

    /// Whether the running session is sustained by leases alone, for hosts
    /// that must choose between stopping a session and handing it over (the
    /// app's trigger pause, the menu's explicit lease stop).
    public var isLeaseHeld: Bool { leaseHeld }

    private var lastLeaseDemandAt: Date?

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
    public var pauseBelowBatteryPercent: Int? {
        didSet {
            if pauseBelowBatteryPercent == nil { pausedByBattery = false }
        }
    }

    /// The power situation fed to ``reconcile(now:systemIdleSeconds:battery:thermal:)``.
    ///
    /// A three-way value, not an optional percentage, because the two "no
    /// number" cases must behave differently: on AC the pause is moot and the
    /// latch clears; with no information (internal reconciles, feature off)
    /// the latch must hold, otherwise any `start()` while battery-paused would
    /// clear it, activate for one tick, and die again with natural-end effects
    /// (notification, display sleep) the user never asked for.
    public enum BatteryReading: Equatable, Sendable {
        case discharging(Int)
        case onAC
        case unknown
    }

    /// Whether any display worth holding awake is currently usable.
    public enum DisplayReading: Equatable, Sendable {
        case lidShutNoExternal
        case lidShutWithExternal
        case usable
        /// No reading this call. Leaves the last known reading in place so a
        /// fluttering `AppleClamshellState` or an out-of-band reconcile (start,
        /// URL command) cannot treat a still-shut lid as open. With no prior
        /// reading, treated as usable so a failed lid read
        /// never silently drops the assertion in front of someone using the Mac.
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
    private let brightness: BrightnessControlling
    private let now: () -> Date

    private var lastActivityPokeAt: Date?
    private var idleAtLastPoke: TimeInterval = 0

    private var presenceHeldUntilInput = false
    /// The previous HID idle reading while held. Real input shows up as a
    /// reading below it. A short idle alone is not enough: a key or
    /// mouse event this app posted just before the action also resets HID
    /// idle time, and must not count as the user coming back.
    private var presenceHeldIdle: TimeInterval?

    private var preDimLevel: Double?

    private var preKeyboardLevel: Double?

    /// Last panel / keyboard levels observed while the lid was open. The first
    /// clamshell tick is too late to sample: macOS has already zeroed the
    /// keyboard (and the built-in panel often drops out of the display lists),
    /// so a live read would capture 0 and a restore would leave the keys dark
    /// (see GitHub #13). Sampled only on ``DisplayReading/usable`` ticks.
    private var lastOpenPanelLevel: Double?
    private var lastOpenKeyboardLevel: Double?

    private var clamshellPanelForced = false
    private var clamshellKeyboardForced = false

    static let activityPokeInterval: TimeInterval = 30

    static let activityIdleThreshold: TimeInterval = 10

    static let pokeIdleSlack: TimeInterval = 0.5

    private var remindersFired = 0

    private var endingSoonFired = false

    /// True once ``pauseBelowBatteryPercent`` has force-stopped the session, so
    /// reactivation waits for a clear recovery instead of the exact cutoff. See
    /// ``batteryResumeMargin``. Public so the UI can explain why an otherwise
    /// satisfied session (manual or trigger-gated) isn't running: the battery is
    /// below the cutoff and Keepresso is deliberately letting the Mac sleep.
    public private(set) var pausedByBattery = false

    static let batteryResumeMargin = 3

    /// Bumped each time ``start(mode:options:cause:)`` is refused by the
    /// battery pause, so the UI can nudge its explanation: the user just asked
    /// to start and nothing visibly happened. Only user-initiated paths (menu,
    /// hotkey, widget, URL command) reach `start` while paused; the trigger
    /// gate activates through `reconcile`, which never counts.
    public private(set) var batteryRefusedStarts = 0

    /// Whether the thermal guard's stop-brewing stage is enabled: the host
    /// sets it from ``ThermalSafetyConfig/stopBrewing``. Off means any stale
    /// thermal latch is cleared at once (and again on the next reconcile).
    public var pauseWhenHot = false {
        didSet {
            if !pauseWhenHot { pausedByThermal = false }
        }
    }

    /// True once the thermal guard force-stopped the session, so reactivation
    /// waits for the guard's all-clear (dwell and hysteresis live there, not
    /// here). Public for the same reason as ``pausedByBattery``: the UI must
    /// be able to say the Mac is deliberately being allowed to cool.
    public private(set) var pausedByThermal = false

    /// The thermal twin of ``batteryRefusedStarts``.
    public private(set) var thermalRefusedStarts = 0

    private var safetyPausedManual: (
        mode: SessionMode,
        startedAt: Date?,
        remindersFired: Int,
        reason: String
    )?

    /// Set when ``reconcile(now:systemIdleSeconds:battery:thermal:)`` wanted
    /// power assertions that the backend did not hold afterwards (an
    /// `IOPMAssertionCreateWithName` failure). Cleared once the held set
    /// matches. Public so the UI can tell "session active" from "actually
    /// preventing sleep".
    public private(set) var lastAssertionError: String?

    /// Refused start attempts across both safety pauses, for the menu's
    /// "that didn't work, and here's why" shake.
    public var refusedStarts: Int { batteryRefusedStarts + thermalRefusedStarts }

    private var pendingEndAction: SessionEndAction?
    private var pendingEndActionAt: Date?

    private var lastBatteryPercent: Int?

    /// Last known display usability from a real host reading (``.usable`` or
    /// ``.lidShutNoExternal``). ``DisplayReading/unknown`` does not clear it:
    /// `AppleClamshellState` flutters to nil the same way ClosedDisplay and
    /// ThermalArming already latch around, and out-of-band reconciles that
    /// omit a display reading must keep the lid-shut policy until the next
    /// good sample. Starts as ``.unknown`` so the first missing reading fails
    /// open as usable.
    private var lastDisplayReading: DisplayReading = .unknown

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
        brightness: BrightnessControlling = NullBrightness(),
        now: @escaping () -> Date = Date.init
    ) {
        self.assertions = assertions
        self.reminder = reminder
        self.activity = activity
        self.endActor = endActor
        self.brightness = brightness
        self.now = now
    }


    /// Begin (or restart) a session with the given policy.
    public func start(
        mode: SessionMode = .indefinite,
        options: SleepPreventionOptions? = nil,
        cause: SessionCause = .manual
    ) {
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
        cancelPendingEndAction()
        leaseHeld = false
        safetyPausedManual = nil
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
        guard isActive, triggerGate == nil, !leaseHeld, interval > 0, let startedAt else { return }
        let instant = now()
        mode = .timed(duration: instant.timeIntervalSince(startedAt) + interval)
        armEndingSoon(remaining: interval)
        reconcile(now: instant)
    }

    /// End the current session and release all assertions.
    public func stop(cause: SessionCause = .manual) {
        stop(reason: cause == .manual ? L("Stopped manually") : L("Stopped by a command"))
    }

    private enum StopEffects {
        case none
        case natural(kind: SessionEventKind)
        case safetyPause(kind: SessionEventKind)
    }

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
        leaseHeld = false
        remindersFired = 0
        endingSoonFired = false
        safetyPausedManual = nil
        lastDisplayReading = .unknown
        restorePanelBrightness()
        restoreKeyboardBrightness()
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

    private func safetyStop(
        reason: String,
        effects: StopEffects,
        notice: (title: String, body: String)?,
        resumeReason: String
    ) {
        let manualOwned = triggerGate == nil && !leaseHeld
        let snapshot = (
            mode: mode,
            startedAt: startedAt,
            remindersFired: remindersFired,
            reason: resumeReason
        )
        stop(reason: reason, effects: effects, notice: notice)
        if manualOwned { safetyPausedManual = snapshot }
    }

    private func resumeSafetyPausedSession(
        _ paused: (
            mode: SessionMode,
            startedAt: Date?,
            remindersFired: Int,
            reason: String
        ),
        at instant: Date
    ) {
        safetyPausedManual = nil
        cancelPendingEndAction()
        leaseHeld = false
        mode = paused.mode
        startedAt = paused.startedAt ?? instant
        isActive = true
        remindersFired = paused.remindersFired
        lastActivityPokeAt = nil
        armEndingSoon(remaining: paused.mode.duration.map {
            $0 - instant.timeIntervalSince(startedAt ?? instant)
        })
        log.record(
            began: true,
            reason: paused.reason,
            kind: .sessionStarted,
            batteryPercent: lastBatteryPercent,
            at: instant
        )
    }

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

    private func flushPendingEndAction(at instant: Date) {
        guard let action = pendingEndAction,
              let due = pendingEndActionAt,
              instant >= due
        else { return }
        cancelPendingEndAction()
        guard instant.timeIntervalSince(due) <= Self.endActionStaleGrace else { return }
        presenceHeldUntilInput = true
        presenceHeldIdle = nil
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


    /// Seconds the current session has been running, or 0 while idle.
    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now().timeIntervalSince(startedAt))
    }

    /// Seconds remaining in a timed session, or `nil` for indefinite/idle or a
    /// trigger-gated session (gating ignores the timed cap, so there's nothing
    /// counting down, see ``reconcile(now:systemIdleSeconds:battery:thermal:)``).
    public var remaining: TimeInterval? {
        guard triggerGate == nil, !leaseHeld, isActive, let total = mode.duration, let startedAt
        else { return nil }
        return max(0, total - now().timeIntervalSince(startedAt))
    }

    /// Whether ``reconcile(now:systemIdleSeconds:battery:thermal:)`` can currently
    /// use a HID idle reading. True when the screen-saver yield is configured, or
    /// when keep-active is on (it needs idle time to avoid nudging a user who is
    /// actively at the keyboard/mouse). The host skips the per-second IOKit idle
    /// read when this is false, which is the default.
    public var consumesIdleReading: Bool {
        (options.preventDisplaySleep && options.allowScreenSaverAfter != nil)
            || (options.preventDisplaySleep && options.dimDisplayAfter != nil)
            || options.simulateUserActivity
    }

    /// Whether ``reconcile(now:systemIdleSeconds:battery:thermal:display:)`` can
    /// currently use a battery reading: battery auto-pause is on. The host skips
    /// the per-second power-source sweep when this is false (off by default).
    public var consumesBatteryReading: Bool {
        pauseBelowBatteryPercent != nil
    }

    /// Whether a display reading has any effect here: something is asking to
    /// hold the display awake, so a shut lid can adjust its assertion and
    /// brightness policy. The host skips
    /// the per-second lid and display sweep when this is false.
    public var consumesDisplayReading: Bool {
        options.preventDisplaySleep
    }

    /// Whether a thermal reading has any effect here: the guard's stop-brewing
    /// stage is on. (The guard itself still runs its other stages regardless.)
    public var consumesThermalReading: Bool {
        pauseWhenHot
    }


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
    ///   - thermal: the thermal guard's verdict, dwell and hysteresis already
    ///     applied there. `.unknown` (the internal-reconcile default) leaves
    ///     the thermal latch untouched, exactly like the battery reading.
    ///   - display: lid and external-monitor layout. ``.lidShutNoExternal``
    ///     drops the display assertion unless zero-brightness mode needs it;
    ///     ``.lidShutWithExternal`` keeps it for the external and forces the
    ///     built-in panel and keyboard dark when
    ///     prevent-display-sleep is on. `.unknown` reuses the last known
    ///     reading so a lid-property flutter or an out-of-band reconcile cannot
    ///     thrash the assertion; with no prior reading it fails open as usable.
    public func reconcile(
        now: Date? = nil,
        systemIdleSeconds: TimeInterval? = nil,
        battery: BatteryReading = .unknown,
        thermal: ThermalReading = .unknown,
        display: DisplayReading = .unknown,
        gameFrontmost: Bool = false
    ) {
        let instant = now ?? self.now()

        // Latch real display verdicts; fold `.unknown` onto the last known so
        // a nil `AppleClamshellState` or a start()/command reconcile without a
        // display sample keeps the lid-shut stand-down instead of thrashing
        // the assertion. First-ever unknown stays unknown (fails open).
        let effectiveDisplay: DisplayReading
        switch display {
        case .usable, .lidShutNoExternal, .lidShutWithExternal:
            lastDisplayReading = display
            effectiveDisplay = display
        case .unknown:
            effectiveDisplay = lastDisplayReading
        }

        let summaries = leases?.tick(now: instant) ?? []
        if summaries != liveLeases { liveLeases = summaries }
        let leaseDemand = !summaries.isEmpty
        if leaseDemand { lastLeaseDemandAt = instant }

        switch battery {
        case .discharging(let percent):
            lastBatteryPercent = percent
        case .onAC, .unknown:
            lastBatteryPercent = nil
        }

        if pauseBelowBatteryPercent == nil {
            pausedByBattery = false
        } else if let threshold = pauseBelowBatteryPercent, case .discharging(let percent) = battery {
            if pausedByBattery {
                guard percent >= threshold + Self.batteryResumeMargin else {
                    triggerGate?.tick()
                    return
                }
                pausedByBattery = false
            } else if percent < threshold {
                pausedByBattery = true
                cancelPendingEndAction()
                if isActive {
                    safetyStop(
                        reason: L("Paused, battery below %d%%", threshold),
                        effects: .safetyPause(kind: .batteryPaused),
                        notice: (
                            title: L("Paused on low battery"),
                            body: L("Battery is at %d%%. Keepresso is letting the Mac sleep until you plug in to charge.", percent)
                        ),
                        resumeReason: L("Resumed, battery recovered")
                    )
                }
                return
            }
        } else if case .onAC = battery {
            pausedByBattery = false
        } else if pausedByBattery {
            triggerGate?.tick()
            return
        }

        if !pauseWhenHot {
            pausedByThermal = false
        } else {
            switch thermal {
            case .hot:
                if !pausedByThermal {
                    pausedByThermal = true
                    cancelPendingEndAction()
                    if isActive {
                        safetyStop(
                            reason: L("Paused, the Mac is running hot"),
                            effects: .safetyPause(kind: .thermalPaused),
                            notice: (
                                title: L("Paused on high temperature"),
                                body: L("Keepresso stopped the keep-awake session so the Mac can cool down. It resumes when temperatures recover.")
                            ),
                            resumeReason: L("Resumed, temperature recovered")
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

        if triggerGate == nil, !isActive, !leaseDemand, let paused = safetyPausedManual {
            resumeSafetyPausedSession(paused, at: instant)
        }

        if let triggerGate {
            triggerGate.tick()
            let gateOn = triggerGate.isSatisfied()
            let want = gateOn || leaseDemand
            if want, isActive { leaseHeld = !gateOn }
            if want, !isActive {
                if gateOn {
                    leaseHeld = false
                    setActive(true, at: instant)
                } else {
                    beginLeaseSession(at: instant)
                }
            } else if !want, isActive {
                if leaseHeld {
                    stop(
                        reason: L("Automation lease ended"),
                        effects: leaseEndEffects(at: instant)
                    )
                } else {
                    setActive(false, at: instant)
                }
            }
        } else if isActive, !leaseHeld, let total = mode.duration, let startedAt,
                  instant.timeIntervalSince(startedAt) >= total {
            let overdue = instant.timeIntervalSince(startedAt) - total
            let fireAction = overdue <= Self.endActionStaleGrace
            stop(
                reason: L("Timed session ended"),
                effects: fireAction
                    ? .natural(kind: .sessionEnded)
                    : .safetyPause(kind: .sessionEnded)
            )
            if leaseDemand {
                beginLeaseSession(at: instant)
            } else {
                flushPendingEndAction(at: instant)
                return
            }
        } else if !isActive, leaseDemand {
            beginLeaseSession(at: instant)
        } else if isActive, leaseHeld, !leaseDemand {
            stop(
                reason: L("Automation lease ended"),
                effects: leaseEndEffects(at: instant)
            )
            flushPendingEndAction(at: instant)
            return
        }

        let userIdle = pokeAdjustedIdle(systemIdleSeconds, at: instant)
        let ownPokeReset = systemIdleSeconds.map { idleResetIsOwnPoke($0, at: instant) } ?? false
        let desired = desiredAssertions(systemIdleSeconds: userIdle, display: effectiveDisplay)
        assertions.apply(
            desired,
            reason: "Keepresso is brewing"
        )
        if desired.isSubset(of: assertions.held) {
            lastAssertionError = nil
        } else {
            lastAssertionError = L("Couldn't create a power assertion. The Mac may still sleep.")
        }

        maybeRemind(at: instant)
        maybeNotifyEndingSoon(at: instant)
        maybePokeActivity(
            at: instant, rawIdle: systemIdleSeconds, userIdle: userIdle,
            ownPokeReset: ownPokeReset, gameFrontmost: gameFrontmost)
        maybeDim(systemIdleSeconds: userIdle, display: effectiveDisplay)
        flushPendingEndAction(at: instant)
    }

    /// - **Lid shut** (either external layout, prevent-display-sleep on): force
    ///   the built-in panel and keyboard backlight to 0. A shut lid means the
    ///   built-in should emit nothing, and macOS offers no way to sleep one
    ///   display: `displaysleepnow` takes every display down, so with an
    ///   external attached brightness is the only lever there is. With no
    ///   external, ``ClosedDisplayController`` applies the selected panel
    ///   policy. This layer keeps it dark when zero-brightness mode holds the
    ///   display awake, or before the display-off policy re-sleeps it. External
    ///   displays and keyboards are untouched either way: this seam only addresses the
    ///   built-in. Restore targets come from the last open-lid sample (not a
    ///   live read after macOS has already zeroed them).
    private func maybeDim(systemIdleSeconds: TimeInterval?, display: DisplayReading = .unknown) {
        let canTouch = isActive && !leaseHeld && options.preventDisplaySleep

        if display == .usable {
            noteOpenBrightnessLevels()
        }

        if canTouch, display == .lidShutWithExternal || display == .lidShutNoExternal {
            forceClamshellDark()
            return
        }
        restoreKeyboardBrightness()

        guard canTouch,
              let threshold = options.dimDisplayAfter,
              brightness.isSupported
        else { restorePanelBrightness(); return }

        guard let idle = systemIdleSeconds else { return }
        if idle >= threshold {
            if preDimLevel == nil, let current = brightness.currentBrightness() {
                preDimLevel = current
                lastOpenPanelLevel = current
                brightness.setBrightness(options.dimFloor)
            } else if clamshellPanelForced {
                brightness.setBrightness(options.dimFloor)
                clamshellPanelForced = false
            }
        } else {
            restorePanelBrightness()
        }
    }

    /// Remember panel and keyboard levels while the lid is open. Used as the
    /// clamshell restore target so we never learn macOS's post-close zero.
    private func noteOpenBrightnessLevels() {
        if preDimLevel == nil, !clamshellPanelForced,
           let panel = brightness.currentBrightness() {
            lastOpenPanelLevel = panel
        }
        if !clamshellKeyboardForced, let keys = brightness.currentKeyboardBrightness() {
            lastOpenKeyboardLevel = keys
        }
    }

    /// Restore targets prefer a live **lit** reading, then the last open-lid
    /// sample. A live near-zero is never stored as the restore target: on the
    /// first clamshell tick macOS has usually already darkened the keyboard,
    /// and capturing that 0 was what left keys dark after lid open (#13).
    /// When no good target exists, that side is left alone so macOS can own it.
    private func forceClamshellDark() {
        if preDimLevel == nil {
            if let current = brightness.currentBrightness(), current > 0.02 {
                preDimLevel = current
                clamshellPanelForced = false
            } else if let open = lastOpenPanelLevel {
                preDimLevel = open
                clamshellPanelForced = false
            }
        }
        if preDimLevel != nil {
            let needsWrite: Bool
            if !clamshellPanelForced {
                needsWrite = true
            } else if let current = brightness.currentBrightness() {
                needsWrite = current > 0.02
            } else {
                needsWrite = false
            }
            if needsWrite {
                brightness.setBrightness(0)
                clamshellPanelForced = true
            }
        }

        guard brightness.isKeyboardSupported else { return }
        if preKeyboardLevel == nil {
            if let current = brightness.currentKeyboardBrightness(), current > 0.02 {
                preKeyboardLevel = current
                clamshellKeyboardForced = false
            } else if let open = lastOpenKeyboardLevel {
                // May be 0 if the user dimmed keys while open; still a real
                // preference, and safer than capturing macOS's post-close zero
                // when open was never sampled.
                preKeyboardLevel = open
                clamshellKeyboardForced = false
            }
        }
        if preKeyboardLevel != nil {
            let needsWrite: Bool
            if !clamshellKeyboardForced {
                needsWrite = true
            } else if let current = brightness.currentKeyboardBrightness() {
                needsWrite = current > 0.02
            } else {
                needsWrite = false
            }
            if needsWrite {
                brightness.setKeyboardBrightness(0)
                clamshellKeyboardForced = true
            }
        }
    }

    private func restorePanelBrightness() {
        guard let level = preDimLevel else { return }
        brightness.setBrightness(level)
        lastOpenPanelLevel = level
        preDimLevel = nil
        clamshellPanelForced = false
    }

    private func restoreKeyboardBrightness() {
        guard let level = preKeyboardLevel else { return }
        brightness.setKeyboardBrightness(level)
        preKeyboardLevel = nil
        clamshellKeyboardForced = false
    }

    /// Restore any panel or keyboard brightness change without ending the
    /// session, for app termination where ``stop`` isn't called. Brightness is a
    /// persistent setting the OS won't undo on exit the way it releases power
    /// assertions, so quitting mid-dim would otherwise leave the panel or keys
    /// dark. Idempotent and a no-op when nothing was held.
    public func restoreDisplayBrightness() {
        restorePanelBrightness()
        restoreKeyboardBrightness()
    }

    private func maybePokeActivity(
        at instant: Date,
        rawIdle: TimeInterval?,
        userIdle: TimeInterval?,
        ownPokeReset: Bool,
        gameFrontmost: Bool
    ) {
        if isActive { presenceHeldUntilInput = false }
        guard options.simulateUserActivity,
              isActive || !options.activityOnlyWhileBrewing else { return }
        if !isActive {
            guard let idle = rawIdle else { return }
            guard pendingEndAction == nil else { return }
            if presenceHeldUntilInput {
                guard let previous = presenceHeldIdle, idle < previous else {
                    presenceHeldIdle = idle
                    return
                }
                presenceHeldUntilInput = false
                presenceHeldIdle = nil
            }
        }
        let idleOnlyMinutes = options.activityPokeIdleMinutes.flatMap { $0 > 0 ? $0 : nil }
        if let minutes = idleOnlyMinutes {
            if gameFrontmost {
                lastActivityPokeAt = nil
                return
            }
            let needed = TimeInterval(minutes * 60)
            guard let idle = userIdle, idle >= needed else {
                return
            }
        } else if let idle = userIdle, idle < Self.activityIdleThreshold, !ownPokeReset {
            lastActivityPokeAt = nil
            return
        }
        let interval = options.activitySimulationMethod.pokeInterval
        if let last = lastActivityPokeAt,
           instant.timeIntervalSince(last) < interval { return }
        lastActivityPokeAt = instant
        idleAtLastPoke = userIdle ?? 0
        activity.poke(options.activityPokeKind)
    }

    /// The idle reading with our own poke taken out. A posted key or mouse
    /// event resets HID idle just like a person would, so read raw it looks
    /// like the user came back: that re-armed the poke and fired it again as
    /// soon as idle passed ``activityIdleThreshold`` (GitHub #35). While the
    /// reading keeps pace with the time since the poke, nothing else has
    /// touched the Mac, so idle carries on from where it was at the poke.
    /// A reading clearly below that is real input and passes through. Used
    /// for the poke, dimming, and the screen saver allowance alike, so a
    /// poke never brightens a dimmed panel either.
    private func pokeAdjustedIdle(_ raw: TimeInterval?, at instant: Date) -> TimeInterval? {
        guard let raw else { return nil }
        guard idleResetIsOwnPoke(raw, at: instant), let last = lastActivityPokeAt else { return raw }
        return max(raw, idleAtLastPoke + instant.timeIntervalSince(last))
    }

    private func idleResetIsOwnPoke(_ raw: TimeInterval, at instant: Date) -> Bool {
        guard let last = lastActivityPokeAt else { return false }
        let sincePoke = instant.timeIntervalSince(last)
        return sincePoke >= 0 && raw + Self.pokeIdleSlack >= sincePoke
    }

    private func maybeRemind(at instant: Date) {
        guard isActive, let after = reminderAfter, after > 0, after.isFinite, let startedAt else { return }
        let ratio = instant.timeIntervalSince(startedAt) / after
        guard ratio.isFinite, ratio >= 0 else { return }
        let intervalsPassed = Int(min(ratio, Double(Int.max / 2)))
        guard intervalsPassed >= 1 else { return }
        let target = reminderRepeats ? intervalsPassed : 1
        guard target > remindersFired else { return }
        remindersFired = target

        let elapsed = Self.humanDuration(TimeInterval(target) * after)
        let body = reminderRepeats
            ? L("Your Mac is still awake. It's been %@.", elapsed)
            : L("Your Mac has been kept awake for %@.", elapsed)
        reminder?.notify(title: L("Keepresso is still brewing"), body: body, sound: reminderSound)
    }

    private func armEndingSoon(remaining: TimeInterval?) {
        guard let notice = endingSoonNotice, notice > 0, let remaining else {
            endingSoonFired = false
            return
        }
        endingSoonFired = remaining <= notice
    }

    private func maybeNotifyEndingSoon(at instant: Date) {
        guard isActive, triggerGate == nil, !leaseHeld, !endingSoonFired,
              let notice = endingSoonNotice, notice > 0,
              let total = mode.duration, let startedAt else { return }
        let remaining = total - instant.timeIntervalSince(startedAt)
        guard remaining <= notice else { return }
        endingSoonFired = true
        let display = (remaining / 60).rounded(.up) * 60
        reminder?.notify(
            title: L("Keepresso stops soon"),
            body: L("Your keep-awake session ends in about %@.", Self.humanDuration(display)),
            sound: reminderSound
        )
    }

    static func humanDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0,
              seconds < Double(Int.max / 2)
        else { return "" }
        let total = Int(seconds.rounded())
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = total >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(max(60, total))) ?? ""
    }

    /// Keep an active session running when trigger gating is paused or turned
    /// off while live leases still demand it: ownership flips to the leases in
    /// place (assertions drop to `.system` on the next reconcile, lease expiry
    /// then ends the session naturally) instead of a stop that lease demand
    /// would undo one tick later. No-op unless a session is active with a
    /// live lease and not already lease-held.
    public func handOffToLeases() {
        guard isActive, !leaseHeld, !liveLeases.isEmpty else { return }
        leaseHeld = true
    }

    private func leaseEndEffects(at instant: Date) -> StopEffects {
        let late = lastLeaseDemandAt.map {
            instant.timeIntervalSince($0) > Self.endActionStaleGrace
        } ?? false
        return late ? .safetyPause(kind: .leaseReleased) : .natural(kind: .leaseReleased)
    }

    private func beginLeaseSession(at instant: Date) {
        cancelPendingEndAction()
        safetyPausedManual = nil
        isActive = true
        startedAt = instant
        remindersFired = 0
        lastActivityPokeAt = nil
        leaseHeld = true
        let detail = liveLeases.first.map { "\($0.tool): \($0.task)" }
        log.record(
            began: true,
            reason: detail.map { L("Automation lease: %@", $0) } ?? L("Automation lease acquired"),
            kind: .leaseAcquired,
            batteryPercent: lastBatteryPercent,
            at: instant
        )
    }

    private func setActive(_ want: Bool, at instant: Date) {
        if want, !isActive {
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

    func desiredAssertions(
        systemIdleSeconds: TimeInterval?,
        display: DisplayReading = .unknown
    ) -> Set<PowerAssertionKind> {
        guard isActive else { return [] }
        if leaseHeld { return [.system] }
        var kinds: Set<PowerAssertionKind> = []
        if options.preventSystemSleep { kinds.insert(.system) }
        let canHoldDisplay = display != .lidShutNoExternal || closedLidDisplayPolicy == .zeroBrightness
        if options.preventDisplaySleep, canHoldDisplay {
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
