import Foundation

/// Stable identifiers for configurable groups. Each group can contain any row
/// the user chooses to place there.
public enum MenuLayoutSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case status, otherApps, triggers, manualSession, quickSettings, activity
    case presets, toolsAndShortcuts, appShortcuts, help
    public var id: String { rawValue }
}

/// Presentation identifiers only. Moving or hiding a row never changes the
/// feature, session, trigger, or safety setting that row controls.
public enum MenuItem: String, CaseIterable, Codable, Identifiable, Sendable {
    case statusHeader, statusCaption, endTime, otherApps
    case manualToggle, duration, quickStop, manualOverride
    case triggersToggle, triggerAction, triggerSummary, triggerRules
    case systemSleep, displaySleep, keepActive, screenSaverYield, dimDisplay
    case closedDisplay, brewingOnly, lidPolicy, batteryPause, batteryThreshold
    case reminder, endAction
    case leaseStatus, fanStatus, awdlStatus, presets
    case setup, gaming, keyboard, wifi
    case preferences, customize, welcome, about, updates, support, quit

    public var id: String { rawValue }
    public var defaultSection: MenuLayoutSection {
        switch self {
        case .statusHeader, .statusCaption, .endTime: .status
        case .otherApps: .otherApps
        case .manualToggle, .duration, .quickStop, .manualOverride: .manualSession
        case .triggersToggle, .triggerAction, .triggerSummary, .triggerRules: .triggers
        case .systemSleep, .displaySleep, .keepActive, .screenSaverYield, .dimDisplay,
             .closedDisplay, .brewingOnly, .lidPolicy, .batteryPause, .batteryThreshold,
             .reminder, .endAction: .quickSettings
        case .leaseStatus, .fanStatus, .awdlStatus: .activity
        case .presets: .presets
        case .setup, .gaming, .keyboard, .wifi: .toolsAndShortcuts
        case .preferences, .customize, .quit: .appShortcuts
        case .welcome, .about, .updates, .support: .help
        }
    }
}

public enum MenuLayoutProfile: String, CaseIterable, Identifiable, Sendable {
    case minimal, compact, balanced, lidControls, brewingControls, statusOnly, detailed
    public var id: String { rawValue }
}
public enum MenuDensity: String, CaseIterable, Codable, Identifiable, Sendable {
    case compact, comfortable, spacious
    public var id: String { rawValue }
    public var spacing: Double {
        switch self { case .compact: 8; case .comfortable: 12; case .spacious: 16 }
    }
}
public enum MenuHeaderStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case card, compact, text
    public var id: String { rawValue }
}
public enum MenuControlStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case accent, clear
    public var id: String { rawValue }
}
public enum CompactMenuMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case pinnedItems, firstSections, allItems
    public var id: String { rawValue }
}
public enum MenuBarTextStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case existing, iconOnly, remaining, elapsed, endTime, status
    public var id: String { rawValue }
}

public struct MenuLayoutGroup: Equatable, Identifiable, Sendable {
    public var section: MenuLayoutSection
    public var items: [MenuItem]
    public var id: MenuLayoutSection { section }
}

/// The custom layout is optional in KeepressoSettings. Its absence, or
/// customization being off, selects the standard menu.
public struct MenuLayout: Codable, Equatable, Sendable {
    public var sectionOrder: [MenuLayoutSection] = MenuLayoutSection.allCases
    public var itemOrder: [MenuItem] = MenuItem.allCases
    public var placements: [MenuItem: MenuLayoutSection] = [.triggerAction: .manualSession]
    public var hiddenSections: Set<MenuLayoutSection> = []
    public var hiddenItems: Set<MenuItem> = Self.balancedHiddenItems
    public var compactItems: Set<MenuItem> = [
        .statusHeader, .statusCaption, .otherApps, .manualToggle, .duration, .quickStop,
        .manualOverride, .triggerAction, .triggerRules, .leaseStatus, .fanStatus, .awdlStatus,
    ]
    public var collapsedSections: Set<MenuLayoutSection> = [.quickSettings, .presets, .toolsAndShortcuts, .help]
    public var compactMode: CompactMenuMode = .pinnedItems
    public var compactSectionCount: Int = 2
    public var showExpandToggle = true
    public var showSectionTitles = false
    public var showDividers = true
    public var density: MenuDensity = .comfortable
    public var headerStyle: MenuHeaderStyle = .card
    public var controlStyle: MenuControlStyle = .accent
    public var panelWidth: Int = Self.standardWidth
    public var adaptiveSessionControls = true
    public var showAgentDetails = true
    public var onlyActiveTriggers = false
    public var maxTriggerRows: Int = 5
    public var maxAgentRows: Int = 5
    public var showMenuBarIcon = true
    public var menuBarTextStyle: MenuBarTextStyle = .existing

