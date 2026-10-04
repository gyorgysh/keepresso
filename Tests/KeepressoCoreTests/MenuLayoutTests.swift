import Foundation
import Testing
@testable import KeepressoCore

@Test func granularMenuIsOptInAndRetainedWhenDisabled() throws {
    var settings = KeepressoSettings.default
    #expect(settings.menuLayout == nil)
    #expect(settings.customizedMenuLayout == nil)
    settings.setMenuLayout(.profile(.detailed))
    #expect(settings.customizedMenuLayout == nil)
    settings.menuCustomizationEnabled = true
    #expect(settings.customizedMenuLayout == .profile(.detailed))
    settings.menuCustomizationEnabled = false
    let restored = try JSONDecoder().decode(KeepressoSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored.customizedMenuLayout == nil)
    #expect(restored.menuLayout == settings.menuLayout)
}

@Test func menuLayoutRepairsFutureAndMalformedPresentationFields() throws {
    let json = """
    {"sectionOrder":["help","future","help"], "itemOrder":["quit","quit","future"],
     "placements":{"quit":"status","future":"help","preferences":"future"},
     "hiddenItems":["future","duration"],"hiddenSections":["future","help"],
     "compactItems":["future","quit"],"collapsedSections":["future","status"],
     "panelWidth":99999,"compactSectionCount":-10,"maxTriggerRows":0,"maxAgentRows":1000,
     "density":"future","headerStyle":false,"showDividers":"invalid",
     "showMenuBarIcon":false,"menuBarTextStyle":"iconOnly"}
    """
    let layout = try JSONDecoder().decode(MenuLayout.self, from: Data(json.utf8))
    #expect(layout.sectionOrder.first == .help)
    #expect(layout.sectionOrder.count == MenuLayoutSection.allCases.count)
    #expect(layout.itemOrder.first == .quit)
    #expect(layout.itemOrder.count == MenuItem.allCases.count)
    #expect(layout.placements == [.quit: .status])
    #expect(layout.hiddenItems == [.duration])
    #expect(layout.hiddenSections == [.help])
    #expect(layout.compactItems == [.quit])
    #expect(layout.collapsedSections == [.status])
    #expect(layout.panelWidth == MenuLayout.widthRange.upperBound)
    #expect(layout.compactSectionCount == 1)
    #expect(layout.maxTriggerRows == 1)
    #expect(layout.maxAgentRows == 20)
    #expect(layout.density == .comfortable)
    #expect(layout.headerStyle == .card)
    #expect(layout.showDividers)
    #expect(layout.showMenuBarIcon)
    #expect(try JSONDecoder().decode(MenuLayout.self, from: JSONEncoder().encode(layout)) == layout)
}

@Test func malformedGranularLayoutDoesNotDiscardFeatureSettings() throws {
    for payload in ["false", "42", "[]", #""invalid""#, "null"] {
        let json = """
        {"menuLayout":\(payload),"triggersEnabled":true,"menuCustomizationEnabled":false,
         "showCountdownInMenuBar":true,"closedDisplayOnlyWhileBrewing":true}
        """
        let settings = try JSONDecoder().decode(KeepressoSettings.self, from: Data(json.utf8))
        #expect(settings.menuLayout == nil)
        #expect(settings.triggersEnabled)
        #expect(settings.showCountdownInMenuBar)
        #expect(settings.closedDisplayOnlyWhileBrewing)
        #expect(settings.customizedMenuLayout == nil)
    }
}

