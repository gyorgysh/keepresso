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

@Test func toolsSectionDefaultsClosedAndRemembersExpandedState() throws {
    let legacyJSON = """
    { "showToolsInMenu": true }
    """
    let upgraded = try JSONDecoder().decode(
        KeepressoSettings.self, from: Data(legacyJSON.utf8))
    #expect(!upgraded.toolsSectionExpanded)
    #expect(!KeepressoSettings.default.toolsSectionExpanded)

    var settings = KeepressoSettings.default
    settings.menuCustomizationEnabled = true
    settings.toolsSectionExpanded = true
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(
        KeepressoSettings.self, from: data
    ).toolsSectionExpanded == true)
}

@Test func menuCustomizationIsOptInAndSectionChoicesRoundTrip() throws {
    // A settings blob from before menu customization keeps the established
    // layout. All section choices are seeded on for a later explicit opt-in.
    let json = """
    { "triggersEnabled": true }
    """
    let upgraded = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
    #expect(!upgraded.menuCustomizationEnabled)
    #expect(upgraded.showManualSessionInMenu)
    #expect(upgraded.showTriggerControlsInMenu)
    #expect(upgraded.showQuickSettingsInMenu)
    #expect(upgraded.showToolsInMenu)

    // A user's one-section layout survives persistence.
    var settings = KeepressoSettings.default
    settings.menuCustomizationEnabled = true
    settings.showManualSessionInMenu = false
    settings.showQuickSettingsInMenu = false
    settings.showToolsInMenu = false
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.menuCustomizationEnabled)
    #expect(!decoded.showManualSessionInMenu)
    #expect(decoded.showTriggerControlsInMenu)
    #expect(!decoded.showQuickSettingsInMenu)
    #expect(!decoded.showToolsInMenu)

    // Corrupt or hand-edited settings cannot hide every configurable section.
    let emptyJSON = """
    {
      "showManualSessionInMenu": false,
      "showTriggerControlsInMenu": false,
      "showQuickSettingsInMenu": false,
      "showToolsInMenu": false
    }
    """
    let repaired = try JSONDecoder().decode(KeepressoSettings.self, from: Data(emptyJSON.utf8))
    #expect(repaired.showManualSessionInMenu)
    #expect(!repaired.showTriggerControlsInMenu)
    #expect(!repaired.showQuickSettingsInMenu)
    #expect(!repaired.showToolsInMenu)
}

@Test func menuSectionOrderDefaultsRoundTripsAndRepairsMalformedLists() throws {
    let legacyJSON = """
    { "triggersEnabled": true }
    """
    let upgraded = try JSONDecoder().decode(
        KeepressoSettings.self, from: Data(legacyJSON.utf8))
    #expect(upgraded.menuSectionOrder == MenuBarSection.defaultOrder)

    var settings = KeepressoSettings.default
    settings.menuSectionOrder = [
        .manualSession, .toolsAndShortcuts, .triggers, .quickSettings,
    ]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(decoded.menuSectionOrder == settings.menuSectionOrder)

    // Duplicates are removed, unknown future values are ignored, and missing
    // known sections return at the end in their stable default order.
    let malformedJSON = """
    {
      "menuSectionOrder": ["quickSettings", "quickSettings", "futureSection", "triggers"]
    }
    """
    let repaired = try JSONDecoder().decode(
        KeepressoSettings.self, from: Data(malformedJSON.utf8))
    #expect(repaired.menuSectionOrder == [
        .quickSettings, .triggers, .manualSession, .toolsAndShortcuts,
    ])
}

@Test func collapsedMenuKeepsTheFirstTwoEnabledSections() {
    let order: [MenuBarSection] = [
        .toolsAndShortcuts, .quickSettings, .triggers, .manualSession,
    ]
    let enabled: Set<MenuBarSection> = [
        .toolsAndShortcuts, .triggers, .manualSession,
    ]

    #expect(MenuBarSection.displayedSections(
        in: order, enabled: enabled, expanded: false
    ) == [.toolsAndShortcuts, .triggers])
    #expect(MenuBarSection.displayedSections(
        in: order, enabled: enabled, expanded: true
    ) == [.toolsAndShortcuts, .triggers, .manualSession])
}

@Test func disablingCustomizationRestoresStandardLayoutWithoutLosingChoices() throws {
    var settings = KeepressoSettings(
        menuPanelExpanded: false,
        menuCustomizationEnabled: true,
        showManualSessionInMenu: false,
        showTriggerControlsInMenu: false,
        showQuickSettingsInMenu: true,
        showToolsInMenu: true,
        toolsSectionExpanded: true,
        menuSectionOrder: [.toolsAndShortcuts, .quickSettings, .manualSession, .triggers]
    )
    #expect(settings.customizedMenuSections == [.toolsAndShortcuts, .quickSettings])

    settings.menuCustomizationEnabled = false
    let data = try JSONEncoder().encode(settings)
    let restored = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    // Nil selects the original adaptive panel, even with saved custom choices.
    #expect(restored.customizedMenuSections == nil)
    #expect(restored == settings)

    settings.menuCustomizationEnabled = true
    #expect(settings.customizedMenuSections == [.toolsAndShortcuts, .quickSettings])
}