    public static let widthRange = 240...480
    public static let standardWidth = 280
    public static let balancedHiddenItems: Set<MenuItem> = [
        .endTime, .triggerSummary, .systemSleep, .displaySleep, .keepActive,
        .screenSaverYield, .dimDisplay, .reminder, .endAction, .presets, .triggersToggle, .customize,
    ]

    public init() {}

    public static func profile(_ profile: MenuLayoutProfile) -> Self {
        var layout = Self()
        switch profile {
        case .balanced: break
        case .minimal, .compact:
            var visible: Set<MenuItem> = [.statusHeader, .manualToggle, .duration, .manualOverride, .triggerAction]
            if profile == .compact { visible.formUnion([.statusCaption, .quickStop]) }
            layout.hiddenItems = Set(MenuItem.allCases).subtracting(visible)
            layout.compactItems = visible
            layout.showExpandToggle = false
            layout.showDividers = false
            layout.density = .compact
            layout.headerStyle = .compact
        case .lidControls, .brewingControls:
            layout = .profile(.compact)
            let item: MenuItem = profile == .lidControls ? .closedDisplay : .brewingOnly
            layout.hiddenItems.remove(item)
            layout.compactItems.insert(item)
            layout.placements[item] = .manualSession
        case .statusOnly:
            let visible: Set<MenuItem> = [.statusHeader, .statusCaption, .endTime, .otherApps,
                                        .leaseStatus, .fanStatus, .awdlStatus]
            layout.hiddenItems = Set(MenuItem.allCases).subtracting(visible)
            layout.compactItems = visible
            layout.showExpandToggle = false
            layout.showDividers = false
            layout.density = .compact
            layout.headerStyle = .compact
        case .detailed:
            layout.hiddenItems = []
            layout.compactItems = Set(MenuItem.allCases)
            layout.collapsedSections.formUnion([.triggers, .appShortcuts])
            layout.maxTriggerRows = 5
            layout.maxAgentRows = 3
        }
        return layout
    }

    public var isStatusOnly: Bool {
        let statuses: Set<MenuItem> = [.statusHeader, .statusCaption, .endTime, .otherApps,
                                      .triggerSummary, .triggerRules, .leaseStatus, .fanStatus, .awdlStatus]
        let items = Set(groups(expanded: true).flatMap(\.items))
        return !items.isEmpty && items.isSubset(of: statuses)
    }

    public func placement(of item: MenuItem) -> MenuLayoutSection {
        placements[item] ?? item.defaultSection
    }
    public func items(in section: MenuLayoutSection) -> [MenuItem] {
        normalizedOrder(itemOrder, defaults: MenuItem.allCases).filter { placement(of: $0) == section }
    }

    /// Availability is supplied by the host, so empty runtime-only groups do
    /// not consume the user's compact-section budget or leave stray dividers.
    public func groups(expanded: Bool, available: Set<MenuItem> = Set(MenuItem.allCases)) -> [MenuLayoutGroup] {
        let normalized = normalized()
        var groups = normalized.sectionOrder.compactMap { section -> MenuLayoutGroup? in
            guard !normalized.hiddenSections.contains(section) else { return nil }
            var items = normalized.items(in: section).filter {
                !normalized.hiddenItems.contains($0) && available.contains($0)
            }
            if !expanded && normalized.showExpandToggle && normalized.compactMode == .pinnedItems {
                items = items.filter(normalized.compactItems.contains)
            }
            return items.isEmpty ? nil : MenuLayoutGroup(section: section, items: items)
        }
        if !expanded && normalized.showExpandToggle && normalized.compactMode == .firstSections {
            groups = Array(groups.prefix(normalized.compactSectionCount))
        }
        return groups
    }

