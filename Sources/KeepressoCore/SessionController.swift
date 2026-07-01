import Foundation
import Observation

/// The heart of Keepresso: an observable state machine that owns the current
/// keep-awake session and reconciles it down to concrete power assertions.
///
/// The controller is intentionally UI-free and side-effect-light so it can be
/// driven from SwiftUI *and* exercised in tests. It does not run its own timer;
/// the host (the app, or a test) calls ``reconcile(now:systemIdleSeconds:)``
/// periodically — typically once a second — which is where timed sessions
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
    /// timed-``mode`` cap is ignored — a condition-gated session isn't time-boxed.
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

    /// When set, ``reconcile(now:systemIdleSeconds:batteryPercent:)`` force-stops
    /// an active session (releasing assertions and letting the Mac sleep) once
    /// the battery drops below this percentage, and holds off reactivating —
    /// manual or trigger-gated — until it's fed a reading at or above it again.
    /// `nil` (the default) never overrides on battery level.
    public var pauseBelowBatteryPercent: Int?

    private let assertions: PowerAsserting
    private let reminder: ReminderNotifying?
    private let now: () -> Date

    /// How many reminder intervals have already been surfaced this session, so
    /// the per-second ``reconcile(now:systemIdleSeconds:)`` fires each at most
    /// once (and a recurring reminder advances one nudge per interval crossed).
    private var remindersFired = 0

    /// - Parameters:
    ///   - assertions: power-assertion backend; inject a fake in tests.
    ///   - reminder: reminder delivery backend; inject a fake in tests. `nil`
    ///     disables reminders entirely regardless of ``reminderAfter``.
    ///   - now: clock source; inject a controllable clock in tests.
    public init(
        assertions: PowerAsserting = IOKitPowerAssertionManager(),
        reminder: ReminderNotifying? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.assertions = assertions
        self.reminder = reminder
        self.now = now
    }

    // MARK: - Lifecycle

    /// Begin (or restart) a session with the given policy.
    public func start(mode: SessionMode = .indefinite, options: SleepPreventionOptions? = nil) {
        if let options { self.options = options }
        self.mode = mode
        self.startedAt = now()
        self.isActive = true
        remindersFired = 0
        reconcile(now: now())
    }

    /// End the current session and release all assertions.
    public func stop() {
        isActive = false
        startedAt = nil
        remindersFired = 0
        assertions.releaseAll()
        reminder?.cancelPending()
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
    /// counting down — see ``reconcile(now:systemIdleSeconds:batteryPercent:)``).
    public var remaining: TimeInterval? {
        guard triggerGate == nil, isActive, let total = mode.duration, let startedAt else { return nil }
        return max(0, total - now().timeIntervalSince(startedAt))
    }

    // MARK: - Reconciliation

    /// Bring live power assertions in line with current state, expire timed
    /// sessions, and apply the screen-saver yield. Safe to call frequently.
    ///
    /// - Parameters:
    ///   - now: current time (defaults to the injected clock).
    ///   - systemIdleSeconds: how long the user has been idle (HID idle time).
    ///     The app supplies this; when omitted the screen-saver yield can't fire.
    ///   - batteryPercent: current battery charge (0–100), or `nil` when
    ///     unavailable (e.g. on AC-only desktops). The app supplies this; when
    ///     omitted ``pauseBelowBatteryPercent`` can't fire.
    public func reconcile(now: Date? = nil, systemIdleSeconds: TimeInterval? = nil, batteryPercent: Int? = nil) {
        let instant = now ?? self.now()

        if let threshold = pauseBelowBatteryPercent, let percent = batteryPercent, percent < threshold {
            if isActive { stop() }
            return
        }

        if let triggerGate {
            // Triggers fully own activation; the timed cap doesn't apply.
            setActive(triggerGate.isSatisfied(), at: instant)
        } else if isActive, let total = mode.duration, let startedAt,
                  instant.timeIntervalSince(startedAt) >= total {
            stop()
            return
        }

        assertions.apply(
            desiredAssertions(systemIdleSeconds: systemIdleSeconds),
            reason: "Keepresso is brewing"
        )

        maybeRemind(at: instant)
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
            ? "Your Mac is still awake. It's been \(elapsed)."
            : "Your Mac has been kept awake for \(elapsed)."
        reminder?.notify(title: "Keepresso is still brewing", body: body, sound: reminderSound)
    }

    /// A short human duration like "30 minutes", "1 hour", or "2 hours 15 min".
    static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if hours > 0 && minutes > 0 { return "\(plural(hours, "hour")) \(minutes) min" }
        if hours > 0 { return plural(hours, "hour") }
        return plural(max(1, minutes), "minute")
    }

    /// Drive `isActive` toward `want` without disturbing it when already there,
    /// so a trigger-held session keeps its original `startedAt`.
    private func setActive(_ want: Bool, at instant: Date) {
        if want, !isActive {
            isActive = true
            startedAt = instant
            remindersFired = 0
        } else if !want, isActive {
            isActive = false
            startedAt = nil
            remindersFired = 0
            reminder?.cancelPending()
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
