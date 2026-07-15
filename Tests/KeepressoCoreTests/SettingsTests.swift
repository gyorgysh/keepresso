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

@Test func onboardingDefaultsOffForFreshInstallButOnForExistingSettings() throws {
    // A fresh install sees the welcome window once...
    #expect(KeepressoSettings.default.hasOnboarded == false)
    // ...but a blob saved before the field existed is an existing user, who
    // should not be shown it on upgrade, so it decodes to true.
    let json = """
    { "triggersEnabled": true }
    """
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
    #expect(decoded.hasOnboarded == true)
    // And it round-trips once actually set.
    var settings = KeepressoSettings.default
    settings.hasOnboarded = true
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(KeepressoSettings.self, from: data).hasOnboarded == true)
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

@Test func quickStopAndEndingSoonRoundTripAndDefault() throws {
    var settings = KeepressoSettings.default
    let defaults: [TimeInterval] = [900, 1800, 3600]
    #expect(settings.quickStopDurations == defaults)
    #expect(settings.endingSoonNoticeSeconds == nil)

    let custom: [TimeInterval] = [300, 2700]
    settings.quickStopDurations = custom
    settings.endingSoonNoticeSeconds = 120
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.quickStopDurations == custom)
    #expect(decoded.endingSoonNoticeSeconds == 120)

    // A blob from before the fields existed decodes to the defaults.
    let json = """
    { "triggersEnabled": true }
    """
    let old = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
    #expect(old.quickStopDurations == KeepressoSettings.defaultQuickStopDurations)
    #expect(old.endingSoonNoticeSeconds == nil)
}

@Test func quickStopDurationsAreNormalizedFromAnySource() throws {
    // Drops non-positive entries, dedupes, sorts, and caps at the maximum.
    let raw: [TimeInterval] = [1800, -60, 900, 0, 1800, 7200, 3600, 5400]
    let normalized = KeepressoSettings.normalizedQuickStopDurations(raw)
    let expected: [TimeInterval] = [900, 1800, 3600, 5400]
    #expect(normalized == expected)

    // The decoder applies the same cleanup to hand-edited or imported blobs.
    let json = """
    { "quickStopDurations": [1800, 900, -5, 900] }
    """
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
    let cleaned: [TimeInterval] = [900, 1800]
    #expect(decoded.quickStopDurations == cleaned)
}
