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

@Test func thermalSafetyRoundTripsAndDefaultsOff() throws {
    // Absent key (any pre-thermal blob) decodes to off.
    let json = """
    { "triggersEnabled": true }
    """
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
    #expect(decoded.thermalSafety == nil)
    // A full config survives the settings round-trip.
    var settings = KeepressoSettings.default
    settings.thermalSafety = ThermalSafetyConfig(
        mode: .sensors(ids: ["Tp09"], celsius: 98),
        sustainSeconds: 60,
        fanBoostPercent: 80,
        stopBrewing: true
    )
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(KeepressoSettings.self, from: data).thermalSafety == settings.thermalSafety)
}

@Test func menuPanelExpandedDefaultsOnAndRoundTripsCollapsed() throws {
    // A blob saved before the field existed keeps today's full panel.
    let json = """
    { "triggersEnabled": true }
    """
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
    #expect(decoded.menuPanelExpanded == true)
    // And a collapsed panel stays collapsed across a save/load.
    var settings = KeepressoSettings.default
    settings.menuPanelExpanded = false
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(KeepressoSettings.self, from: data).menuPanelExpanded == false)
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

@Test func outOfRangeImportsAreNormalizedOnDecode() throws {
    // A non-positive ending-soon lead would show the feature enabled while
    // the notice can never fire; an out-of-range battery threshold would be
    // live while the slider displays its clamp. Both are cleaned on decode.
    let json = """
    { "endingSoonNoticeSeconds": -30, "pauseBelowBatteryPercent": 95 }
    """
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
    #expect(decoded.endingSoonNoticeSeconds == nil)
    #expect(decoded.pauseBelowBatteryPercent == 90)

    let low = try JSONDecoder().decode(
        KeepressoSettings.self,
        from: Data(#"{ "pauseBelowBatteryPercent": 3 }"#.utf8))
    #expect(low.pauseBelowBatteryPercent == 10)

    // In-range values pass through untouched.
    let fine = try JSONDecoder().decode(
        KeepressoSettings.self,
        from: Data(#"{ "endingSoonNoticeSeconds": 120, "pauseBelowBatteryPercent": 40 }"#.utf8))
    #expect(fine.endingSoonNoticeSeconds == 120)
    #expect(fine.pauseBelowBatteryPercent == 40)
}

@Test func automationLeasesDefaultOnAndDecodeForgivingly() throws {
    #expect(KeepressoSettings().automationLeasesEnabled)
    // A blob saved before the field existed keeps the default.
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: Data("{}".utf8))
    #expect(decoded.automationLeasesEnabled)
    let off = try JSONDecoder().decode(
        KeepressoSettings.self,
        from: Data(#"{"automationLeasesEnabled":false}"#.utf8)
    )
    #expect(!off.automationLeasesEnabled)
}
