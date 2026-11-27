import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import KeepressoCore

struct WelcomeView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var selectedUseCase: String?
    @State private var showOtherUseCases = false
    @State private var revealed = false
    @State private var lidRowShakes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct UseCase: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
    }

    private static let manualID = "manual"

    private static let useCases: [UseCase] = [
        UseCase(id: "ai-agent", title: "Agentic coding",
                detail: "Stay awake while Claude Code, Cursor, Codex, or another agent is working.",
                icon: "terminal"),
        UseCase(id: "meetings", title: "Meetings & calls",
                detail: "Stay awake whenever the camera or microphone is in use.", icon: "video"),
        UseCase(id: "cloud-gaming", title: "Gaming & streaming",
                detail: "Stay awake while a game or cloud-gaming app is in front.", icon: "gamecontroller"),
        UseCase(id: "external-display", title: "Docked to a display",
                detail: "Stay awake whenever an external display is connected.", icon: "display.2"),
        UseCase(id: "on-ac-power", title: "Plugged into power",
                detail: "Stay awake whenever your Mac is running on AC power.", icon: "powerplug"),
        UseCase(id: "remote-session", title: "Remote access",
                detail: "Stay awake while someone is connected over SSH.", icon: "network"),
        UseCase(id: manualID, title: "Keep it manual for now",
                detail: "Just toggle keep-awake yourself, and set up your own triggers later in Preferences.",
                icon: "hand.tap"),
    ]

    private enum Step: Int, CaseIterable {
        case welcome, useCase, setup
        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == Step.allCases.last }
        var previous: Step { Step(rawValue: rawValue - 1) ?? self }
        var next: Step { Step(rawValue: rawValue + 1) ?? self }
    }
    @State private var step: Step = .welcome
    /// Whether the window is actually on screen. The closed window keeps this
    /// shell alive, so the heavy tour unmounts while false (stops Observation
    /// and TimelineView churn) and remounts on reopen. Starts false so the
    /// first paint waits for a real visibility probe rather than flashing the
    /// last-remembered step.
    @State private var windowVisible = false

    private var cupBrewing: Bool {
        model.session.isActive
            || (selectedUseCase != nil && selectedUseCase != Self.manualID)
    }

    @State private var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800

    private var type: ScaledType { ScaledType() }

    private var scrollCap: CGFloat { max(300, screenHeight - 230 * type.scale) }

    private static let scrollSpace = "welcome-scroll"

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    private var needsScroll: Bool { contentHeight > viewportHeight + 1 }
    private var reachedBottom: Bool { scrollOffset <= viewportHeight - contentHeight + 2 }

    var body: some View {
        Group {
            if windowVisible {
                VStack(spacing: 0) {
                    BrewingCupView(isActive: cupBrewing, scale: 2.0 * type.scale)
                        .padding(.top, 22)
                        .padding(.bottom, 4)
                    ScrollView {
                        stepContent
                            .padding(.horizontal, 24)
                            .padding(.top, 10)
                            .padding(.bottom, 12)
                            .id(step)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ChecklistFrameKey.self,
                                    value: proxy.frame(in: .named(Self.scrollSpace))
                                )
                            })
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    // fixedSize makes the scroll area ask for its content's full
                    // height and the capped frame clamps it, so the window hugs the
                    // checklist whenever it fits under the cap and scrolls when it
                    // doesn't. (Verified empirically: without fixedSize the window
                    // ignores the content and opens at a default height.)
                    .frame(maxHeight: scrollCap)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: ViewportHeightKey.self,
                            value: proxy.size.height
                        )
                    })
                    .overlay(alignment: .bottom) {
                        if needsScroll && !reachedBottom {
                            moreBelowCue
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: reachedBottom)
                    .onPreferenceChange(ChecklistFrameKey.self) { frame in
                        contentHeight = frame.height
                        scrollOffset = frame.minY
                    }
                    .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }

                    footer
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                }
                .font(type.body)
                .onAppear {
                    model.helper.refresh()
                    model.refreshAgentHookStatuses()
                    revealed = true
                    refreshScreenHeight()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didChangeScreenParametersNotification
                )) { _ in
                    refreshScreenHeight()
                }
                .task { notificationStatus = await model.notificationAuthorizationStatus() }
            } else {
                Color.clear
                    .frame(width: 400 * type.scale)
            }
        }
        .frame(width: 400 * type.scale)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        .centersAndFrontsWindow()
        // Ignore occlusion: a password sheet or another app covering this
        // window must not unmount the tour (and must not look like a close).
        // Only a real order-out / close flips visibility.
        .background(WindowVisibilityReader(isVisible: $windowVisible, ignoreOcclusion: true))
        .onChange(of: windowVisible) { _, visible in
            // Only a real reopen gets here: `onChange` fires on transitions,
            // and with occlusion ignored a password prompt, focus loss or a
            // covering window no longer counts as one (they used to send the
            // user back to step 1 mid-setup).
            guard visible else { return }
            step = .welcome
            revealed = false
            refreshScreenHeight()
            launchAtLogin = LoginItem.isEnabled
            model.refreshAgentHookStatuses()
            Task { notificationStatus = await model.notificationAuthorizationStatus() }
            withAnimation { revealed = true }
        }
    }

    private func refreshScreenHeight() {
        screenHeight = NSScreen.main?.visibleFrame.height ?? 800
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .useCase: useCaseStep
        case .setup:   setupStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Text("Welcome to Keepresso")
                .font(type.title2.bold())
            Text("Keepresso keeps your Mac awake from the menu bar, with no Dock icon and no main window.")
                .font(type.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                pointRow("cursorarrow.click",
                         "Click the cup in the menu bar to keep your Mac awake, and click again to let it sleep.")
                pointRow("wand.and.stars",
                         "Or set up triggers, so it stays awake automatically only while you are on a call, downloading, or gaming.")
                pointRow("checkmark.shield",
                         "It also protects your Mac, pausing on low battery or high temperature.")
            }
            .padding(.top, 2)
            languagePicker
        }
        .frame(maxWidth: .infinity)
        .entrance(0, revealed: revealed, animated: !reduceMotion)
    }

    private func pointRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(type.callout)
                .foregroundStyle(Color.keepressoBrew)
                .frame(width: 22 * type.scale)
            Text(LocalizedStringKey(text))
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var useCaseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When should it stay awake?")
                .font(type.callout.weight(.semibold))
            Text("Choose how you use your Mac and Keepresso sets up matching triggers. It then keeps the Mac awake only while those conditions hold, and lets it sleep otherwise. You can adjust or add triggers in Preferences.")
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let selected = Self.useCases.first(where: { $0.id == selectedUseCase }) {
                useCaseRow(selected)
                DisclosureGroup("Choose another use", isExpanded: $showOtherUseCases) {
                    ForEach(Self.useCases.filter { $0.id != selectedUseCase }) { useCase in
                        useCaseRow(useCase)
                    }
                }
                .font(type.caption)
            } else {
                ForEach(Self.useCases) { useCase in
                    useCaseRow(useCase)
                }
            }
            if selectedUseCase == "cloud-gaming" {
                gamingJitterCallout
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if selectedUseCase == "ai-agent", !model.agentSetupTools.isEmpty {
                agentHooksCallout
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: selectedUseCase)
        .entrance(0, revealed: revealed, animated: !reduceMotion)
    }

    private var setupStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A few basics")
                .font(type.callout.weight(.semibold))
            setupRow(
                icon: "power",
                title: "Launch at login",
                detail: "Start Keepresso automatically when you log in."
            ) {
                Toggle("", isOn: Binding(
                    get: { launchAtLogin },
                    set: { LoginItem.setEnabled($0); launchAtLogin = LoginItem.isEnabled }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            setupRow(
                icon: "bell.badge",
                title: "Notifications",
                detail: "Let Keepresso remind you when a long session is still keeping the Mac awake."
            ) {
                notificationControl
            }
            setupRow(
                icon: "checkmark.seal",
                title: "Administrator helper",
                detail: "Approve a small helper once and the privileged extras (lid-closed mode, AWDL pausing) never ask for your password again. Set and forget; removable in Preferences."
            ) {
                helperControl
            }
            if model.machineHasBattery {
                closedDisplaySetupRow
                setupRow(
                    icon: "shield.lefthalf.filled",
                    title: "Battery and heat safety",
                    detail: "Let the Mac sleep anyway if the charge runs low, or if it stays hot with the lid shut. Thresholds are in Preferences."
                ) {
                    Toggle("", isOn: Binding(
                        get: { safetyNetsEnabled },
                        set: { setSafetyNets($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            Text("Keepresso runs in the menu bar. Click the cup at any time, or open Preferences for everything else.")
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .animation(.snappy(duration: 0.25), value: model.closedDisplayError)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayAutoError)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayOnlyWhileBrewing)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayEnabled)
        .entrance(0, revealed: revealed, animated: !reduceMotion)
    }

    private var closedDisplaySetupRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            setupRow(
                icon: "laptopcomputer",
                title: "Keep awake with the lid closed",
                detail: "Keep running with the lid shut and no external display. Stays on until you switch it off."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.closedDisplayEnabled },
                    set: { model.setClosedDisplay($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.closedDisplayBusy || model.closedDisplayOnlyWhileBrewing)
                .overlay {
                    if model.closedDisplayOnlyWhileBrewing {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { lidRowShakes += 1 }
                    }
                }
            }
            if model.closedDisplayOnlyWhileBrewing {
                Text("Follows the session while \u{201C}Only while brewing\u{201D} is on.")
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .shakes(on: lidRowShakes)
            } else if model.closedDisplayEnabled, !model.closedDisplayOnlyWhileBrewing {
                onlyWhileBrewingHint
            }
            if model.closedDisplayAutoBusy && !model.helperInstalled {
                AdminAuthNote(purpose: L("switch closed-display mode with the session"))
            }
            if model.closedDisplayBusy && !model.helperInstalled {
                AdminAuthNote(purpose: L("keep the Mac awake with the lid closed"))
            }
            if let error = model.closedDisplayAutoError {
                HelperFeatureNotice(model: model, message: error)
                    .font(type.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.closedDisplayError {
                HelperFeatureNotice(model: model, message: error)
                    .font(type.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var onlyWhileBrewingHint: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cup.and.saucer.fill")
                .font(type.title3)
                .foregroundStyle(Color.keepressoBrew)
                .frame(width: 26 * type.scale)
            VStack(alignment: .leading, spacing: 2) {
                Text("Handle it automatically")
                    .font(type.callout.weight(.medium))
                Text("Enable \u{201C}Only while brewing\u{201D} so closed-display follows each keep-awake session (your triggers or a manual brew) and turns off when nothing is holding the Mac awake.")
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Enable") {
                model.closedDisplayOnlyWhileBrewing = true
            }
            .controlSize(.small)
            .disabled(model.closedDisplayAutoBusy)
        }
        .padding(8)
        .glassCard(cornerRadius: 10, tint: Color.keepressoBrew.opacity(0.04))
    }

    private var safetyNetsEnabled: Bool {
        model.batteryAutoPauseEnabled && model.thermalSafety != nil
    }

    private func setSafetyNets(_ on: Bool) {
        model.batteryAutoPauseEnabled = on
        model.thermalSafety = on ? (model.thermalSafety ?? ThermalSafetyConfig()) : nil
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Divider()
            HStack {
                if step.isFirst {
                    Link("Learn more", destination: AppInfo.website)
                        .font(type.callout)
                } else {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.2)) { step = step.previous }
                    }
                }
                Spacer()
                stepDots
                Spacer()
                if step.isLast {
                    Button("Get Started") {
                        model.hasOnboarded = true
                        dismiss()
                    }
                    .prominentActionStyle()
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") {
                        withAnimation(.easeInOut(duration: 0.2)) { step = step.next }
                    }
                    .prominentActionStyle()
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .entrance(3, revealed: revealed, animated: !reduceMotion)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s == step ? Color.keepressoBrew : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private var moreBelowCue: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "chevron.compact.down")
                .font(type.title3)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
        }
        .frame(height: 34)
        .allowsHitTesting(false)
    }

    /// The Notifications row's trailing control, reflecting the real permission
    /// state: already granted shows a static "Enabled", a prior denial sends the
    /// user to System Settings (a re-request would silently no-op), and only an
    /// undecided state offers to ask.
    @ViewBuilder
    private var notificationControl: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Label("Enabled", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(type.callout)
                .foregroundStyle(.secondary)
        case .denied:
            Button("Open Settings") { openNotificationSettings() }
        default:
            Button("Enable") {
                Task { notificationStatus = await model.requestNotificationAuthorization() }
            }
        }
    }

    @ViewBuilder
    private var helperControl: some View {
        switch model.helper.status {
        case .enabled:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(type.callout)
                .foregroundStyle(.secondary)
        case .requiresApproval:
            Button("Approve\u{2026}") { model.helper.openApprovalSettings() }
        default:
            Button("Install\u{2026}") { model.installHelper() }
        }
    }

    private var languagePicker: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(type.caption)
                .foregroundStyle(.secondary)
            Picker("App language", selection: Binding(
                get: { AppLanguage.current },
                set: { switchLanguage(to: $0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("App language"))
        }
    }

    private func switchLanguage(to language: AppLanguage) {
        guard language != AppLanguage.current else { return }
        language.apply()
        model.hasOnboarded = false
        AppLanguage.relaunch()
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private var gamingJitterCallout: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
                .font(type.title3)
                .foregroundStyle(Color.keepressoBrew)
                .frame(width: 26 * type.scale)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reduce lag and jitter")
                    .font(type.callout.weight(.medium))
                Text("Pause AWDL to steady your connection, and test your jitter, in Gaming & Streaming.")
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Set Up\u{2026}") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: KeepressoApp.streamingWindowID)
            }
        }
        .padding(8)
        .glassCard(cornerRadius: 10, tint: Color.keepressoBrew.opacity(0.04))
    }

    private var agentHooksCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(type.title3)
                    .foregroundStyle(Color.keepressoBrew)
                    .frame(width: 26 * type.scale)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Know exactly when an agent is working")
                        .font(type.callout.weight(.medium))
                    Text("Connect the coding tools you use and their sessions report for themselves, instead of Keepresso judging them by how busy they look.")
                        .font(type.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            ForEach(model.agentSetupTools, id: \.self) { tool in
                AgentHookConnectionRow(model: model, tool: tool, compact: true)
            }
        }
        .padding(8)
        .glassCard(cornerRadius: 10, tint: Color.keepressoBrew.opacity(0.04))
    }

    private func apply(_ useCase: UseCase) {
        if useCase.id == Self.manualID {
            model.triggersEnabled = false
        } else if let preset = Preset.builtIns.first(where: { $0.id == useCase.id }) {
            model.applyPreset(preset)
        }
        selectedUseCase = useCase.id
        showOtherUseCases = false
    }

    private func useCaseRow(_ useCase: UseCase) -> some View {
        let selected = selectedUseCase == useCase.id
        return Button {
            apply(useCase)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: useCase.icon)
                    .font(type.title3)
                    .foregroundStyle(Color.keepressoBrew)
                    .frame(width: 26 * type.scale)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(useCase.title)).font(type.callout.weight(.medium))
                    Text(LocalizedStringKey(useCase.detail))
                        .font(type.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.keepressoBrew : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(8)
            .background(selected ? Color.keepressoBrew.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func setupRow<Control: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(type.title3)
                .foregroundStyle(Color.keepressoBrew)
                .frame(width: 26 * type.scale)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(type.callout.weight(.medium))
                Text(LocalizedStringKey(detail))
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
    }
}

private struct ChecklistFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    func entrance(_ order: Int, revealed: Bool, animated: Bool) -> some View {
        opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 10)
            .animation(
                animated ? .easeOut(duration: 0.4).delay(0.05 + Double(order) * 0.08) : nil,
                value: revealed
            )
    }
}
