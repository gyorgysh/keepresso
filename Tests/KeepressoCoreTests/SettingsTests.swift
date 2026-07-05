import Testing
import Foundation
@testable import KeepressoCore

@Test func settingsRoundTripCarriesTheHotKey() throws {
    var settings = KeepressoSettings.default
    settings.hotKey = HotKeyShortcut(keyCode: 40, modifierFlags: 1_048_576) // ⌘K-ish
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.hotKey == settings.hotKey)
}

@Test func settingsWithoutAHotKeyDecodeToNilWithoutThrowing() throws {
    // A blob saved before the hotKey field existed must still decode, keeping
    // the user's other settings rather than resetting to defaults.
    let json = """
    { "triggersEnabled": true, "showCountdownInMenuBar": true }
    """
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
    #expect(decoded.hotKey == nil)
    #expect(decoded.triggersEnabled == true)
    #expect(decoded.showCountdownInMenuBar == true)
}

@Test func optionsWithoutSimulateActivityDecodeToItsDefault() throws {
    // Same guarantee one level down: an options blob from before keep-active
    // existed still decodes (simulateUserActivity defaults off).
    let json = """
    { "preventSystemSleep": true, "preventDisplaySleep": true }
    """
    let decoded = try JSONDecoder().decode(SleepPreventionOptions.self, from: Data(json.utf8))
    #expect(decoded.simulateUserActivity == false)
    #expect(decoded.preventDisplaySleep == true)
}