    public mutating func moveSection(_ section: MenuLayoutSection, by offset: Int) {
        sectionOrder = normalizedOrder(sectionOrder, defaults: MenuLayoutSection.allCases)
        move(section, in: &sectionOrder, by: offset)
    }
    public mutating func moveItem(_ item: MenuItem, by offset: Int) {
        itemOrder = normalizedOrder(itemOrder, defaults: MenuItem.allCases)
        let siblings = items(in: placement(of: item))
        guard let index = siblings.firstIndex(of: item), [-1, 1].contains(offset),
              siblings.indices.contains(index + offset),
              let source = itemOrder.firstIndex(of: item),
              let destination = itemOrder.firstIndex(of: siblings[index + offset]) else { return }
        itemOrder.swapAt(source, destination)
    }
    public mutating func moveItem(_ item: MenuItem, to section: MenuLayoutSection) {
        placements[item] = section
        itemOrder.removeAll { $0 == item }
        itemOrder.append(item)
    }

    public func normalized() -> Self {
        var copy = self
        copy.sectionOrder = normalizedOrder(sectionOrder, defaults: MenuLayoutSection.allCases)
        copy.itemOrder = normalizedOrder(itemOrder, defaults: MenuItem.allCases)
        copy.panelWidth = min(max(panelWidth, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        copy.compactSectionCount = min(max(compactSectionCount, 1), MenuLayoutSection.allCases.count)
        copy.maxTriggerRows = min(max(maxTriggerRows, 1), 50)
        copy.maxAgentRows = min(max(maxAgentRows, 1), 20)
        // Text-only labels need an idle fallback. Existing/hidden text cannot
        // be the sole carrier, or the menu-bar entry disappears while idle.
        if !showMenuBarIcon && [.existing, .iconOnly].contains(menuBarTextStyle) {
            copy.showMenuBarIcon = true
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case sectionOrder, itemOrder, placements, hiddenSections, hiddenItems, compactItems, collapsedSections
        case compactMode, compactSectionCount, showExpandToggle, showSectionTitles, showDividers
        case density, headerStyle, controlStyle, panelWidth, adaptiveSessionControls, showAgentDetails, onlyActiveTriggers, maxTriggerRows, maxAgentRows
        case showMenuBarIcon, menuBarTextStyle
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func strings(_ key: CodingKeys) -> [String]? { try? c.decode([String].self, forKey: key) }
        if let values = strings(.sectionOrder) { sectionOrder = values.compactMap(MenuLayoutSection.init(rawValue:)) }
        if let values = strings(.itemOrder) { itemOrder = values.compactMap(MenuItem.init(rawValue:)) }
        if let values = try? c.decode([String: String].self, forKey: .placements) {
            placements = Dictionary(uniqueKeysWithValues: values.compactMap { item, section in
                guard let item = MenuItem(rawValue: item), let section = MenuLayoutSection(rawValue: section) else { return nil }
                return (item, section)
            })
        }
        if let values = strings(.hiddenSections) { hiddenSections = Set(values.compactMap(MenuLayoutSection.init(rawValue:))) }
        if let values = strings(.hiddenItems) { hiddenItems = Set(values.compactMap(MenuItem.init(rawValue:))) }
        if let values = strings(.compactItems) { compactItems = Set(values.compactMap(MenuItem.init(rawValue:))) }
        if let values = strings(.collapsedSections) { collapsedSections = Set(values.compactMap(MenuLayoutSection.init(rawValue:))) }
        func raw<T: RawRepresentable>(_ key: CodingKeys, default value: T) -> T where T.RawValue == String {
            (try? c.decode(String.self, forKey: key)).flatMap(T.init(rawValue:)) ?? value
        }
        compactMode = raw(.compactMode, default: compactMode)
        density = raw(.density, default: density)
        headerStyle = raw(.headerStyle, default: headerStyle)
        controlStyle = raw(.controlStyle, default: controlStyle)
        menuBarTextStyle = raw(.menuBarTextStyle, default: menuBarTextStyle)
        compactSectionCount = (try? c.decode(Int.self, forKey: .compactSectionCount)) ?? compactSectionCount
        panelWidth = (try? c.decode(Int.self, forKey: .panelWidth)) ?? panelWidth
        // Existing granular layouts retain their independently visible controls.
        adaptiveSessionControls = (try? c.decode(Bool.self, forKey: .adaptiveSessionControls)) ?? false
        maxTriggerRows = (try? c.decode(Int.self, forKey: .maxTriggerRows)) ?? maxTriggerRows
        maxAgentRows = (try? c.decode(Int.self, forKey: .maxAgentRows)) ?? maxAgentRows
        showExpandToggle = (try? c.decode(Bool.self, forKey: .showExpandToggle)) ?? showExpandToggle
        showSectionTitles = (try? c.decode(Bool.self, forKey: .showSectionTitles)) ?? showSectionTitles
        showDividers = (try? c.decode(Bool.self, forKey: .showDividers)) ?? showDividers
        showAgentDetails = (try? c.decode(Bool.self, forKey: .showAgentDetails)) ?? showAgentDetails
        onlyActiveTriggers = (try? c.decode(Bool.self, forKey: .onlyActiveTriggers)) ?? onlyActiveTriggers
        showMenuBarIcon = (try? c.decode(Bool.self, forKey: .showMenuBarIcon)) ?? showMenuBarIcon
        self = normalized()
    }
    public func encode(to encoder: Encoder) throws {
        let value = normalized()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value.sectionOrder.map(\.rawValue), forKey: .sectionOrder)
        try c.encode(value.itemOrder.map(\.rawValue), forKey: .itemOrder)
        try c.encode(Dictionary(uniqueKeysWithValues: value.placements.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .placements)
        try c.encode(value.hiddenSections.map(\.rawValue).sorted(), forKey: .hiddenSections)
        try c.encode(value.hiddenItems.map(\.rawValue).sorted(), forKey: .hiddenItems)
        try c.encode(value.compactItems.map(\.rawValue).sorted(), forKey: .compactItems)
        try c.encode(value.collapsedSections.map(\.rawValue).sorted(), forKey: .collapsedSections)
        try c.encode(value.compactMode, forKey: .compactMode)
        try c.encode(value.compactSectionCount, forKey: .compactSectionCount)
        try c.encode(value.showExpandToggle, forKey: .showExpandToggle)
        try c.encode(value.showSectionTitles, forKey: .showSectionTitles)
        try c.encode(value.showDividers, forKey: .showDividers)
        try c.encode(value.density, forKey: .density)
        try c.encode(value.headerStyle, forKey: .headerStyle)
        try c.encode(value.controlStyle, forKey: .controlStyle)
        try c.encode(value.panelWidth, forKey: .panelWidth)
        try c.encode(value.adaptiveSessionControls, forKey: .adaptiveSessionControls)
        try c.encode(value.showAgentDetails, forKey: .showAgentDetails)
        try c.encode(value.onlyActiveTriggers, forKey: .onlyActiveTriggers)
        try c.encode(value.maxTriggerRows, forKey: .maxTriggerRows)
        try c.encode(value.maxAgentRows, forKey: .maxAgentRows)
        try c.encode(value.showMenuBarIcon, forKey: .showMenuBarIcon)
        try c.encode(value.menuBarTextStyle, forKey: .menuBarTextStyle)
    }
}

private func normalizedOrder<T: Hashable>(_ order: [T], defaults: [T]) -> [T] {
    var seen = Set<T>()
    return (order + defaults).filter { seen.insert($0).inserted }
}
private func move<T: Equatable>(_ item: T, in order: inout [T], by offset: Int) {
    guard [-1, 1].contains(offset), let source = order.firstIndex(of: item),
          order.indices.contains(source + offset) else { return }
    order.swapAt(source, source + offset)
}
