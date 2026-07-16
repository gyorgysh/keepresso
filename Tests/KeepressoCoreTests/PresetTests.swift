import Testing
import Foundation
@testable import KeepressoCore

@Test func builtInPresetsHaveUniqueIDs() {
    let ids = Set(Preset.builtIns.map(\.id))
    #expect(ids.count == Preset.builtIns.count)
}

@Test func presetCodableRoundTrip() throws {
    let original = Preset(id: "custom", name: "Focus Time", ruleSet: RuleSet(combine: .all, rules: [.externalDisplay]))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Preset.self, from: data)
    #expect(decoded == original)
}

@Test func settingsDefaultsToBuiltInPresets() {
    #expect(KeepressoSettings.default.presets == Preset.builtIns)
}

@Test func settingsDecodesMissingPresetsAsBuiltIns() throws {
    // Simulates a settings blob saved before presets existed.
    let json = "{}".data(using: .utf8)!
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: json)
    #expect(decoded.presets == Preset.builtIns)
}

@Test func settingsPreservesEmptyPresetsAfterUserRemovesAll() throws {
    var settings = KeepressoSettings.default
    settings.presets = []
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.presets.isEmpty)
}

// MARK: - Seeding new built-ins into existing settings

@Test func seedingAddsOnlyUnseenBuiltIns() throws {
    // A 1.2.x settings blob: the original three built-ins, no seeding record.
    let old = ["ai-agent", "on-ac-power", "external-display"]
    let json = "{}".data(using: .utf8)!
    var settings = try JSONDecoder().decode(KeepressoSettings.self, from: json)
    #expect(settings.seededPresetIDs == old)

    settings.seedNewBuiltInPresets()
    let ids = settings.presets.map(\.id)
    #expect(ids.contains("remote-session"))
    #expect(ids.contains("backup-running"))
    #expect(ids.contains("media-render"))
    #expect(ids.contains("cloud-gaming"))
    // The originals aren't duplicated.
    #expect(ids.filter { old.contains($0) }.count == old.count)
    #expect(settings.seededPresetIDs.count == Preset.builtIns.count)
}

@Test func seedingNeverResurrectsADeletedBuiltIn() {
    var settings = KeepressoSettings.default // everything already seeded
    settings.presets.removeAll { $0.id == "remote-session" }
    settings.seedNewBuiltInPresets()
    #expect(!settings.presets.contains { $0.id == "remote-session" })
}

@Test func seedingIsIdempotent() {
    var settings = KeepressoSettings.default
    settings.seedNewBuiltInPresets()
    let once = settings
    settings.seedNewBuiltInPresets()
    #expect(settings == once)
}

// MARK: - Refreshing stored built-ins to current definitions

@Test func refreshUpdatesAStaleBuiltInRuleSet() {
    var settings = KeepressoSettings.default
    // The AI Agent preset as an older version seeded it: process rules
    // instead of the working rule.
    let stale = RuleSet(combine: .any, rules: [.process("claude"), .process("codex")])
    let index = settings.presets.firstIndex { $0.id == "ai-agent" }!
    settings.presets[index].ruleSet = stale

    settings.refreshBuiltInPresets()
    let current = Preset.builtIns.first { $0.id == "ai-agent" }!
    #expect(settings.presets[index].ruleSet == current.ruleSet)
}

@Test func refreshLeavesRenamedAndUserPresetsAndDeletionsAlone() {
    var settings = KeepressoSettings.default
    // A renamed built-in is the user's own now.
    let renamedRules = RuleSet(combine: .any, rules: [.process("mine")])
    let index = settings.presets.firstIndex { $0.id == "ai-agent" }!
    settings.presets[index].name = "My agents"
    settings.presets[index].ruleSet = renamedRules
    // A user-created preset and a deleted built-in.
    let user = Preset(name: "Mine", ruleSet: renamedRules)
    settings.presets.append(user)
    settings.presets.removeAll { $0.id == "meetings" }

    settings.refreshBuiltInPresets()
    #expect(settings.presets[index].ruleSet == renamedRules)
    #expect(settings.presets.contains { $0.id == user.id && $0.ruleSet == renamedRules })
    #expect(!settings.presets.contains { $0.id == "meetings" })
}

// MARK: - Restoring deleted built-ins

