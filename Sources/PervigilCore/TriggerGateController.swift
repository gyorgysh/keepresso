import Foundation

/// Owns the live ``TriggerEngine`` that gates a trigger-driven session and the
/// short cache behind the menu's live rule list. Extracted from the app layer so
/// this pure logic (engine rebuild with trigger reuse, per-tick rule snapshot)
/// is testable without SwiftUI: the app wires the engine to a
/// ``SessionController`` and reads ``ruleStates()`` for its summary.
///
/// `@MainActor` like the controllers it feeds. The clock is injectable so the
/// rule-state cache can be unit-tested without waiting on real time.
@MainActor
public final class TriggerGateController {
    private let factory: TriggerFactory
    private let now: () -> Date

    /// The live engine currently gating the session, or `nil` when gating is
    /// off. Exposed so the app can hand it to ``SessionController/triggerGate``.
    public private(set) var engine: TriggerEngine?

    /// The rules ``engine``'s triggers were built from, index-aligned with
    /// `engine.triggers`, so a rebuild can carry live triggers over for rules
    /// that didn't change.
    private var engineRules: [TriggerRule] = []

    /// Cached result of ``ruleStates()`` and when it was computed. Evaluating a
    /// rule can shell out (a process trigger spawns `ps`), and the menu asks
    /// several times per render and every second, so the result is cached
    /// briefly. Cleared on every ``rebuild(rules:combine:enabled:)``.
    private var cachedStates: [RuleState]?
    private var cachedAt: Date?
    private static let ttl: TimeInterval = 0.9

    public init(factory: TriggerFactory = TriggerFactory(), now: @escaping () -> Date = Date.init) {
        self.factory = factory
        self.now = now
    }

    /// Rebuild (or tear down) the engine to match the rule set.
    ///
    /// Live triggers are stateful (a ``GracePeriodTrigger`` remembers when it
    /// was last satisfied), so this avoids discarding them: with the rules
    /// unchanged (an OR/AND flip) the engine is kept as is, and on a rule edit
    /// every unchanged rule keeps its existing trigger, so an in-flight grace
    /// window survives edits to other rules. `enabled` false tears it down.
    public func rebuild(rules: [TriggerRule], combine: CombineMode, enabled: Bool) {
        if enabled {
            if let engine, engineRules == rules {
                engine.combine = combine
            } else {
                var reusable: [TriggerRule: [Trigger]] = [:]
                if let engine {
                    for (rule, trigger) in zip(engineRules, engine.triggers) {
                        reusable[rule, default: []].append(trigger)
                    }
                }
                let triggers = rules.map { rule -> Trigger in
                    if var pool = reusable[rule], !pool.isEmpty {
                        let trigger = pool.removeFirst()
                        reusable[rule] = pool
                        return trigger
                    }
                    return factory.makeTrigger(for: rule)
                }
                engine = TriggerEngine(combine: combine, triggers: triggers)
                engineRules = rules
            }
        } else {
            engine = nil
            engineRules = []
        }
        // Skip transcript/hook walks when nothing in the engine can use them.
        let wantsAgentEvidence = enabled && engineRules.contains {
            if case .agentActivity = $0 { return true }
            return false
        }
        factory.setAgentEvidenceEnabled(wantsAgentEvidence)
        // The rules (or the engine) just changed; drop the cached states so the
        // next read re-evaluates against the new rule set immediately.
        cachedStates = nil
        cachedAt = nil
    }

    /// Live satisfaction of each rule, aligned with the rules the engine was
    /// built from, or `nil` when gating is off. Cached for ``ttl`` seconds.
    public func ruleStates() -> [RuleState]? {
        guard let engine else {
            cachedStates = nil
            return nil
        }
        if let cachedAt, let cachedStates, now().timeIntervalSince(cachedAt) < Self.ttl {
            return cachedStates
        }
        let triggers = engine.triggers
        let states = engineRules.enumerated().map { index, rule -> RuleState in
            guard index < triggers.count else { return RuleState(rule: rule, satisfied: false, inGrace: false, graceRemaining: nil) }
            let trigger = triggers[index]
            let satisfied = trigger.isSatisfied()
            // Amber "lingering" state: satisfied only because a GracePeriodTrigger
            // is holding after its wrapped condition (e.g. a game) went away, plus
            // how long is left so the UI can count it down and then go grey.
            let grace = trigger as? GracePeriodTrigger
            let inGrace = satisfied && grace?.wrappedIsSatisfied == false
            // Per-instance rows (agent sessions) live on the wrapped trigger.
            let inner = grace?.wrappedTrigger ?? trigger
            let details = (inner as? TriggerDetailProviding)?.detailRows ?? []
            return RuleState(
                rule: rule,
                satisfied: satisfied,
                inGrace: inGrace,
                graceRemaining: grace?.graceRemaining,
                details: details
            )
        }
        cachedStates = states
        cachedAt = now()
        return states
    }

    /// Whether any live agent-activity trigger flipped from working to idle
    /// on its most recent ``Trigger/tick()``. The host reads this after
    /// reconcile to fire the agent-idle outbound hook. False when gating is
    /// off or no agent rule is present. Consuming: each edge is reported
    /// once, so a gate that stops ticking (paused) can't re-report the same
    /// edge every second.
    public func agentJustWentIdle() -> Bool {
        guard let engine else { return false }
        var fired = false
        for trigger in engine.triggers {
            let inner = (trigger as? GracePeriodTrigger)?.wrappedTrigger ?? trigger
            if let agent = inner as? AgentActivityTrigger, agent.consumeJustWentIdle() {
                fired = true
            }
        }
        return fired
    }
}

/// The live state of one saved rule, for the menu's condition list.
public struct RuleState: Equatable {
    public let rule: TriggerRule
    /// Whether the rule is currently holding the session on (directly or via a
    /// grace window).
    public let satisfied: Bool
    /// Satisfied only because of a grace/linger window, not the live condition
    /// (e.g. a game just closed). Lets the UI show it amber rather than green.
    public let inGrace: Bool
    /// Seconds left in the grace window, when the rule has one and it's running,
    /// so the UI can show a countdown that resolves to grey at zero.
    public let graceRemaining: TimeInterval?
    /// Per-instance sub-rows for a multi-instance rule (the agent sessions an
    /// agent-activity rule detected), empty for every other rule.
    public let details: [RuleDetail]

    public init(rule: TriggerRule, satisfied: Bool, inGrace: Bool, graceRemaining: TimeInterval? = nil, details: [RuleDetail] = []) {
        self.rule = rule
        self.satisfied = satisfied
        self.inGrace = inGrace
        self.graceRemaining = graceRemaining
        self.details = details
    }
}