@Test(arguments: [true, false])
func legacyMenuChoicesDoNotOptUsersIn(expanded: Bool) throws {
    // Settings from the early PR version have section choices but no explicit
    // opt-in. A normal upgrade must ignore them when choosing the layout.
    let json = """
    {
      "triggersEnabled": true,
      "menuPanelExpanded": \(expanded),
      "showQuickSettingsInMenu": false,
      "showToolsInMenu": false,
      "toolsSectionExpanded": true,
      "menuSectionOrder": ["toolsAndShortcuts", "manualSession"]
    }
    """
    let settings = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
    #expect(settings.customizedMenuSections == nil)
    #expect(settings.menuPanelExpanded == expanded)
    #expect(settings.triggersEnabled)
}

@Test func malformedCustomizationDoesNotDiscardExistingSettings() throws {
    let legacyJSON = """
    {
      "triggersEnabled": true,
      "menuPanelExpanded": false,
      "showCountdownInMenuBar": true,
      "closedDisplayOnlyWhileBrewing": true,
      "pauseBelowBatteryPercent": 40,
      "glassClarity": 75,
      "quickStopDurations": [900, 5400]
    }
    """
    let legacy = try JSONDecoder().decode(KeepressoSettings.self, from: Data(legacyJSON.utf8))
    var object = try #require(JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as? [String: Any])
    object["menuCustomizationEnabled"] = "yes"
    object["showManualSessionInMenu"] = []
    object["showTriggerControlsInMenu"] = "no"
    object["showQuickSettingsInMenu"] = [:] as [String: String]
    object["showToolsInMenu"] = 0
    object["toolsSectionExpanded"] = "yes"
    object["menuSectionOrder"] = ["quickSettings", 123] as [Any]
    let data = try JSONSerialization.data(withJSONObject: object)
    let recovered = try JSONDecoder().decode(KeepressoSettings.self, from: data)
    #expect(recovered == legacy)
}

@Test func emptyCustomizedMenuRepairsToManualControls() throws {
    let settings = KeepressoSettings(
        menuCustomizationEnabled: true,
        showManualSessionInMenu: false,
        showTriggerControlsInMenu: false,
        showQuickSettingsInMenu: false,
        showToolsInMenu: false
    )
    #expect(settings.customizedMenuSections == [.manualSession])
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(KeepressoSettings.self, from: data) == settings)
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

@Test func freshInstallDefaultsOnlyTouchUnsaved() {
    // A first launch (nothing persisted) starts session-scoped; anything
    // saved, including an explicit off, passes through untouched.
    let fresh = KeepressoSettings.default.withFreshInstallDefaults(hasStoredSettings: false)
    #expect(fresh.closedDisplayOnlyWhileBrewing)

    var savedOff = KeepressoSettings.default
    savedOff.closedDisplayOnlyWhileBrewing = false
    #expect(savedOff.withFreshInstallDefaults(hasStoredSettings: true) == savedOff)

    // Everything else passes through on a fresh install too.
    #expect(fresh.reminderAfter == KeepressoSettings.default.reminderAfter)
    #expect(fresh.options == KeepressoSettings.default.options)
}

@Test func storeKnowsWhetherAnythingWasPersisted() {
    let defaults = UserDefaults(suiteName: "keepresso.tests.firstlaunch")!
    defaults.removePersistentDomain(forName: "keepresso.tests.firstlaunch")
    let store = UserDefaultsSettingsStore(defaults: defaults, key: "k")
    #expect(!store.hasStoredSettings)
    store.save(KeepressoSettings.default)
    #expect(store.hasStoredSettings)
}

@Test func displaySecondsNeverTraps() {
    #expect(KeepressoSettings.displaySeconds(90.4) == 90)
    #expect(KeepressoSettings.displaySeconds(-3) == 0)
    #expect(KeepressoSettings.displaySeconds(.nan) == 0)
    #expect(KeepressoSettings.displaySeconds(.infinity) == 0)
    #expect(KeepressoSettings.displaySeconds(1e308) > Int.max / 4)
}

