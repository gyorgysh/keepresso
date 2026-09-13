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
    #expect(decoded.activitySimulationMethod == .powerWarp)
    #expect(decoded.activitySimulationKeyCode == nil)
    #expect(decoded.activityPokeIdleMinutes == nil)
    #expect(decoded.preventDisplaySleep == true)
}

@Test func optionsKeepActiveMethodRoundTrips() throws {
    let options = SleepPreventionOptions(
        preventSystemSleep: true,
        simulateUserActivity: true,
        activitySimulationMethod: .specifiedKey,
        activitySimulationKeyCode: 113,
        activityPokeIdleMinutes: 5
    )
    let data = try JSONEncoder().encode(options)
    let decoded = try JSONDecoder().decode(SleepPreventionOptions.self, from: data)
    #expect(decoded.simulateUserActivity)
    #expect(decoded.activitySimulationMethod == .specifiedKey)
    #expect(decoded.activitySimulationKeyCode == 113)
    #expect(decoded.activityPokeIdleMinutes == 5)
    #expect(decoded.activityPokeKind == .key(113))
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

@Test func positiveIntervalHasACapAndAFloor() throws {
    // `reminderAfter` is also a divisor (`elapsed / reminderAfter`): a
    // denormal like 1e-300 would trap `Int(_:)` on the 1 Hz reconcile path,
    // and an absurd value would never fire. Both are cleaned on decode.
    let tiny = try JSONDecoder().decode(
        KeepressoSettings.self,
        from: Data(#"{ "reminderAfter": 1e-300 }"#.utf8))
    #expect(tiny.reminderAfter == 1)

    let huge = try JSONDecoder().decode(
        KeepressoSettings.self,
        from: Data(#"{ "reminderAfter": 1e300, "awdlGraceSeconds": 1e300 }"#.utf8))
    let cap = SessionMode.maxTimedMinutes * 60
    #expect(huge.reminderAfter == cap)
    #expect(huge.awdlGraceSeconds == cap)

    // The programmatic init applies the same cleanup as the decoder.
    #expect(KeepressoSettings(reminderAfter: 0.001).reminderAfter == 1)
    #expect(KeepressoSettings(awdlGraceSeconds: -5).awdlGraceSeconds == 60)

    // Sane values pass through untouched.
    let fine = try JSONDecoder().decode(
        KeepressoSettings.self,
        from: Data(#"{ "reminderAfter": 1800, "awdlGraceSeconds": 90 }"#.utf8))
    #expect(fine.reminderAfter == 1800)
    #expect(fine.awdlGraceSeconds == 90)
}

@Test func hotKeySanitizedOnBothInitPaths() throws {
    // A corrupt imported shortcut is dropped rather than trapping the
    // Carbon conversion later, on decode and on programmatic init alike.
    let bad = try JSONDecoder().decode(
        KeepressoSettings.self,
        from: Data(#"{ "hotKey": { "keyCode": -1, "modifierFlags": 1048576 } }"#.utf8))
    #expect(bad.hotKey == nil)
    #expect(KeepressoSettings(hotKey: HotKeyShortcut(keyCode: -1, modifierFlags: 0)).hotKey == nil)

    // The bound is the RegisterEventHotKey parameter width (UInt32).
    let wide = HotKeyShortcut(keyCode: Int(UInt32.max), modifierFlags: 1_048_576)
    #expect(KeepressoSettings(hotKey: wide).hotKey == wide)
    let fine = HotKeyShortcut(keyCode: 40, modifierFlags: 1_048_576)
    #expect(KeepressoSettings(hotKey: fine).hotKey == fine)
}

@Test func displaySecondsNeverTraps() {
    #expect(KeepressoSettings.displaySeconds(90.4) == 90)
    #expect(KeepressoSettings.displaySeconds(-3) == 0)
    #expect(KeepressoSettings.displaySeconds(.nan) == 0)
    #expect(KeepressoSettings.displaySeconds(.infinity) == 0)
    #expect(KeepressoSettings.displaySeconds(1e308) > Int.max / 4)
}
