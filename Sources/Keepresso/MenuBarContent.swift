import SwiftUI
import AppKit
import KeepressoCore
import Combine

struct MenuPreviewConfiguration {
    var layout: MenuLayout?
    var expanded: Bool
    var includesUnavailableItems = false
    var maxHeight: CGFloat = 480
}

struct MenuBarContent: View {
    @Bindable var model: AppModel

    let updater: any Updating

    let bridge: StatusItemBridge
    var preview: MenuPreviewConfiguration? = nil

    @Environment(\.openWindow) private var openWindow

    private var session: SessionController { model.session }

    private var panel: MenuPanelSnapshot { model.menuPanel }

    private var type: ScaledType { ScaledType() }
    private var advancedMenuLayout: MenuLayout? {
        if let preview { return preview.layout }
        return model.advancedMenuLayout
    }
    private var menuExpanded: Bool { preview?.expanded ?? model.menuPanelExpanded }

    /// Whether the panel is actually on screen. The closed panel keeps this
    /// view alive on current macOS, so the heavy body unmounts while false
    /// (stops Observation-graph growth and TimelineView CPU) and remounts
    /// when the menu opens again.
    @State private var panelVisible = true
    @State private var lidRowShakes = 0
    @State private var showCustomDuration = false
    @State private var showUntilTime = false
    @State private var toolsExpanded = false
    @State private var helpExpanded = false
    @State private var advancedDurationItem: MenuItem?
    @State private var advancedUntilItem: MenuItem?
    @State private var advancedContentHeight: CGFloat?
    @State private var previewTick = 0
    /// Held in state so each body pass reuses one timer. A publisher built in
    /// `body` is replaced on every re-render, which restarts its countdown.
    /// Autoconnect only starts it for the preview, the one subscriber.
    @State private var previewTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var previewCollapsedSections: Set<MenuLayoutSection>?
    @State private var disclosedSections: Set<MenuLayoutSection> = []

    private static let durationOptions: [(label: String, mode: SessionMode)] = [
        ("Indefinitely", .indefinite),
        ("15 minutes", .timed(duration: 15 * 60)),
        ("1 hour", .timed(duration: 60 * 60)),
        ("4 hours", .timed(duration: 4 * 60 * 60)),
    ]

    static func modeLabel(_ mode: SessionMode) -> String {
        if let preset = durationOptions.first(where: { $0.mode == mode }) { return L(preset.label) }
        guard let duration = mode.duration else { return L("Indefinitely") }
        return shortDuration(duration)
    }

