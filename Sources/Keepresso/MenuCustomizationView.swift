import SwiftUI
import KeepressoCore

extension MenuLayoutSection {
    var label: String {
        switch self {
        case .status: L("Status")
        case .otherApps: L("Other apps")
        case .triggers: L("Triggers")
        case .manualSession: L("Manual session")
        case .quickSettings: L("Quick settings")
        case .activity: L("Activity")
        case .presets: L("Presets")
        case .toolsAndShortcuts: L("Tools & shortcuts")
        case .appShortcuts: L("App shortcuts")
        case .help: L("Help")
        }
    }
}
extension MenuItem {
    var label: String {
        switch self {
        case .statusHeader: L("Status header")
        case .statusCaption: L("Status explanation")
        case .endTime: L("End time")
        case .otherApps: L("Other apps")
        case .manualToggle: L("Keep awake")
        case .duration: L("For")
        case .quickStop: L("Stop in")
        case .manualOverride: L("Manual session")
        case .triggersToggle: L("Activate by triggers")
        case .triggerAction: L("Pause / Resume Triggers")
        case .triggerSummary: L("Trigger summary")
        case .triggerRules: L("Trigger conditions")
        case .systemSleep: L("Prevent system sleep")
        case .displaySleep: L("Prevent display sleep")
        case .keepActive: L("Keep me active")
        case .screenSaverYield: L("Allow screen saver after")
        case .dimDisplay: L("Dim after idle")
        case .closedDisplay: L("Closed-display mode")
        case .brewingOnly: L("Only while brewing")
        case .lidPolicy: L("If the lid shuts")
        case .batteryPause: L("Pause on low battery")
        case .batteryThreshold: L("Battery threshold")
        case .reminder: L("Reminder")
        case .endAction: L("End action")
        case .leaseStatus: L("Automation leases")
        case .fanStatus: L("Fans")
        case .awdlStatus: L("AWDL")
        case .presets: L("Presets")
        case .setup: L("Headless Setup…")
        case .gaming: L("Gaming & Streaming…")
        case .keyboard: L("Keyboard Cleaner…")
        case .wifi: L("Public Wi-Fi…")
        case .preferences: L("Preferences…")
        case .customize: L("Customize Menu…")
        case .welcome: L("Welcome to Keepresso…")
        case .about: L("About Keepresso")
        case .updates: L("Check for Updates…")
        case .support: L("Support Keepresso…")
        case .quit: L("Quit Keepresso")
        }
    }
}
extension MenuLayoutProfile {
    var label: String {
        switch self {
        case .minimal: L("Minimal")
        case .compact: L("Compact")
        case .balanced: L("Balanced")
        case .lidControls: L("Lid controls")
        case .brewingControls: L("Brewing controls")
        case .statusOnly: L("Status only")
        case .detailed: L("Detailed")
        }
    }
}
extension MenuDensity {
    var label: String {
        switch self { case .compact: L("Compact"); case .comfortable: L("Comfortable"); case .spacious: L("Spacious") }
    }
}
extension MenuHeaderStyle {
    var label: String {
        switch self { case .card: L("Card"); case .compact: L("Compact"); case .text: L("Text only") }
    }
}
extension MenuControlStyle {
    var label: String {
        switch self { case .accent: L("Accent color"); case .clear: L("Clear style") }
    }
}
extension CompactMenuMode {
    var label: String {
        switch self {
        case .pinnedItems: L("Pinned controls")
        case .firstSections: L("First sections")
        case .allItems: L("All visible controls")
        }
    }
}
extension MenuBarTextStyle {
    var label: String {
        switch self {
        case .existing: L("Follow countdown setting")
        case .iconOnly: L("Icon only")
        case .remaining: L("Remaining time")
        case .elapsed: L("Elapsed time")
        case .endTime: L("End time")
        case .status: L("Status")
        }
    }
}

