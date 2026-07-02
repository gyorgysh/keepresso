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
