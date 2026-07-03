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
    /// a user can remove one and have it stay gone; new built-ins reach
    /// existing users via ``KeepressoSettings/seedNewBuiltInPresets()``.
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
        // Matches only while someone is actually connected over SSH, not the
        // idle `/usr/sbin/sshd` listener: each connection runs as
        // `sshd: user@ttys000` on older OpenSSH (macOS 14) and as an
        // `sshd-session` process on OpenSSH 9.8+ (macOS 15 and later).
        Preset(
            id: "remote-session",
            name: "Remote Session (SSH)",
            ruleSet: RuleSet(combine: .any, rules: [.process("sshd:"), .process("sshd-session")])
        ),
        // `backupd` runs only while Time Machine is working on a backup.
        Preset(
            id: "backup-running",
            name: "Backup Running",
            ruleSet: RuleSet(combine: .any, rules: [.process("backupd")])
        ),
        Preset(
            id: "media-render",
            name: "Media Render",
            ruleSet: RuleSet(combine: .any, rules: [.process("ffmpeg")])
        ),
        // Camera or microphone in use covers every meeting app at once,
        // including calls running in a browser tab.
        Preset(
            id: "meetings",
            name: "Meetings",
            ruleSet: RuleSet(combine: .any, rules: [.mediaInUse(.camera), .mediaInUse(.microphone)])
        ),
    ]

    /// The built-ins that shipped before ``KeepressoSettings`` tracked seeding,
    /// used as the assumed-seeded set when loading settings saved by 1.2.x or
    /// earlier (so only genuinely new built-ins get appended for those users).
    static let preSeedTrackingBuiltInIDs = ["ai-agent", "on-ac-power", "external-display"]
}
