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