    static func shortDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = wholeMinutes(duration)
        let hours = totalMinutes / 60, minutes = totalMinutes % 60
        if hours > 0 && minutes > 0 { return L("%d h %d min", hours, minutes) }
        if hours > 0 { return L("%d h", hours) }
        return L("%d min", max(1, minutes))
    }

    static func wholeMinutes(_ duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        let capped = min(duration, SessionMode.maxTimedMinutes * 60)
        return Int((capped / 60).rounded())
    }

    static func graceCountdown(_ seconds: TimeInterval) -> String {
        // Saturate at a day rather than trap: `Int(_:)` faults past Int.max.
        let capped = seconds.isFinite ? min(max(0, seconds), 86_400) : 0
        let s = Int(capped.rounded(.up))
        if s >= 60 { return L("%d:%02d", s / 60, s % 60) }
        return L("%ds", s)
    }

    var body: some View {
        let _ = previewTick
        Group {
            if preview != nil {
                panelBody
                    .onReceive(previewTimer) { _ in previewTick &+= 1 }
                    .onChange(of: advancedMenuLayout?.collapsedSections) { _, _ in previewCollapsedSections = nil }
            } else {
                livePanel
            }
        }
    }

    private var livePanel: some View {
        // Tear the heavy body down while ordered out. A closed MenuBarExtra
        // panel keeps this shell alive; leaving the full tree mounted would
        // keep observing SessionController / MenuPanelSnapshot every reconcile
        // and grow the Observation graph without bound (and leave steam/spark
        // TimelineViews ticking). The visibility probe stays mounted outside
        // the `if` so reopen can remount the body.
        Group {
            if panelVisible {
                panelBody
            } else {
                Color.clear
                    .frame(width: CGFloat(advancedMenuLayout?.panelWidth ?? MenuLayout.standardWidth) * type.scale, height: 1)
            }
        }
        .keepsPanelKey()
        .background(PanelWindowRegistrar { bridge.panelWindow = $0 })
        .background(WindowVisibilityReader(isVisible: $panelVisible))
        .onChange(of: panelVisible) { _, visible in
            model.menuPanelVisible = visible
            guard visible else { return }
            model.pulseMenuPanelIfVisible()
            model.refreshClosedDisplay()
        }
    }

    @ViewBuilder
    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if updater.updateAvailable {
                Button("Update available…", systemImage: "arrow.down.circle") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
                .buttonStyle(.menuRow)
                Divider()
            }
            if let layout = advancedMenuLayout {
                advancedPanel(layout)
            } else {
                originalPanel
            }
        }
        .padding(14)
        .frame(width: CGFloat(advancedMenuLayout?.panelWidth ?? MenuLayout.standardWidth) * type.scale)
        .animation(.snappy(duration: 0.25), value: session.isActive)
        .animation(.snappy(duration: 0.25), value: model.triggersEnabled)
        .animation(.snappy(duration: 0.25), value: model.triggersPaused)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayEnabled)
        .animation(.snappy(duration: 0.25), value: model.closedLidDisplayPolicy)
        .animation(.snappy(duration: 0.25), value: model.batteryAutoPauseEnabled)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayError)
        .animation(.snappy(duration: 0.25), value: model.helperAttention)
        .animation(.snappy(duration: 0.25), value: model.menuPanelExpanded)
        .animation(.snappy(duration: 0.25), value: model.menuCustomizationEnabled)
        .glassPanelBackground(brewing: session.isActive)
        .tint(.keepressoBrew)
        .font(type.body)
        .onAppear {
            guard preview == nil else { return }
            model.menuPanelVisible = true
            model.pulseMenuPanelIfVisible()
            model.refreshClosedDisplay()
        }
    }

    @ViewBuilder
    private var originalPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.helperAttention != nil {
                helperAttentionBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            heldByLine

            standardMenuSections

            expandToggleRow
        }
        .disabled(preview != nil)
        .allowsHitTesting(preview == nil)
    }


    private func availableMenuItems(_ layout: MenuLayout) -> Set<MenuItem> {
        if preview?.includesUnavailableItems == true { return Set(MenuItem.allCases) }
        let triggerControlled = model.triggersEnabled && !model.triggersPaused
        return Set(MenuItem.allCases.filter { item in
            switch item {
            case .manualToggle, .duration:
                return !layout.adaptiveSessionControls || !triggerControlled
            case .manualOverride:
                return !layout.adaptiveSessionControls
                    || (triggerControlled && layout.hiddenItems.contains(.triggerAction))
            case .endTime: return session.isActive && session.remaining != nil
            case .otherApps: return panel.heldBy != nil
            case .quickStop:
                return session.isActive && !session.isLeaseHeld
                    && !(model.triggersEnabled && !model.triggersPaused)
                    && !model.quickStopDurations.isEmpty
            case .triggerAction: return model.triggersEnabled || !session.liveLeases.isEmpty
            case .triggerSummary, .triggerRules: return model.triggersEnabled && !model.triggersPaused
            case .screenSaverYield: return session.options.preventDisplaySleep
            case .dimDisplay: return session.options.preventDisplaySleep && model.brightnessSupported
            case .lidPolicy: return model.machineHasBattery && (model.closedDisplayEnabled || model.closedDisplayOnlyWhileBrewing)
            case .batteryPause: return model.machineHasBattery
            case .batteryThreshold: return model.machineHasBattery && model.batteryAutoPauseEnabled
            case .leaseStatus:
                return !session.liveLeases.isEmpty
                    && (layout.hiddenItems.contains(.triggerAction)
                        || layout.collapsedSections.contains(layout.placement(of: .triggerAction)))
            case .fanStatus: return model.fanBoostActivePercent != nil
            case .awdlStatus: return model.awdlStatus.isPausing && AWDLStatusStyle(model.awdlStatus) != nil
            case .presets: return !model.presets.isEmpty
            default: return true
            }
        })
    }

    private func visibleItems(_ groups: [MenuLayoutGroup], layout: MenuLayout) -> Set<MenuItem> {
        let collapsed = preview != nil ? (previewCollapsedSections ?? layout.collapsedSections) : layout.collapsedSections
        return Set(groups.filter { !collapsed.contains($0.section) }.flatMap(\.items))
    }

    private func advancedPanel(_ layout: MenuLayout) -> some View {
        let groups = layout.groups(expanded: menuExpanded, available: availableMenuItems(layout))
        let visible = visibleItems(groups, layout: layout)
        let maxHeight = preview?.maxHeight ?? (max(250, (bridge.panelWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 100)
        return ScrollView {
            advancedSections(groups, layout: layout, visible: visible)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MenuContentHeight.self, value: geometry.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(advancedContentHeight ?? 280, maxHeight))
        .onPreferenceChange(MenuContentHeight.self) { height in
            if height > 0 && abs(height - (advancedContentHeight ?? 0)) > 0.5 {
                // Never animated: the panel window sizes itself from this
                // frame, and an animated resize interrupted by the next
                // change (flipping the mode switch quickly) can leave the
                // window stuck at a stale, taller size.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { advancedContentHeight = height }
            }
        }
        .background {
            if preview == nil && !visible.contains(.preferences) {
                Button("") { open(KeepressoApp.preferencesWindowID) }.menuShortcut(",", enabled: preview == nil).hidden()
            }
            if preview == nil && !visible.contains(.quit) {
                Button("") { NSApplication.shared.terminate(nil) }.menuShortcut("q", enabled: preview == nil).hidden()
            }
        }
    }

    private struct MenuContentHeight: PreferenceKey {
        static var defaultValue: CGFloat { 0 }
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    @ViewBuilder
    private func advancedSections(_ groups: [MenuLayoutGroup], layout: MenuLayout, visible: Set<MenuItem>) -> some View {
        let closedDisplayHidden = !visible.contains(.closedDisplay)
        let brewingOnlyHidden = !visible.contains(.brewingOnly)
        let combinesCaption = combinesStatusCaption(layout, groups: groups)
        let needsSleepStatus = (closedDisplayHidden
            && (model.closedDisplayEnabled || model.closedDisplayBusy || model.closedDisplayError != nil))
            || (brewingOnlyHidden && (model.closedDisplayAutoBusy || model.closedDisplayAutoError != nil))
        VStack(alignment: .leading, spacing: layout.density.spacing) {
            if model.helperAttention != nil { helperAttentionBanner.disabled(preview != nil) }
            if (session.pausedByBattery || session.pausedByThermal) && !visible.contains(.statusCaption) {
                Text(statusDetail).font(type.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(groups) { group in
                if layout.showDividers && group.id != groups.first?.id { Divider() }
                advancedGroup(group, layout: layout, combinesCaption: combinesCaption)
            }
            if needsSleepStatus {
                VStack(alignment: .leading, spacing: 6) {
                    if layout.showDividers { Divider().opacity(0.5) }
                    hiddenSleepStatus(closedDisplayHidden: closedDisplayHidden, brewingOnlyHidden: brewingOnlyHidden)
                }
                .padding(.top, layout.showDividers ? 0 : 4)
            }
            if model.triggersEnabled && model.triggersPaused && session.liveLeases.isEmpty
                && !visible.contains(.triggerAction)
                && !visible.isDisjoint(with: [.manualToggle, .duration, .manualOverride, .quickStop]) {
                modeSwitch.disabled(preview != nil)
            }
            if visible.isEmpty {
                Button("Customize Menu…") { open(KeepressoApp.menuCustomizationWindowID) }
                    .buttonStyle(.menuRow)
                    .disabled(preview != nil)
            }
            if layout.showExpandToggle { expandToggleRow.disabled(preview != nil) }
        }
    }

    @ViewBuilder
    private func advancedGroup(_ group: MenuLayoutGroup, layout: MenuLayout, combinesCaption: Bool) -> some View {
        let collapsed = (preview != nil ? (previewCollapsedSections ?? layout.collapsedSections) : layout.collapsedSections)
            .contains(group.section)
        VStack(alignment: .leading, spacing: group.section == .manualSession ? layout.density.spacing - 2 : layout.density.spacing) {
            if layout.showSectionTitles || collapsed || disclosedSections.contains(group.section)
                || [.toolsAndShortcuts, .help].contains(group.section) {
                Button {
                    disclosedSections.insert(group.section)
                    if preview != nil {
                        var sections = previewCollapsedSections ?? layout.collapsedSections
                        if !sections.insert(group.section).inserted { sections.remove(group.section) }
                        previewCollapsedSections = sections
                    } else {
                        model.updateMenuLayout {
                            if !$0.collapsedSections.insert(group.section).inserted {
                                $0.collapsedSections.remove(group.section)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(group.section.label).font(type.callout.weight(.medium))
                        Spacer()
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(type.caption2)
                    }
                }
                .buttonStyle(.menuRow)
                .foregroundStyle(.primary)
                .accessibilityValue(collapsed ? L("Show more") : L("Show less"))
            }
            if !collapsed {
                ForEach(group.items.contains(.triggerAction)
                    ? [.triggerAction] + group.items.filter { $0 != .triggerAction }
                    : group.items) { item in
                    advancedItem(item, layout: layout, combinesCaption: combinesCaption)
                        .modifier(CustomMenuControlStyle(item: item, style: layout.controlStyle))
                        .disabled(preview != nil).allowsHitTesting(preview == nil)
                }
            }
        }
    }

    @ViewBuilder
    private func advancedItem(_ item: MenuItem, layout: MenuLayout, combinesCaption: Bool) -> some View {
        let _ = preview == nil ? panel.tick : UInt(previewTick)
        switch item {
        case .statusHeader:
            if combinesCaption { header }
            else { advancedHeader(layout.headerStyle) }
        case .statusCaption:
            if !combinesCaption {
                Text(statusDetail).font(type.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .endTime:
            if let remaining = session.remaining {
                LabeledContent("End time", value: Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))
                    .font(type.caption)
            }
        case .otherApps: heldByLine
        case .manualToggle:
            switchRow("Keep awake", isOn: Binding(get: { session.isActive }, set: { _ in model.toggleManual() }))
        case .duration: advancedDurationControl(item, alwaysStart: false)
        case .manualOverride: advancedDurationControl(item, alwaysStart: true)
        case .quickStop:
            VStack(alignment: .leading, spacing: 6) {
                Text("Stop in")
                adaptiveQuickStopButtons
                    .tint(layout.controlStyle == .accent ? .keepressoBrew : .primary)
                    .foregroundStyle(layout.controlStyle == .accent ? Color.keepressoBrew : .primary)
            }
        case .triggersToggle:
            switchRow("Activate by triggers", isOn: Binding(get: { model.triggersEnabled }, set: { model.triggersEnabled = $0 }))
        case .triggerAction:
            VStack(spacing: layout.density.spacing) {
                if model.triggersEnabled { modeSwitch }
                leaseBanner
            }
        case .triggerSummary:
            Text(model.triggerSummary() ?? L("No conditions yet")).font(type.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .triggerRules: advancedTriggerRules(layout)
        case .systemSleep:
            switchRow("Prevent system sleep", isOn: optionBinding(\.preventSystemSleep))
        case .displaySleep:
            switchRow("Prevent display sleep", isOn: optionBinding(\.preventDisplaySleep))
        case .keepActive:
            switchRow("Keep me active", isOn: Binding(get: { model.simulateUserActivity }, set: { model.simulateUserActivity = $0 }))
        case .screenSaverYield:
            switchRow("Allow screen saver after", isOn: Binding(
                get: { session.options.allowScreenSaverAfter != nil },
                set: { on in model.updateOptions {
                    $0.allowScreenSaverAfter = on ? ($0.allowScreenSaverAfter ?? 5 * 60) : nil
                    if on { $0.dimDisplayAfter = nil }
                }}
            ))
            if let interval = session.options.allowScreenSaverAfter { Text(Self.shortDuration(interval)).font(type.caption).foregroundStyle(.secondary) }
        case .dimDisplay:
            switchRow("Dim the display when idle", isOn: Binding(
                get: { session.options.dimDisplayAfter != nil },
                set: { on in model.updateOptions {
                    $0.dimDisplayAfter = on ? ($0.dimDisplayAfter ?? 5 * 60) : nil
                    if on { $0.allowScreenSaverAfter = nil }
                }}
            ))
            if let interval = session.options.dimDisplayAfter { Text(Self.shortDuration(interval)).font(type.caption).foregroundStyle(.secondary) }
        case .closedDisplay: advancedClosedDisplay
        case .brewingOnly: advancedBrewingOnly
        case .lidPolicy:
            Picker("If the lid shuts", selection: Binding(get: { model.closedLidDisplayPolicy }, set: { model.closedLidDisplayPolicy = $0 })) {
                ForEach(ClosedLidDisplayPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.menu)
            Text(model.closedLidDisplayPolicy.explanation).font(type.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = model.displayDarkeningReason {
                Text(reason).font(type.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .batteryPause:
            switchRow("Pause on low battery", isOn: Binding(get: { model.batteryAutoPauseEnabled }, set: { model.batteryAutoPauseEnabled = $0 }))
        case .batteryThreshold:
            BatteryThresholdSlider(percent: Binding(get: { model.pauseBelowBatteryPercent }, set: { model.pauseBelowBatteryPercent = $0 }))
        case .reminder:
            switchRow("Reminder", isOn: Binding(get: { model.reminderEnabled }, set: { model.reminderEnabled = $0 }))
        case .endAction:
            Picker("After the last session ends", selection: Binding(get: { model.endAction }, set: { model.endAction = $0 })) {
                ForEach(SessionEndAction.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.menu)
        case .leaseStatus: leaseStatusLine
        case .fanStatus: fanStatusLine
        case .awdlStatus: awdlStatusLine
        case .presets:
            Menu("Presets") { ForEach(model.presets) { preset in Button(preset.displayName) { model.applyPreset(preset) } } }
        case .setup: Button("Headless Setup…") { open(KeepressoApp.setupWindowID) }.buttonStyle(.menuRow)
        case .gaming: Button("Gaming & Streaming…") { open(KeepressoApp.streamingWindowID) }.buttonStyle(.menuRow)
        case .keyboard: Button("Keyboard Cleaner…") { open(KeepressoApp.keyboardCleanerWindowID) }.buttonStyle(.menuRow)
        case .wifi: Button("Public Wi-Fi…") { open(KeepressoApp.wifiAssistantWindowID) }.buttonStyle(.menuRow)
        case .preferences:
            Button("Preferences…") { open(KeepressoApp.preferencesWindowID) }.menuShortcut(",", enabled: preview == nil).buttonStyle(.menuRow)
        case .customize:
            Button("Customize Menu…") { open(KeepressoApp.menuCustomizationWindowID) }.buttonStyle(.menuRow)
        case .welcome: Button("Welcome to Keepresso…") { open(KeepressoApp.welcomeWindowID) }.buttonStyle(.menuRow)
        case .about: Button("About Keepresso") { open(KeepressoApp.aboutWindowID) }.buttonStyle(.menuRow)
        case .updates:
            Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates).buttonStyle(.menuRow)
        case .support: Button("Support Keepresso…") { NSWorkspace.shared.open(AppInfo.donate) }.buttonStyle(.menuRow)
        case .quit: Button("Quit Keepresso") { NSApplication.shared.terminate(nil) }.menuShortcut("q", enabled: preview == nil).buttonStyle(.menuRow)
        }
    }

    private func combinesStatusCaption(_ layout: MenuLayout, groups: [MenuLayoutGroup]) -> Bool {
        guard layout.headerStyle == .card,
              layout.placement(of: .statusHeader) == layout.placement(of: .statusCaption) else { return false }
        let group = groups.first { $0.items.contains(.statusHeader) }
        guard let items = group?.items, let index = items.firstIndex(of: .statusHeader),
              items.indices.contains(index + 1) else { return false }
        return items[index + 1] == .statusCaption
    }

    @ViewBuilder
    private func hiddenSleepStatus(closedDisplayHidden: Bool, brewingOnlyHidden: Bool) -> some View {
        if closedDisplayHidden && model.closedDisplayEnabled {
            Text(model.machineHasBattery
                ? L("Stays awake on battery too; the display turns off when the lid closes. Turn it off before putting it in a bag.")
                : L("The Mac won't sleep at all until you turn this off. The display still sleeps as usual."))
                .font(type.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if (closedDisplayHidden && model.closedDisplayBusy) || (brewingOnlyHidden && model.closedDisplayAutoBusy) {
            AdminAuthNote(purpose: L("switch the sleep override with the session"))
        }
        if closedDisplayHidden, let error = model.closedDisplayError { HelperFeatureNotice(model: model, message: error).font(type.caption) }
        if brewingOnlyHidden, let error = model.closedDisplayAutoError { HelperFeatureNotice(model: model, message: error).font(type.caption) }
    }

    private func optionBinding(_ keyPath: WritableKeyPath<SleepPreventionOptions, Bool>) -> Binding<Bool> {
        Binding(get: { session.options[keyPath: keyPath] }, set: { value in model.updateOptions { $0[keyPath: keyPath] = value } })
    }

    private var advancedClosedDisplay: some View {
        VStack(alignment: .leading, spacing: 6) {
            switchRow(model.machineHasBattery ? "Keep awake with lid closed" : "Disable system sleep",
                      isOn: Binding(get: { model.closedDisplayEnabled }, set: { model.setClosedDisplay($0) }),
                      info: model.machineHasBattery
                        ? L("Keeps the Mac running with the lid shut and no external display. This flips a system setting that needs administrator rights: silent with the administrator helper installed (Preferences ▸ General), otherwise macOS asks for your password.")
                        : L("Stops the Mac from sleeping at all, even with no session running. This flips a system setting that needs administrator rights: silent with the administrator helper installed (Preferences ▸ General), otherwise macOS asks for your password."),
                      switchLocked: model.closedDisplayOnlyWhileBrewing, onLockedTap: { lidRowShakes += 1 })
                .disabled(model.closedDisplayBusy)
            if model.closedDisplayBusy {
                AdminAuthNote(purpose: model.machineHasBattery ? L("keep the Mac awake with the lid closed") : L("disable system sleep"))
            }
            if model.closedDisplayOnlyWhileBrewing {
                Text("Follows the session while \u{201C}Only while brewing\u{201D} is on.")
                    .font(type.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .shakes(on: lidRowShakes)
            }
            if model.closedDisplayEnabled {
                Text(model.machineHasBattery
                    ? L("Stays awake on battery too; the display turns off when the lid closes. Turn it off before putting it in a bag.")
                    : L("The Mac won't sleep at all until you turn this off. The display still sleeps as usual."))
                    .font(type.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.closedDisplayError { HelperFeatureNotice(model: model, message: error).font(type.caption) }
        }
    }

    private var advancedBrewingOnly: some View {
        VStack(alignment: .leading, spacing: 6) {
            switchRow("Only while brewing", isOn: Binding(get: { model.closedDisplayOnlyWhileBrewing }, set: { model.closedDisplayOnlyWhileBrewing = $0 }),
                      info: model.machineHasBattery
                        ? L("Turns closed-display mode on when a keep-awake session starts and off when it ends or Keepresso quits.")
                        : L("Turns the sleep override on when a keep-awake session starts and off when it ends or Keepresso quits."))
                .disabled(model.closedDisplayAutoBusy)
            if model.closedDisplayAutoBusy && !model.helperInstalled { AdminAuthNote(purpose: L("switch the sleep override with the session")) }
            if let error = model.closedDisplayAutoError { HelperFeatureNotice(model: model, message: error).font(type.caption) }
        }
    }

    private func advancedHeader(_ style: MenuHeaderStyle) -> some View {
        HStack(spacing: 10) {
            if style != .text {
                BrewingCupView(isActive: session.isActive, pausedLowBattery: session.pausedByBattery, scale: style == .card ? type.scale : type.scale * 0.8)
                    .frame(width: style == .card ? 36 : 24, height: style == .card ? 36 : 24)
                    .accessibilityHidden(true)
            }
            Text(session.pausedByBattery || session.pausedByThermal ? L("Paused") : (session.isActive ? L("Brewing") : L("Idle")))
                .font(style == .card ? type.headline : type.body.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(style == .card ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if style == .card { RoundedRectangle(cornerRadius: 12).fill(Color.keepressoBrew.opacity(session.isActive ? 0.08 : 0.03)) }
        }
        .modifier(ShakeEffect(animatableData: CGFloat(session.refusedStarts)))
        .animation(.easeInOut(duration: 0.45), value: session.refusedStarts)
    }

    private func advancedDurationControl(_ item: MenuItem, alwaysStart: Bool) -> some View {
        let mode = alwaysStart ? model.defaultMode : model.mode
        let label = alwaysStart ? L("Start manual session") : L("For")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Menu(Self.modeLabel(mode)) {
                ForEach(Array(Self.durationOptions.enumerated()), id: \.offset) { _, option in
                    Button(L(option.label)) { setAdvancedDuration(option.mode, alwaysStart: alwaysStart) }
                }
                Divider()
                Button("Custom Duration\u{2026}") { advancedDurationItem = item }
                Button("Until a Time\u{2026}") { advancedUntilItem = item }
            }
            .fixedSize()
            .accessibilityLabel(label)
            .accessibilityValue(Self.modeLabel(mode))
        }
        .frame(maxWidth: .infinity)
        .popover(isPresented: Binding(get: { advancedDurationItem == item }, set: { if !$0 { advancedDurationItem = nil } })) {
            CustomDurationEditor(initial: mode.duration ?? 60 * 60) {
                setAdvancedDuration(.timed(duration: $0), alwaysStart: alwaysStart)
            }
        }
        .popover(isPresented: Binding(get: { advancedUntilItem == item }, set: { if !$0 { advancedUntilItem = nil } })) {
            UntilTimeEditor(isActive: session.isActive) { model.startUntil(hour: $0, minute: $1) }
        }
    }

    private func setAdvancedDuration(_ mode: SessionMode, alwaysStart: Bool) {
        if alwaysStart || (model.triggersEnabled && !model.triggersPaused) { model.startManualOverride(mode: mode) }
        else { model.mode = mode }
    }

    @ViewBuilder
    private func advancedTriggerRules(_ layout: MenuLayout) -> some View {
        let states = (model.ruleStates() ?? []).filter { !layout.onlyActiveTriggers || $0.satisfied || $0.inGrace }
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(states.prefix(layout.maxTriggerRows).enumerated()), id: \.offset) { _, state in
                HStack(spacing: 6) {
                    Image(systemName: state.satisfied ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(state.inGrace ? Color.orange : (state.satisfied ? .green : .secondary))
                        .accessibilityLabel(state.inGrace ? L("Met, in grace period") : (state.satisfied ? L("Met") : L("Not met")))
                    Text(state.rule.label).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let remaining = state.graceRemaining { Text(Self.graceCountdown(remaining)).monospacedDigit().foregroundStyle(.orange) }
                }.font(type.caption)
                if layout.showAgentDetails && !state.details.isEmpty { ruleDetailRows(state.details, limit: layout.maxAgentRows) }
            }
            if states.count > layout.maxTriggerRows { Text(L("+%d more", states.count - layout.maxTriggerRows)).font(type.caption2).foregroundStyle(.secondary) }
            if states.isEmpty { Text(layout.onlyActiveTriggers ? L("No matching triggers") : L("No conditions yet")).font(type.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private var standardMenuSections: some View {
        Divider()

        if model.triggersEnabled {
            modeSwitch
        }

        leaseBanner

        if model.triggersEnabled && !model.triggersPaused {
            triggerSummary
                .transition(.opacity)
        } else {
            switchRow("Keep awake", isOn: Binding(
                get: { session.isActive },
                set: { _ in model.toggleManual() }
            ))

            LabeledContent("For") {
                Menu(Self.modeLabel(model.mode)) {
                    ForEach(Array(Self.durationOptions.enumerated()), id: \.offset) { _, option in
                        Button(L(option.label)) { model.mode = option.mode }
                    }
                    Divider()
                    Button("Custom Duration\u{2026}") { showCustomDuration = true }
                    Button("Until a Time\u{2026}") { showUntilTime = true }
                }
                .fixedSize()
            }
            .popover(isPresented: $showCustomDuration) {
                CustomDurationEditor(initial: model.mode.duration ?? 60 * 60) {
                    model.mode = .timed(duration: $0)
                }
            }
            .popover(isPresented: $showUntilTime) {
                UntilTimeEditor(isActive: session.isActive) { hour, minute in
                    model.startUntil(hour: hour, minute: minute)
                }
            }

            if session.isActive && !model.quickStopDurations.isEmpty {
                if quickStopButtonsFitInline {
                    LabeledContent("Stop in") { quickStopButtons }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stop in")
                        quickStopButtons
                    }
                }
            }

        }

        if menuExpanded {
            optionToggles
        }

        statusStack

        if menuExpanded {
            Divider()

            appEntries
        }
    }


    @ViewBuilder
    private var optionToggles: some View {
        Divider()
        quickSettings
    }

    @ViewBuilder
    private var quickSettings: some View {
        closedDisplayControls

        if model.machineHasBattery {
            switchRow("Pause on low battery", isOn: Binding(
                get: { model.batteryAutoPauseEnabled },
                set: { model.batteryAutoPauseEnabled = $0 }
            ), info: L("Lets the Mac sleep once battery charge drops below this level, even mid-session, so it doesn't run flat."))
            if model.batteryAutoPauseEnabled {
                BatteryThresholdSlider(percent: Binding(
                    get: { model.pauseBelowBatteryPercent },
                    set: { model.pauseBelowBatteryPercent = $0 }
                ))
            }
        }
    }

    @ViewBuilder
    private var closedDisplayControls: some View {
        switchRow(model.machineHasBattery ? "Keep awake with lid closed" : "Disable system sleep",
                  isOn: Binding(
            get: { model.closedDisplayEnabled },
            set: { model.setClosedDisplay($0) }
        ), info: model.machineHasBattery
            ? L("Keeps the Mac running with the lid shut and no external display. This flips a system setting that needs administrator rights: silent with the administrator helper installed (Preferences ▸ General), otherwise macOS asks for your password.")
            : L("Stops the Mac from sleeping at all, even with no session running. This flips a system setting that needs administrator rights: silent with the administrator helper installed (Preferences ▸ General), otherwise macOS asks for your password."),
                  switchLocked: model.closedDisplayOnlyWhileBrewing,
                  onLockedTap: { lidRowShakes += 1 })
        .disabled(model.closedDisplayBusy)
        if model.closedDisplayBusy {
            AdminAuthNote(purpose: model.machineHasBattery
                ? L("keep the Mac awake with the lid closed")
                : L("disable system sleep"))
        }
        if model.closedDisplayOnlyWhileBrewing {
            Text("Follows the session while \u{201C}Only while brewing\u{201D} is on.")
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .shakes(on: lidRowShakes)
        }
        if model.closedDisplayEnabled {
            Text(model.machineHasBattery
                ? L("Stays awake on battery too; the display turns off when the lid closes. Turn it off before putting it in a bag.")
                : L("The Mac won't sleep at all until you turn this off. The display still sleeps as usual."))
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.machineHasBattery && model.closedDisplayEnabled {
            Picker(L("If the lid shuts"), selection: Binding(
                get: { model.closedLidDisplayPolicy },
                set: { model.closedLidDisplayPolicy = $0 }
            )) {
                ForEach(ClosedLidDisplayPolicy.allCases, id: \.self) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .pickerStyle(.menu)
            Text(model.closedLidDisplayPolicy.explanation)
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = model.displayDarkeningReason {
                Text(reason)
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let error = model.closedDisplayError {
            HelperFeatureNotice(model: model, message: error)
                .font(type.caption)
                .fixedSize(horizontal: false, vertical: true)
        }

        switchRow("Only while brewing", isOn: Binding(
            get: { model.closedDisplayOnlyWhileBrewing },
            set: { model.closedDisplayOnlyWhileBrewing = $0 }
        ), info: model.machineHasBattery
            ? L("Turns closed-display mode on when a keep-awake session starts and off when it ends or Keepresso quits.")
            : L("Turns the sleep override on when a keep-awake session starts and off when it ends or Keepresso quits."))
        .disabled(model.closedDisplayAutoBusy)
        if model.closedDisplayAutoBusy && !model.helperInstalled {
            AdminAuthNote(purpose: model.machineHasBattery
                ? L("switch closed-display mode with the session")
                : L("switch the sleep override with the session"))
        }
        if let error = model.closedDisplayAutoError {
            HelperFeatureNotice(model: model, message: error)
                .font(type.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var toolsControls: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { toolsExpanded.toggle() }
        } label: {
            HStack {
                Text("Tools")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(type.caption2)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(toolsExpanded ? 90 : 0))
            }
        }
        .buttonStyle(.menuRow)
        if toolsExpanded {
            VStack(alignment: .leading, spacing: 0) {
                Button("Headless Setup…") { open(KeepressoApp.setupWindowID) }
                    .buttonStyle(.menuRow)
                Button("Gaming & Streaming…") { open(KeepressoApp.streamingWindowID) }
                    .buttonStyle(.menuRow)
                Button("Keyboard Cleaner…") { open(KeepressoApp.keyboardCleanerWindowID) }
                    .buttonStyle(.menuRow)
                Button("Public Wi-Fi…") { open(KeepressoApp.wifiAssistantWindowID) }
                    .buttonStyle(.menuRow)
            }
            .padding(.leading, 12)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var appEntries: some View {
        Button("Preferences…") { open(KeepressoApp.preferencesWindowID) }
            .menuShortcut(",", enabled: preview == nil)
            .buttonStyle(.menuRow)
        toolsControls
        if menuExpanded {
            Button {
                withAnimation(.snappy(duration: 0.2)) { helpExpanded.toggle() }
            } label: {
                HStack {
                    Text("Help")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(type.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(helpExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.menuRow)
            if helpExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Button("Welcome to Keepresso…") { open(KeepressoApp.welcomeWindowID) }
                        .buttonStyle(.menuRow)
                    Button("About Keepresso") { open(KeepressoApp.aboutWindowID) }
                        .buttonStyle(.menuRow)
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                        .buttonStyle(.menuRow)
                    Button("Support Keepresso…") { NSWorkspace.shared.open(AppInfo.donate) }
                        .buttonStyle(.menuRow)
                }
                .padding(.leading, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }

        Divider()

        Button("Quit Keepresso") { NSApplication.shared.terminate(nil) }
            .menuShortcut("q", enabled: preview == nil)
            .buttonStyle(.menuRow)
    }

    private var expandToggleRow: some View {
        Button {
            model.menuPanelExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Spacer()
                Image(systemName: menuExpanded ? "chevron.up" : "chevron.down")
                    .font(type.caption2)
                Text(menuExpanded ? L("Show less") : L("Show more"))
                    .font(type.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.menuRow)
        .background {
            if preview == nil && !menuExpanded {
                Button("") { open(KeepressoApp.preferencesWindowID) }
                    .menuShortcut(",", enabled: preview == nil)
                    .hidden()
                Button("") { NSApplication.shared.terminate(nil) }
                    .menuShortcut("q", enabled: preview == nil)
                    .hidden()
            }
        }
    }

    private var quickStopButtons: some View {
        HStack(spacing: 6) {
            ForEach(model.quickStopDurations, id: \.self) { duration in
                quickStopButton(duration)
            }
        }
    }

    private var adaptiveQuickStopButtons: some View {
        let durations = model.quickStopDurations
        return ViewThatFits(in: .horizontal) {
            quickStopButtons.fixedSize()
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: durations.count, by: 2)), id: \.self) { index in
                    GridRow {
                        quickStopButton(durations[index])
                        if index + 1 < durations.count {
                            quickStopButton(durations[index + 1])
                        }
                    }
                }
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(durations, id: \.self) { duration in
                    quickStopButton(duration)
                }
            }
            .fixedSize()
        }
    }

    private func quickStopButton(_ duration: TimeInterval) -> some View {
        Button(Self.shortDuration(duration)) { model.stopSessionIn(duration) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lineLimit(1)
    }

    private var quickStopButtonsFitInline: Bool {
        model.quickStopDurations.count <= 3 && !model.quickStopDurations.contains {
            let minutes = Self.wholeMinutes($0)
            return minutes > 60 && minutes % 60 != 0
        }
    }

    /// Dismisses the dropdown, then opens a window scene with the app brought
    /// forward. Keepresso is an `LSUIElement` agent, so opening a sibling
    /// `Window` scene doesn't deactivate it: the `.window`-style panel keeps key
    /// status and the new window orders behind it (the user-reported "menu stays
    /// open behind Preferences" bug). Dismiss the panel before opening:
    /// the customization window can still be key while the popup is visible.
    /// a panel closed afterwards is still holding key status during the
    /// handoff, which is one way the new window ends up drawn inactive (gray
    /// controls) until the app is refocused by hand. `@Environment(\.dismiss)`
    /// isn't reliable for this panel across macOS versions, so ask the bridge
    /// to end AppKit's status-item session (or close the legacy panel).
    private func open(_ id: String) {
        guard preview == nil else { return }
        bridge.dismissPanel()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }


    private var header: some View {
        HStack(spacing: 8) {
            BrewingCupView(
                isActive: session.isActive,
                pausedLowBattery: session.pausedByBattery,
                scale: type.scale
            )
            VStack(alignment: .leading, spacing: 2) {
                Text((session.pausedByBattery || session.pausedByThermal)
                    ? L("Paused")
                    : (session.isActive ? L("Brewing") : L("Idle")))
                    .font(type.headline)
                    .contentTransition(.opacity)
                Text(statusDetail)
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.25), value: statusDetail)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .menuPreviewCard(preview: preview != nil, followsClarity: true)
        .background(
            Color.keepressoBrew.opacity(session.isActive ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .animation(.easeInOut(duration: 0.35), value: session.isActive)
        .modifier(ShakeEffect(animatableData: CGFloat(session.refusedStarts)))
        .animation(.easeInOut(duration: 0.45), value: session.refusedStarts)
    }

    private struct ShakeEffect: GeometryEffect {
        var animatableData: CGFloat

        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(CGAffineTransform(
                translationX: 5 * sin(animatableData * .pi * 6),
                y: 0
            ))
        }
    }

    private var helperAttentionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("The helper needs attention")
                    .font(type.callout.weight(.medium))
                Text(model.helperAttention == .needsApproval
                    ? L("Approve Keepresso again in System Settings.")
                    : model.helper.lastError ?? L("The helper isn't responding; reinstall it."))
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Fix\u{2026}") { open(KeepressoApp.helperWindowID) }
        }
        .padding(8)
        .menuPreviewCard(preview: preview != nil, cornerRadius: 8, tint: Color.orange.opacity(0.16), followsClarity: true)
    }


    private struct CustomDurationEditor: View {
        @State private var hours: Int
        @State private var minutes: Int
        let apply: (TimeInterval) -> Void
        @Environment(\.dismiss) private var dismiss
        private let type = ScaledType()

        init(initial: TimeInterval, apply: @escaping (TimeInterval) -> Void) {
            let totalMinutes = max(1, MenuBarContent.wholeMinutes(initial))
            _hours = State(initialValue: totalMinutes / 60)
            _minutes = State(initialValue: totalMinutes % 60)
            self.apply = apply
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Stepper("\(hours) h", value: $hours, in: 0...48)
                Stepper("\(minutes) min", value: $minutes, in: 0...55, step: 5)
                Button("Set Duration") {
                    apply(TimeInterval(hours * 3600 + minutes * 60))
                    dismiss()
                }
                .prominentActionStyle()
                .frame(maxWidth: .infinity)
                .disabled(hours == 0 && minutes == 0)
            }
            .padding(14)
            .frame(width: 180 * type.scale)
            .font(type.body)
        }
    }

    private struct UntilTimeEditor: View {
        let isActive: Bool
        let start: (Int, Int) -> Void
        @State private var time = Date().addingTimeInterval(60 * 60)
        @Environment(\.dismiss) private var dismiss
        private let type = ScaledType()

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Until", selection: $time, displayedComponents: .hourAndMinute)
                Text("If that time already passed today, it means tomorrow.")
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(isActive ? L("Update Session") : L("Start")) {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                    start(parts.hour ?? 0, parts.minute ?? 0)
                    dismiss()
                }
                .prominentActionStyle()
                .frame(maxWidth: .infinity)
            }
            .padding(14)
            .frame(width: 220 * type.scale)
            .font(type.body)
        }
    }

    private var statusDetail: String {
        if session.pausedByBattery {
            return L("Battery below %d%%, Keepresso sessions paused until plugged in", model.pauseBelowBatteryPercent)
        }
        if session.pausedByThermal {
            if let celsius = model.thermalGuard.currentCelsius {
                return L("Running hot (%d °C), letting the Mac cool down", Int(celsius))
            }
            return L("Running hot, letting the Mac cool down")
        }
        if model.triggersEnabled && !model.triggersPaused {
            return model.triggerSummary() ?? L("No conditions yet")
        }
        guard session.isActive else { return L("System can sleep") }
        if let remaining = session.remaining {
            return L("Stops in %@", MenuBarLabel.format(remaining))
        }
            return L("Awake for %@", MenuBarLabel.format(preview == nil ? panel.elapsed : session.elapsed))
    }

    @ViewBuilder
    private var heldByLine: some View {
        let _ = panel.tick
        if let held = panel.heldBy {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                    .font(type.caption)
                    .accessibilityHidden(true)
                Text("\(held.processName): \(held.effect.lowercased())")
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var hasStatusLines: Bool {
        model.fanBoostActivePercent != nil
            || (model.awdlStatus.isPausing && AWDLStatusStyle(model.awdlStatus) != nil)
    }

    @ViewBuilder
    private var statusStack: some View {
        let _ = panel.tick
        if hasStatusLines {
            VStack(alignment: .leading, spacing: 6) {
                fanStatusLine
                awdlStatusLine
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .menuPreviewCard(preview: preview != nil)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var leaseBanner: some View {
        if !session.liveLeases.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                leaseStatusLine
                Button("End Automation Leases") { model.endAutomationLeases() }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.keepressoBrew.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var leaseStatusLine: some View {
        let _ = panel.tick
        let leases = session.liveLeases
        if !leases.isEmpty {
            let paused = session.pausedByBattery || session.pausedByThermal
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.badge.clock")
                        .foregroundStyle(.secondary)
                        .font(type.caption)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(paused
                        ? (leases.count == 1
                            ? L("An automation lease is waiting (safety pause)")
                            : L("%d automation leases are waiting (safety pause)", leases.count))
                        : (leases.count == 1
                            ? L("Held awake by an automation lease")
                            : L("Held awake by %d automation leases", leases.count)))
                        .font(type.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                ForEach(leases.prefix(4), id: \.id) { lease in
                    HStack(spacing: 6) {
                        Text("\(lease.tool): \(lease.task)")
                            .font(type.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Self.graceCountdown(max(0, lease.expiresAt.timeIntervalSinceNow)))
                            .font(type.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .padding(.leading, 22)
                }
                if leases.count > 4 {
                    Text(L("and %d more", leases.count - 4))
                        .font(type.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 22)
                }
            }
        }
    }

    @ViewBuilder
    private var fanStatusLine: some View {
        if let percent = model.fanBoostActivePercent {
            HStack(spacing: 6) {
                Image(systemName: "fanblades")
                    .foregroundStyle(.orange)
                    .font(type.caption)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(L("Fans boosted to %d%% to cool the Mac", percent))
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var awdlStatusLine: some View {
        let _ = panel.tick
        if model.awdlStatus.isPausing, let status = AWDLStatusStyle(model.awdlStatus) {
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                    .font(type.caption)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(status.text)
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }


    private enum ControlMode: Hashable { case automatic, manual }

    private var modeSwitch: some View {
        Picker("Keep awake mode", selection: Binding(
            get: { model.triggersPaused ? ControlMode.manual : .automatic },
            set: { $0 == .manual ? model.pauseTriggers() : model.resumeTriggers() }
        )) {
            Text("Automatic").tag(ControlMode.automatic)
            Text("Manual").tag(ControlMode.manual)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var triggerSummary: some View {
        let _ = panel.tick
        if let states = model.ruleStates(), !states.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    HStack(spacing: 6) {
                        Image(systemName: state.satisfied ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(state.inGrace ? Color.orange : (state.satisfied ? Color.green : Color.secondary))
                            .font(type.caption)
                            .contentTransition(.symbolEffect(.replace))
                            .animation(.snappy(duration: 0.25), value: state.satisfied)
                            .animation(.snappy(duration: 0.25), value: state.inGrace)
                            .accessibilityLabel(state.inGrace ? L("Met, in grace period") : (state.satisfied ? L("Met") : L("Not met")))
                        Text(state.rule.label)
                            .font(type.caption)
                            .foregroundStyle(state.satisfied ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let remaining = state.graceRemaining {
                            Text(Self.graceCountdown(remaining))
                                .font(type.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                                .contentTransition(.numericText(countsDown: true))
                                .animation(.linear(duration: 0.2), value: remaining)
                        }
                    }
                    if !state.details.isEmpty {
                        ruleDetailRows(state.details)
                    }
                }
            }
        } else {
            Text("No conditions yet. Add some in Preferences ▸ Triggers.")
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let maxDetailRows = 5

    private static func detailAccent(_ detail: RuleDetail) -> Color {
        switch detail.agent {
        case "claude": return .claudeAccent
        case "cursor", "cursor-agent", "grok", "codex", "agy", "antigravity", "bionic",
             "omp", "cline",
             "hermes", "kilo", "opencode", "opencode2", "dsh", "muse", "devin",
             "qwen", "kimi":
            return .monochromeAccent
        default: return .green
        }
    }

    private func ruleDetailRows(_ details: [RuleDetail], limit: Int = Self.maxDetailRows) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(details.prefix(limit).enumerated()), id: \.offset) { _, detail in
                let accent = Self.detailAccent(detail)
                HStack(spacing: 6) {
                    SparkView(agent: detail.agent, animated: detail.animated && panelVisible,
                              tint: detail.active ? accent : Color.secondary)
                        .foregroundStyle(detail.active ? accent : Color.secondary)
                    Text(detail.label)
                        .font(type.caption)
                        .foregroundStyle(detail.active ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(detail.active ? L("working") : L("idle"))
                        .font(type.caption2)
                        .foregroundStyle(detail.active ? accent : Color.secondary)
                }
            }
            if details.count > limit {
                Text(L("+%d more", details.count - limit))
                    .font(type.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 22)
    }

}

private struct CustomMenuControlStyle: ViewModifier {
    var item: MenuItem
    var style: MenuControlStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        switch item {
        case .triggerAction:
            content.buttonStyle(.bordered)
                .tint(style == .accent ? .keepressoBrew : .primary)
                .foregroundStyle(style == .accent ? Color.keepressoBrew : .primary)
        case .duration, .manualOverride, .lidPolicy, .endAction, .presets:
            content.tint(.primary).foregroundStyle(.primary)
        case .setup, .gaming, .keyboard, .wifi, .preferences, .customize,
             .welcome, .about, .updates, .support, .quit:
            content.tint(.primary).foregroundStyle(.primary)
        default:
            content
        }
    }
}

private extension View {
    /// Liquid Glass cards composite through the window server. The nested
    /// preview uses the same content and geometry with a stable readable fill.
    @ViewBuilder
    func menuPreviewCard(preview: Bool, cornerRadius: CGFloat = 12, tint: Color? = nil, followsClarity: Bool = false) -> some View {
        if preview {
            background(tint ?? Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            glassCard(cornerRadius: cornerRadius, tint: tint, followsClarity: followsClarity)
        }
    }
    func menuShortcut(_ key: KeyEquivalent, enabled: Bool) -> some View {
        keyboardShortcut(enabled ? KeyboardShortcut(key, modifiers: .command) : nil)
    }
}