@Test func restoreBringsBackOnlyDeletedBuiltIns() {
    var settings = KeepressoSettings.default
    settings.presets.removeAll { $0.id == "meetings" || $0.id == "media-render" }
    #expect(settings.missingBuiltInPresets.map(\.id) == ["media-render", "meetings"])

    let restored = settings.restoreMissingBuiltInPresets()
    #expect(restored.map(\.id) == ["media-render", "meetings"])
    // Every built-in is present again, none duplicated.
    let ids = settings.presets.map(\.id)
    for built in Preset.builtIns { #expect(ids.filter { $0 == built.id }.count == 1) }
}

@Test func restoreLeavesUserAndRenamedPresetsUntouched() {
    var settings = KeepressoSettings.default
    // Rename a built-in (keeps its id) and add a user preset.
    let renamedIndex = settings.presets.firstIndex { $0.id == "meetings" }!
    settings.presets[renamedIndex].name = "Calls"
    settings.presets.append(Preset(id: "mine", name: "My Rule", ruleSet: .empty))
    settings.presets.removeAll { $0.id == "backup-running" }

    settings.restoreMissingBuiltInPresets()
    #expect(settings.presets.contains { $0.id == "meetings" && $0.name == "Calls" })
    #expect(settings.presets.contains { $0.id == "mine" })
    #expect(settings.presets.contains { $0.id == "backup-running" })
    // The renamed built-in isn't resurrected as a duplicate.
    #expect(settings.presets.filter { $0.id == "meetings" }.count == 1)
}

@Test func restoreIsANoOpWhenNothingIsMissing() {
    var settings = KeepressoSettings.default
    #expect(settings.missingBuiltInPresets.isEmpty)
    let restored = settings.restoreMissingBuiltInPresets()
    #expect(restored.isEmpty)
    #expect(settings == KeepressoSettings.default)
}

@Test func cloudGamingPresetPairsTheGamingTriggerWithClientAppRules() {
    // The gaming trigger already matches any frontmost cloud client; the app
    // rules add background coverage (queueing, downloading) for the
    // session-scoped clients only. Autostarting hosts (Parsec and friends)
    // must NOT get a while-running rule, or the preset pins the Mac awake
    // around the clock.
    let rules = Preset.builtIns.first { $0.id == "cloud-gaming" }!.ruleSet.rules
    #expect(rules.contains(.gaming))
    let appIDs: [String] = rules.compactMap { if case .app(let r) = $0 { return r.bundleID } else { return nil } }
    #expect(Set(appIDs) == ["com.nvidia.gfnpc.mall", "com.boosteroid.macclient"])
    #expect(Set(appIDs).isSubset(of: GamingTrigger.cloudGamingBundleIDs))
}

@Test func remoteControlPresetMatchesOnlyActiveDriving() {
    // Frontmost with a grace, never while-running: these apps autostart in
    // the background as hosts, and the host side stays awake on its own.
    let rules = Preset.builtIns.first { $0.id == "remote-control" }!.ruleSet.rules
    #expect(!rules.isEmpty)
    for rule in rules {
        guard case .app(let appRule) = rule else {
            Issue.record("unexpected non-app rule \(rule)")
            continue
        }
        #expect(appRule.match == .frontmost)
        #expect(appRule.grace > 0)
    }
}

@Test func appRuleLabelPrefersTheFriendlyNameOverTheBundleID() {
    let named = AppRule(bundleID: "com.nvidia.gfnpc.mall", name: "NVIDIA GeForce NOW")
    #expect(named.label == "NVIDIA GeForce NOW is running")
    // No name falls back to the bundle id, keeping the "App" prefix.
    #expect(AppRule(bundleID: "com.acme.tool").label == "App com.acme.tool is running")
    // Grace still appends.
    let grace = AppRule(bundleID: "tv.parsec.www", name: "Parsec", match: .frontmost, grace: 120)
    #expect(grace.label == "Parsec is frontmost (+120s)")
}

@Test func appRuleWithoutANameDecodesForBackwardCompatibility() throws {
    // A rule saved before AppRule carried a name must still decode (name nil),
    // matching stays by bundle id, and the label falls back to the bundle id.
    let json = """
    { "bundleID": "com.acme.tool", "match": "running", "grace": 0 }
    """
    let decoded = try JSONDecoder().decode(AppRule.self, from: Data(json.utf8))
    #expect(decoded.name == nil)
    #expect(decoded.bundleID == "com.acme.tool")
    #expect(decoded.label == "App com.acme.tool is running")
}

@Test func cloudGamingAndRemoteControlPresetsRenderFriendlyLabels() {
    // These presets ship app rules by bundle id; each must carry a friendly
    // name so the menu doesn't show "App com.nvidia.gfnpc.mall is running".
    let appRules = Preset.builtIns
        .filter { ["cloud-gaming", "remote-control"].contains($0.id) }
        .flatMap(\.ruleSet.rules)
        .compactMap { rule -> AppRule? in if case .app(let r) = rule { return r } else { return nil } }
    #expect(!appRules.isEmpty)
    for rule in appRules {
        #expect(rule.name != nil, "\(rule.bundleID) should have a friendly name")
        #expect(!rule.label.contains(rule.bundleID), "label should not show the raw bundle id: \(rule.label)")
    }
}

@Test func remoteSessionPresetMatchesConnectionsNotTheListener() {
    // The idle sshd listener must not hold the Mac awake; a live connection
    // (either OpenSSH process naming) must.
    let rules = Preset.builtIns.first { $0.id == "remote-session" }!.ruleSet.rules
    let queries: [String] = rules.compactMap { if case .process(let q) = $0 { return q } else { return nil } }
    let listener = ["/usr/sbin/sshd"]
    let oldStyle = ["/usr/sbin/sshd", "sshd: gyorgy@ttys001"]
    let newStyle = ["/usr/sbin/sshd", "/usr/libexec/sshd-session -R"]
    #expect(!queries.contains { ProcessTrigger.matches($0, in: listener) })
    #expect(queries.contains { ProcessTrigger.matches($0, in: oldStyle) })
    #expect(queries.contains { ProcessTrigger.matches($0, in: newStyle) })
}
