import Foundation

/// A named, saved trigger configuration a user can apply in one action instead
/// of rebuilding a ``RuleSet`` by hand — e.g. "AI Agent" (a bundle of process
/// rules) or "On AC Power" (a single power-source rule).
///
/// Value-typed and `Codable` like ``RuleSet`` itself, so presets round-trip
/// through ``KeepressoSettings`` the same way. Applying a preset replaces the
/// current rule set outright; it's a switch, not a merge.
public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var ruleSet: RuleSet

    public init(id: String = UUID().uuidString, name: String, ruleSet: RuleSet) {
        self.id = id
        self.name = name
        self.ruleSet = ruleSet
    }
}

extension Preset {
    /// Shipped with the app so there's something useful to pick from before a
    /// user builds their own. Stored (not computed) in ``KeepressoSettings`` so
    /// a user can remove one and have it stay gone.
    public static let builtIns: [Preset] = [
        Preset(
            id: "ai-agent",
            name: "AI Agent",
            ruleSet: RuleSet(combine: .any, rules: [.process("claude"), .process("codex"), .process("grok")])
        ),
        Preset(
            id: "on-ac-power",
            name: "On AC Power",
            ruleSet: RuleSet(combine: .any, rules: [.powerSource(.onACPower)])
        ),
        Preset(
            id: "external-display",
            name: "External Display Connected",
            ruleSet: RuleSet(combine: .any, rules: [.externalDisplay])
        ),
    ]
}