@Test(arguments: [true, false])
func customizationUpgradePreservesAComplete125SettingsBlob(expanded: Bool) throws {
    // Produced by the settings encoder at f231b07 (1.25.0), before menu
    // customization existed. Keep the serialized representation here so an
    // upgrade exercises the previous release's data, including its enum shape.
    let fixture = """
    {
      "options": {
        "preventSystemSleep": false, "preventDisplaySleep": true,
        "allowScreenSaverAfter": 400, "dimFloor": 0.25,
        "simulateUserActivity": true, "activitySimulationMethod": "specifiedKey",
        "activitySimulationKeyCode": 40, "activityPokeIdleMinutes": 5
      },
      "defaultMode": {"timed": {"duration": 12345}},
      "triggersEnabled": true,
      "ruleSet": {"combine": "all", "rules": [{"process": {"_0": "ffmpeg"}}, {"externalDisplay": {}}]},
      "reminderAfter": 1800, "reminderRepeats": true, "reminderSound": false,
      "notifyOnEnd": true, "endingSoonNoticeSeconds": 120,
      "quickStopDurations": [900, 5400], "endAction": "lockScreen",
      "eventHooks": [{
        "id": "E7A6D53C-E07A-48AE-9194-EEBF2C38A38B", "enabled": true,
        "event": "sessionStarted", "action": {"runShortcut": {"name": "Mine"}}
      }],
      "wakeSchedule": {
        "repeatingEnabled": true, "repeatSecondsFromMidnight": 42300,
        "repeatWeekdays": "MTWRF", "startSessionOnWake": true,
        "sessionDurationSeconds": 6000, "presetID": "custom"
      },
      "automationSync": {
        "enabled": true, "enabledSources": [], "mutedIDs": ["hidden"],
        "holdSeconds": 2400, "leadSeconds": 120
      },
      "diskKeepAlive": {"directory": "file:///Volumes/Archive", "interval": 200},
      "virtualDisplay": {"width": 1920, "height": 1080, "hiDPI": false},
      "thermalSafety": {
        "mode": {"sensors": {"ids": ["Tp09"], "celsius": 98}},
        "sustainSeconds": 60, "fanBoostPercent": 80, "stopBrewing": true
      },
      "pauseBelowBatteryPercent": 40, "showCountdownInMenuBar": true,
      "menuPanelExpanded": true, "glassClarity": 75,
      "awdlAutoWithGaming": true, "awdlNotifications": true, "awdlGraceSeconds": 150,
      "closedDisplayOnlyWhileBrewing": false, "closedLidDisplayPolicy": "displayOff",
      "hotKey": {"keyCode": 40, "modifierFlags": 1048576}, "startOnLaunch": true,
      "presets": [{
        "id": "custom", "name": "Render",
        "ruleSet": {"combine": "all", "rules": [{"process": {"_0": "ffmpeg"}}, {"externalDisplay": {}}]}
      }],
      "seededPresetIDs": ["user-deleted-built-in"], "hasOnboarded": true,
      "automationLeasesEnabled": false, "automationWakeControlEnabled": true,
      "gamePriorityBoost": true, "controllerPokeWhileGaming": true
    }
    """
    var oldFields = try #require(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
    oldFields["menuPanelExpanded"] = expanded
    let oldData = try JSONSerialization.data(withJSONObject: oldFields)
    let upgraded = try JSONDecoder().decode(KeepressoSettings.self, from: oldData)
    #expect(!upgraded.menuCustomizationEnabled)
    #expect(upgraded.menuLayout == nil)
    #expect(upgraded.customizedMenuLayout == nil)
    #expect(upgraded.customizedMenuSections == nil)
    #expect(upgraded.menuPanelExpanded == expanded)
    #expect(!upgraded.closedDisplayOnlyWhileBrewing)
    #expect(upgraded.withFreshInstallDefaults(hasStoredSettings: true) == upgraded)

    func previousReleaseFields(_ settings: KeepressoSettings) throws -> NSDictionary {
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        return encoded.filter { oldFields.keys.contains($0.key) } as NSDictionary
    }
    #expect(try previousReleaseFields(upgraded) == oldFields as NSDictionary)

    let suite = "keepresso.tests.customizationUpgrade." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(oldData, forKey: UserDefaultsSettingsStore.defaultKey)
    let store = UserDefaultsSettingsStore(defaults: defaults)
    #expect(store.hasStoredSettings)
    #expect(store.load() == upgraded)
    store.save(upgraded)
    #expect(store.load() == upgraded)

    let oldExport = try JSONSerialization.data(withJSONObject: [
        "format": SettingsTransfer.formatName, "version": 1,
        "appVersion": "1.25.0", "settings": oldFields,
    ])
    #expect(try SettingsTransfer.importSettings(from: oldExport) == upgraded)

    var customized = upgraded
    customized.menuCustomizationEnabled = true
    customized.setMenuLayout(.profile(.statusOnly))
    #expect(try previousReleaseFields(customized) == oldFields as NSDictionary)
    let imported = try SettingsTransfer.importSettings(from: SettingsTransfer.exportData(customized))
    #expect(imported == customized)
    customized.menuCustomizationEnabled = false
    store.save(customized)
    let restored = store.load()
    #expect(restored.customizedMenuLayout == nil)
    #expect(restored.customizedMenuSections == nil)
    #expect(restored.menuLayout == customized.menuLayout)
    #expect(try previousReleaseFields(restored) == oldFields as NSDictionary)
}
