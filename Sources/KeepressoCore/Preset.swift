import Foundation

/// A named, saved trigger configuration a user can apply in one action instead
/// of rebuilding a ``RuleSet`` by hand, e.g. "AI Agent" (a bundle of process
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

    /// The name to show in the UI. For a built-in preset the user hasn't renamed,
    /// this is the localized default name (so it follows the app's language and
    /// survives a language switch); the stored ``name`` stays the English key.
    /// A renamed built-in or a user-created preset shows its stored name as-is.
    public var displayName: String {
        if let english = Self.builtIns.first(where: { $0.id == id })?.name, english == name {
            return L(english)
        }
        return name
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
        // The gaming trigger covers a frontmost game or streaming client; the
        // app rules keep the session alive while a cloud client runs in the
        // background (queueing for a rig, downloading) without being
        // frontmost. Deliberately only the session-scoped clients: Parsec and
        // friends often autostart for hosting, so a while-running rule for
        // them would pin the Mac awake around the clock.
        Preset(
            id: "cloud-gaming",
            name: "Cloud Gaming",
            ruleSet: RuleSet(combine: .any, rules: [
                .gaming,
                .app(AppRule(bundleID: "com.nvidia.gfnpc.mall", name: "NVIDIA GeForce NOW")),
                .app(AppRule(bundleID: "com.boosteroid.macclient", name: "Boosteroid")),
            ])
        ),
        // While actively driving another machine from this Mac. Frontmost,
        // not running: these apps commonly autostart in the background as
        // hosts, and the host side stays awake on its own (the remote user's
        // input resets HID idle). The grace survives a quick alt-tab away.
        Preset(
            id: "remote-control",
            name: "Remote Control",
            ruleSet: RuleSet(combine: .any, rules: [
                .app(AppRule(bundleID: "com.teamviewer.TeamViewer", name: "TeamViewer", match: .frontmost, grace: 120)),
                .app(AppRule(bundleID: "com.philandro.anydesk", name: "AnyDesk", match: .frontmost, grace: 120)),
                .app(AppRule(bundleID: "tv.parsec.www", name: "Parsec", match: .frontmost, grace: 120)),
            ])
        ),
    ]

    /// The built-ins that shipped before ``KeepressoSettings`` tracked seeding,
    /// used as the assumed-seeded set when loading settings saved by 1.2.x or
    /// earlier (so only genuinely new built-ins get appended for those users).
    static let preSeedTrackingBuiltInIDs = ["ai-agent", "on-ac-power", "external-display"]
}
