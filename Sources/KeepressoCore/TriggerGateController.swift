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
    private var cachedStates: [(rule: TriggerRule, satisfied: Bool)]?
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
        // The rules (or the engine) just changed; drop the cached states so the
        // next read re-evaluates against the new rule set immediately.
        cachedStates = nil
        cachedAt = nil
    }

    /// Live satisfaction of each rule, aligned with the rules the engine was
    /// built from, or `nil` when gating is off. Cached for ``ttl`` seconds.
    public func ruleStates() -> [(rule: TriggerRule, satisfied: Bool)]? {
        guard let engine else {
            cachedStates = nil
            return nil
        }
        if let cachedAt, let cachedStates, now().timeIntervalSince(cachedAt) < Self.ttl {
            return cachedStates
        }
        let triggers = engine.triggers
        let states = engineRules.enumerated().map { index, rule in
            (rule, index < triggers.count && triggers[index].isSatisfied())
        }
        cachedStates = states
        cachedAt = now()
        return states
    }
}