/// Presentation edits stay separate from the session and feature settings.
/// The default experience can always be restored without deleting this layout.
struct MenuCustomizationView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var expandedEditors: Set<MenuLayoutSection> = []
    private enum EditorTab { case controls, appearance, details }
    @State private var editorTab = EditorTab.controls
    @State private var previewExpanded = true
    @State private var previewUnavailable = false
    @State private var previewBridge = StatusItemBridge(updater: MenuPreviewUpdater())
    @State private var windowVisible = false
    private var layout: MenuLayout { model.editableMenuLayout }

    private func binding<T>(_ keyPath: WritableKeyPath<MenuLayout, T>) -> Binding<T> {
        Binding(get: { layout[keyPath: keyPath] }, set: { value in
            model.updateMenuLayout { $0[keyPath: keyPath] = value }
        })
    }
    private func membership<T: Hashable>(
        _ value: T, in keyPath: WritableKeyPath<MenuLayout, Set<T>>, inverted: Bool = false
    ) -> Binding<Bool> {
        Binding(get: { layout[keyPath: keyPath].contains(value) != inverted }, set: { enabled in
            model.updateMenuLayout {
                if enabled != inverted { $0[keyPath: keyPath].insert(value) }
                else { $0[keyPath: keyPath].remove(value) }
            }
        })
    }

    var body: some View {
        Group {
            if windowVisible { editor }
            else { Color.clear }
        }
        .frame(minWidth: 860, idealWidth: 940, minHeight: 560, idealHeight: 800)
        .glassWindowBackground()
        .background(WindowVisibilityReader(isVisible: $windowVisible))
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Customize menu sections", isOn: Binding(
                    get: { model.menuCustomizationEnabled }, set: { model.menuCustomizationEnabled = $0 }
                ))
                .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button("Use standard menu") { model.menuCustomizationEnabled = false }
                    .disabled(!model.menuCustomizationEnabled)
            }
            .padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Form {
                        Section {
                            Menu {
                                ForEach(MenuLayoutProfile.allCases) { profile in
                                    Button(profile.label) { model.updateMenuLayout { $0 = .profile(profile) } }
                                }
                            } label: {
                                Label(currentProfile?.label ?? L("Custom"), systemImage: "square.grid.2x2")
                            }
                            Text(currentProfile?.summary ?? L("These choices change the menu, while your feature settings stay the same."))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } header: { Text("Starting layout") }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .scrollContentBackground(.hidden)
                    .frame(height: 150)
                    .disabled(!model.menuCustomizationEnabled)
                    Picker("Customize Menu", selection: $editorTab) {
                        Text("Controls").tag(EditorTab.controls)
                        Text("Appearance").tag(EditorTab.appearance)
                        Text("Details").tag(EditorTab.details)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 20)
                    settingsEditor
                    HStack {
                        Button("Reset customization") { model.updateMenuLayout { $0 = MenuLayout() } }
                            .disabled(!model.menuCustomizationEnabled)
                        Spacer()
                        InfoButton(text: L("Warnings stay visible. Preferences and Quit are also available by right-clicking the cup."))
                    }.padding(20)
                }
                .frame(minWidth: 360, maxWidth: 440)
                Divider()
                previewPane
            }
        }
        .tint(.keepressoBrew)
    }

    private var currentProfile: MenuLayoutProfile? {
        MenuLayoutProfile.allCases.first { MenuLayout.profile($0) == layout }
    }

    private var settingsEditor: some View {
        Form {
            if !model.menuCustomizationEnabled {
                Section { Text("Enable customization to edit the menu.").foregroundStyle(.secondary) }
            } else {
                switch editorTab {
                case .controls:
                    Section {
                        TextField("Find controls", text: $search)
                        Text("Show, hide, pin, reorder, or move any control to another section.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(layout.sectionOrder.filter(sectionMatchesSearch)) { section in sectionEditor(section) }
                case .appearance:
                    appearanceEditor
                case .details:
                    detailsEditor
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var appearanceEditor: some View {
        Group {
            Section {
                Picker("Control style", selection: binding(\.controlStyle)) {
                    ForEach(MenuControlStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Spacing", selection: binding(\.density)) {
                    ForEach(MenuDensity.allCases) { Text($0.label).tag($0) }
                }
                Picker("Status header", selection: binding(\.headerStyle)) {
                    ForEach(MenuHeaderStyle.allCases) { Text($0.label).tag($0) }
                }
                Stepper(L("Panel width: %d pt", layout.panelWidth), value: binding(\.panelWidth), in: MenuLayout.widthRange, step: 20)
                Button("Standard width") { model.updateMenuLayout { $0.panelWidth = MenuLayout.standardWidth } }
                Toggle("Show section headings", isOn: binding(\.showSectionTitles))
                Toggle("Show section dividers", isOn: binding(\.showDividers))
                Toggle("Show more / Show less", isOn: binding(\.showExpandToggle))
            } header: { Text("Appearance") }
            Section {
                Picker("Show less", selection: binding(\.compactMode)) {
                    ForEach(CompactMenuMode.allCases) { Text($0.label).tag($0) }
                }
                if layout.compactMode == .firstSections {
                    Stepper(L("Sections: %d", layout.compactSectionCount), value: binding(\.compactSectionCount), in: 1...MenuLayoutSection.allCases.count)
                }
                Text("Pin controls to keep them visible in Show less.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Compact menu") }
            Section {
                Picker("Menu bar", selection: binding(\.menuBarTextStyle)) {
                    ForEach(MenuBarTextStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show cup icon", isOn: binding(\.showMenuBarIcon))
                    .disabled([.existing, .iconOnly].contains(layout.menuBarTextStyle))
            } header: { Text("Menu bar") }
        }
    }

    private var detailsEditor: some View {
        Section {
            Toggle("Adapt controls to manual or trigger sessions", isOn: binding(\.adaptiveSessionControls))
            Toggle("Show agent details", isOn: binding(\.showAgentDetails))
            Toggle("Only show matching triggers", isOn: binding(\.onlyActiveTriggers))
            Stepper(L("Trigger rows: %d", layout.maxTriggerRows), value: binding(\.maxTriggerRows), in: 1...50)
            Stepper(L("Agent rows: %d", layout.maxAgentRows), value: binding(\.maxAgentRows), in: 1...20)
        } header: { Text("Details") }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                Label("Live", systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Preview", selection: $previewExpanded) {
                Text("Show more").tag(true)
                Text("Show less").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.advancedMenuLayout?.showExpandToggle == false)
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 16) {
                        MenuBarLabel(session: model.session, showCountdown: model.showCountdownInMenuBar,
                                     presentation: model.advancedMenuLayout)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                            .allowsHitTesting(false)
                        MenuBarContent(model: model, updater: MenuPreviewUpdater(), bridge: previewBridge,
                                       preview: MenuPreviewConfiguration(
                                        layout: model.advancedMenuLayout, expanded: previewExpanded,
                                        useCustomSections: model.usesCustomMenuSections,
                                        includesUnavailableItems: previewUnavailable,
                                        maxHeight: max(200, geometry.size.height - 90)))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                    }
                    .padding(18)
                    .frame(minWidth: geometry.size.width, alignment: .top)
                }
            }
            Toggle("Show inactive controls", isOn: $previewUnavailable)
                .font(.caption).disabled(model.advancedMenuLayout == nil)
            Text("Preview only. Controls do not change your session.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35))
        .onAppear { previewExpanded = model.menuPanelExpanded }
    }

    private func matches(_ item: MenuItem) -> Bool {
        search.isEmpty || item.label.localizedCaseInsensitiveContains(search)
    }
    private func sectionMatchesSearch(_ section: MenuLayoutSection) -> Bool {
        search.isEmpty || section.label.localizedCaseInsensitiveContains(search)
            || layout.items(in: section).contains(where: matches)
    }

    @ViewBuilder private func sectionEditor(_ section: MenuLayoutSection) -> some View {
        Section {
            HStack {
                Toggle(section.label, isOn: membership(section, in: \.hiddenSections, inverted: true))
                Spacer()
                moveButton(up: true, label: section.label, disabled: layout.sectionOrder.first == section) {
                    model.updateMenuLayout { $0.moveSection(section, by: -1) }
                }
                moveButton(up: false, label: section.label, disabled: layout.sectionOrder.last == section) {
                    model.updateMenuLayout { $0.moveSection(section, by: 1) }
                }
            }
            DisclosureGroup(isExpanded: Binding(
                get: { !search.isEmpty || expandedEditors.contains(section) },
                set: { if $0 { expandedEditors.insert(section) } else { expandedEditors.remove(section) } }
            )) {
                Toggle("Start collapsed", isOn: membership(section, in: \.collapsedSections))
                ForEach(layout.items(in: section).filter {
                    search.isEmpty || section.label.localizedCaseInsensitiveContains(search) || matches($0)
                }) { item in itemEditor(item) }
            } label: { Text("Controls") }
        }
    }

    @ViewBuilder private func itemEditor(_ item: MenuItem) -> some View {
        let siblings = layout.items(in: layout.placement(of: item))
        HStack(spacing: 8) {
            Toggle(item.label, isOn: membership(item, in: \.hiddenItems, inverted: true))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.updateMenuLayout {
                    if !$0.compactItems.insert(item).inserted { $0.compactItems.remove(item) }
                }
            } label: {
                Image(systemName: layout.compactItems.contains(item) ? "pin.fill" : "pin")
            }
            .accessibilityLabel("\(L("Keep in Show less")): \(item.label)")
            .help(L("Keep in Show less"))
            moveButton(up: true, label: item.label, disabled: siblings.first == item) {
                model.updateMenuLayout { $0.moveItem(item, by: -1) }
            }
            moveButton(up: false, label: item.label, disabled: siblings.last == item) {
                model.updateMenuLayout { $0.moveItem(item, by: 1) }
            }
            Menu {
                ForEach(MenuLayoutSection.allCases) { section in
                    Button(section.label) { model.updateMenuLayout { $0.moveItem(item, to: section) } }
                        .disabled(section == layout.placement(of: item))
                }
            } label: { Image(systemName: "arrowshape.turn.up.right") }
            .accessibilityLabel("\(L("Move to section")): \(item.label)")
            .help(L("Move to section"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func moveButton(up: Bool, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: up ? "chevron.up" : "chevron.down") }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(L(up ? "Move up" : "Move down")): \(label)")
            .disabled(disabled)
    }
}

extension MenuLayoutProfile {
    var summary: String {
        switch self {
        case .minimal: L("Just the session controls. Manual timers or trigger controls, at the standard width.")
        case .compact: L("A small session menu with status and quick timers.")
        case .balanced: L("The familiar menu, with settings and tools tucked away.")
        case .lidControls: L("A compact session menu with the closed-display switch.")
        case .brewingControls: L("A compact session menu with Only while brewing.")
        case .statusOnly: L("Status and activity only, without session buttons.")
        case .detailed: L("All controls available. Settings, conditions, and shortcuts start collapsed.")
        }
    }
}

private struct MenuPreviewUpdater: Updating {
    var canCheckForUpdates: Bool { true }
    func checkForUpdates() {}
}