@Test func menuCanHideMoveAndOrderEveryControlWithoutDuplicates() {
    var layout = MenuLayout.profile(.detailed)
    layout.moveItem(.quit, to: .status)
    #expect(layout.items(in: .status).last == .quit)
    layout.moveItem(.quit, by: -1)
    #expect(layout.items(in: .status) == [.statusHeader, .statusCaption, .quit, .endTime])
    layout.moveSection(.status, by: 1)
    #expect(layout.sectionOrder.prefix(2) == [.otherApps, .status])
    layout.moveItem(.quit, by: 999)
    layout.moveSection(.status, by: -999)
    let items = layout.groups(expanded: true).flatMap(\.items)
    #expect(items.count == MenuItem.allCases.count)
    #expect(Set(items).count == items.count)
    layout.hiddenItems = [.statusHeader, .quit]
    layout.hiddenSections = [.manualSession]
    let hidden = Set(layout.groups(expanded: true).flatMap(\.items))
    #expect(!hidden.contains(.statusHeader))
    #expect(!hidden.contains(.quit))
    #expect(!hidden.contains(.manualToggle))
    #expect(hidden.contains(.preferences))
}

@Test func compactMenuHonorsPinnedControlsAndSkipsUnavailableSections() {
    var layout = MenuLayout.profile(.detailed)
    layout.compactItems = [.manualOverride, .quit]
    #expect(Set(layout.groups(expanded: false).flatMap(\.items)) == [.manualOverride, .quit])
    #expect(layout.groups(expanded: true).flatMap(\.items).count == MenuItem.allCases.count)
    layout.compactMode = .firstSections
    layout.compactSectionCount = 1
    let available: Set<MenuItem> = [.duration, .preferences, .quit]
    #expect(layout.groups(expanded: false, available: available) == [
        MenuLayoutGroup(section: .manualSession, items: [.duration])
    ])
    layout.compactMode = .allItems
    #expect(Set(layout.groups(expanded: false, available: available).flatMap(\.items)) == available)
    layout.compactMode = .pinnedItems
    layout.showExpandToggle = false
    #expect(Set(layout.groups(expanded: false, available: available).flatMap(\.items)) == available)
}

@Test func applyingEveryMenuProfileChangesOnlyPresentation() throws {
    var settings = KeepressoSettings.default
    settings.triggersEnabled = true
    settings.options.preventDisplaySleep = true
    settings.options.simulateUserActivity = true
    settings.defaultMode = .timed(duration: 12_345)
    settings.closedDisplayOnlyWhileBrewing = true
    settings.reminderAfter = 999
    settings.endAction = .lockScreen
    settings.ruleSet = RuleSet(combine: .all, rules: [.process("ffmpeg"), .externalDisplay])
    settings.presets = [Preset(id: "mine", name: "Mine", ruleSet: settings.ruleSet)]
    func featureFields(_ settings: KeepressoSettings) throws -> NSDictionary {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "menuLayout")
        return json as NSDictionary
    }
    let original = try featureFields(settings)
    for profile in MenuLayoutProfile.allCases {
        settings.setMenuLayout(.profile(profile))
        #expect(try featureFields(settings) == original)
        #expect(try SettingsTransfer.importSettings(from: SettingsTransfer.exportData(settings)) == settings)
    }
    var empty = MenuLayout()
    empty.hiddenSections = Set(MenuLayoutSection.allCases)
    settings.setMenuLayout(empty)
    #expect(settings.menuLayout?.groups(expanded: true).isEmpty == true)
    #expect(try SettingsTransfer.importSettings(from: SettingsTransfer.exportData(settings)) == settings)
}

@Test func menuProfilesOfferMinimalThroughDetailedWithoutChangingDefaults() {
    #expect(MenuLayout.profile(.minimal).groups(expanded: true).flatMap(\.items).count == 5)
    #expect(MenuLayout.profile(.detailed).groups(expanded: true).flatMap(\.items).count == MenuItem.allCases.count)
    #expect(MenuLayout.profile(.balanced) == MenuLayout())
    var layout = MenuLayout()
    layout.showMenuBarIcon = false
    #expect(layout.normalized().showMenuBarIcon)
    layout.menuBarTextStyle = .remaining
    #expect(!layout.normalized().showMenuBarIcon)
    layout.panelWidth = 1
    #expect(layout.normalized().panelWidth == MenuLayout.widthRange.lowerBound)
}

@Test func everyMenuProfileRetainsTheStandardPanelWidthAndCollapsesSettings() {
    for profile in MenuLayoutProfile.allCases {
        let layout = MenuLayout.profile(profile)
        #expect(layout.panelWidth == MenuLayout.standardWidth)
        #expect(layout.controlStyle == .accent)
        #expect(layout.collapsedSections.isSuperset(of: [.quickSettings, .presets, .toolsAndShortcuts, .help]))
        #expect(layout.adaptiveSessionControls)
    }
    #expect(MenuLayout.profile(.detailed).collapsedSections.contains(.triggers))
    #expect(MenuLayout.profile(.detailed).collapsedSections.contains(.appShortcuts))
}

@Test func smallMenuVariantsOnlyAddTheirRequestedSwitch() {
    let compact = MenuLayout.profile(.compact)
    let items = Set(compact.groups(expanded: true).flatMap(\.items))
    #expect(Set(MenuLayout.profile(.lidControls).groups(expanded: true).flatMap(\.items)) == items.union([.closedDisplay]))
    #expect(Set(MenuLayout.profile(.brewingControls).groups(expanded: true).flatMap(\.items)) == items.union([.brewingOnly]))
    #expect(MenuLayout.profile(.lidControls).placement(of: .closedDisplay) == .manualSession)
    #expect(MenuLayout.profile(.brewingControls).placement(of: .brewingOnly) == .manualSession)
    #expect(MenuLayout.profile(.statusOnly).isStatusOnly)
    #expect(!MenuLayout.profile(.minimal).isStatusOnly)
}

@Test func enablingCustomizationAloneDoesNotSelectAnotherLayout() throws {
    var settings = KeepressoSettings.default
    settings.menuCustomizationEnabled = true
    #expect(settings.customizedMenuLayout == nil)
    #expect(try JSONDecoder().decode(KeepressoSettings.self, from: JSONEncoder().encode(settings)) == settings)
}

@Test func olderGranularLayoutsPreserveWidthAndIndependentControls() throws {
    let data = Data(#"{"panelWidth":360,"collapsedSections":[],"placements":{},"hiddenItems":[]}"#.utf8)
    let layout = try JSONDecoder().decode(MenuLayout.self, from: data)
    #expect(layout.panelWidth == 360)
    #expect(layout.controlStyle == .accent)
    #expect(!layout.adaptiveSessionControls)
    #expect(layout.collapsedSections.isEmpty)
    #expect(layout.placement(of: .triggerAction) == .triggers)
}

@Test func clearMenuControlStyleIsOptInAndRetainedInBackups() throws {
    var settings = KeepressoSettings.default
    settings.triggersEnabled = true
    settings.closedDisplayOnlyWhileBrewing = true
    var layout = MenuLayout.profile(.compact)
    layout.controlStyle = .clear
    settings.setMenuLayout(layout)
    #expect(settings.customizedMenuLayout == nil)
    settings.menuCustomizationEnabled = true
    #expect(settings.customizedMenuLayout?.controlStyle == .clear)
    #expect(settings.triggersEnabled && settings.closedDisplayOnlyWhileBrewing)
    #expect(try SettingsTransfer.importSettings(from: SettingsTransfer.exportData(settings)) == settings)
    settings.menuCustomizationEnabled = false
    #expect(settings.customizedMenuLayout == nil)
    #expect(settings.menuLayout?.controlStyle == .clear)
}

@Test func unknownMenuControlStylesRetainAccentAndOtherLayoutChoices() throws {
    for value in [#""future""#, "false", "42", "null"] {
        let json = """
        {"controlStyle":\(value),"panelWidth":360,"hiddenItems":["duration"]}
        """
        let layout = try JSONDecoder().decode(MenuLayout.self, from: Data(json.utf8))
        #expect(layout.controlStyle == .accent)
        #expect(layout.panelWidth == 360)
        #expect(layout.hiddenItems == [.duration])
    }
}
