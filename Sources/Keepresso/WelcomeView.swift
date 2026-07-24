import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import KeepressoCore

/// The first-run welcome window: a short intro to a menu-bar app that has no
/// Dock icon or main window, then a one-click "how do you use your Mac" setup
/// that applies a matching trigger preset, plus a couple of general options.
/// Shown on launch until Get Started is pressed (the press is what sets
/// ``AppModel/hasOnboarded``) and reopenable from Preferences > General.
/// Every step here acts only when its control is used; nothing prompts for a
/// permission just because the window opened.
struct WelcomeView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = LoginItem.isEnabled
    /// The live notification authorization status, so the row reflects "already
    /// on" / "not asked" / "denied" instead of always offering Enable.
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// The preset id of the use case the user picked, for the checkmark. Local
    /// to this window: applying a preset is the persisted action.
    @State private var selectedUseCase: String?
    /// Drives the one-time entrance: sections fade up in a quick stagger the
    /// first time the window draws. Skipped entirely under Reduce Motion.
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A way someone uses their Mac, mapped to a built-in preset that sets up the
    /// matching triggers in one tap.
    private struct UseCase: Identifiable {
        let id: String // the built-in preset id to apply
        let title: String
        let detail: String
        let icon: String
    }

    /// The id of the opt-out row: no triggers, keep-awake stays a manual toggle.
    private static let manualID = "manual"

    private static let useCases: [UseCase] = [
        UseCase(id: "ai-agent", title: "Agentic coding",
                detail: "Stay awake while Claude, Codex, or Grok is running.", icon: "terminal"),
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

    /// The onboarding is a short paged flow: an intro, then the "how do you use
    /// your Mac" picker, then the general setup rows. Only Get Started on the
    /// last step completes onboarding (sets ``AppModel/hasOnboarded``), so a
    /// user who closes early still sees the welcome again next launch.
    private enum Step: Int, CaseIterable {
        case welcome, useCase, setup
        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == Step.allCases.last }
        var previous: Step { Step(rawValue: rawValue - 1) ?? self }
        var next: Step { Step(rawValue: rawValue + 1) ?? self }
    }
    @State private var step: Step = .welcome

    /// Whether the hero cup is brewing: a live session, or a use case just
    /// picked (the pour is the payoff for the choice; the manual opt-out
    /// keeps the cup honest and empty).
    private var cupBrewing: Bool {
        model.session.isActive
            || (selectedUseCase != nil && selectedUseCase != Self.manualID)
    }

    /// The screen's visible height, kept live: resolutions change at runtime
    /// and displays come and go, so this refreshes on every screen-parameter
    /// change (and each open) rather than being read once per app run.
    @State private var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800

    /// Text styles and metrics at the readability scale (grows on very dense
    /// screens; exactly 1 everywhere else). The body re-renders whenever
    /// `screenHeight` refreshes, which covers display and resolution changes.
    private var type: ScaledType { ScaledType() }

    /// The scroll area's height cap: the visible screen height minus room
    /// for the pinned footer and the window chrome (which grow with the
    /// readability scale). On a regular display the whole checklist fits
    /// under it and the window hugs the content exactly; on a low-resolution
    /// one the checklist scrolls behind the footer instead of running off
    /// screen.
    private var scrollCap: CGFloat { max(320, screenHeight - 130 * type.scale) }

    private static let scrollSpace = "welcome-scroll"

    /// Measurements for the "more below" cue only. Deliberately never fed
    /// back into layout: the scroll area's height comes from `maxHeight`
    /// below, not from these.
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// The checklist's top edge inside the scroll viewport: 0 at rest, going
    /// negative as the user scrolls.
    @State private var scrollOffset: CGFloat = 0

    private var needsScroll: Bool { contentHeight > viewportHeight + 1 }
    private var reachedBottom: Bool { scrollOffset <= viewportHeight - contentHeight + 2 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                stepContent
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
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
            // The cue that more of the checklist sits below the fold: a fade
            // and a chevron, gone once the user reaches the end (and never
            // shown when everything fits).
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
        .frame(width: 400 * type.scale)
        .tint(.keepressoBrew)
        // Cascades to every text that sets no font of its own (toggles,
        // buttons, links), so the whole window scales together.
        .font(type.body)
        .glassWindowBackground()
        .centersAndFrontsWindow()
        .onAppear {
            // Status reads only; showing the window never prompts for anything.
            model.helper.refresh()
            revealed = true
            refreshScreenHeight()
        }
        // Resolution or display changes while the app runs must re-cap the
        // window, or it can end up taller than the new screen.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            refreshScreenHeight()
        }
        .task { notificationStatus = await model.notificationAuthorizationStatus() }
    }

    private func refreshScreenHeight() {
        screenHeight = NSScreen.main?.visibleFrame.height ?? 800
    }

    /// The current step's content. Each step is one of the sections that used
    /// to be stacked on a single scrolling page.
    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .useCase: useCaseStep
        case .setup:   setupStep
        }
    }

    /// Step 1: what Keepresso is, plus a language picker for anyone who landed
    /// in the wrong language before reading anything else.
    private var welcomeStep: some View {
        VStack(spacing: 10) {
            BrewingCupView(isActive: cupBrewing, scale: 2.8 * type.scale)
            Text("Welcome to Keepresso")
                .font(type.title2.bold())
            Text("Keepresso keeps your Mac awake on your terms. It lives in the menu bar near the clock, with no Dock icon. Click its cup any time to start or stop.")
                .font(type.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            languagePicker
        }
        .frame(maxWidth: .infinity)
        .entrance(0, revealed: revealed, animated: !reduceMotion)
    }

    /// Step 2: pick how you use your Mac to seed a matching preset in one tap.
    private var useCaseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How do you use your Mac?")
                .font(type.callout.weight(.semibold))
            Text("Pick one to set up matching triggers, or keep it manual and add your own later. You can change this any time in Preferences.")
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.useCases) { useCase in
                useCaseRow(useCase)
            }
            if selectedUseCase == "cloud-gaming" {
                gamingJitterCallout
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: selectedUseCase)
        .entrance(0, revealed: revealed, animated: !reduceMotion)
    }

    /// Step 3: a couple of general options. Each acts only when its own control
    /// is used; reaching this step prompts for nothing.
    private var setupStep: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        }
        .entrance(0, revealed: revealed, animated: !reduceMotion)
    }

    /// Pinned under the scroll area, so Get Started is always on screen no
    /// matter how small the display is. Get Started is what consumes the
    /// first-run one-shot: not opening the window, not seeing it. Anything
    /// short of that press (a language-switch relaunch, closing the window,
    /// quitting) brings the welcome back on the next launch.
    private var footer: some View {
        VStack(spacing: 14) {
            Divider()
            HStack {
                // Leading: "Learn more" on the first step, "Back" afterwards.
                if step.isFirst {
                    Link("Learn more", destination: AppInfo.repository)
                        .font(type.callout)
                } else {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.2)) { step = step.previous }
                    }
                }
                Spacer()
                stepDots
                Spacer()
                // Trailing: advance, or finish onboarding on the last step.
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

    /// Small progress dots between the footer buttons, one per step.
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

    /// A soft fade with a compact chevron over the scroll area's last points.
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
        default: // .notDetermined and any future case: safe to ask
            Button("Enable") {
                Task { notificationStatus = await model.requestNotificationAuthorization() }
            }
        }
    }

    /// The Administrator helper row's trailing control, mirroring
    /// ``HelperStatusRows`` in the compact welcome layout. Installing acts
    /// only on the button press, never on the window appearing (the one-time
    /// approval, with its password ask, happens over in System Settings).
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

    /// A quiet globe-and-menu row under the hero, so someone landed in the
    /// wrong language can fix it before reading anything else. Switching
    /// relaunches the app (the override resolves at process start); clearing
    /// `hasOnboarded` first makes the fresh instance reopen this window in
    /// the picked language, so the relaunch reads as a live switch. And since
    /// only Get Started sets the flag back, the welcome keeps returning on
    /// launch until the user confirms in the language they ended up with.
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

    /// Offered when the gaming use case is picked: a hop to the Gaming &
    /// Streaming window, where AWDL pausing (which steadies the connection and
    /// cuts jitter) and the jitter test live. A hand-off rather than an inline
    /// enable, because turning AWDL on needs an administrator password, which
    /// that window sets up in context (and its jitter test shows whether it's
    /// even needed first). Opening a window never prompts.
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
        .glassCard(cornerRadius: 8, tint: Color.keepressoBrew.opacity(0.14))
    }

    /// Act on a picked use case: the manual opt-out turns trigger gating off (so
    /// keep-awake stays a plain manual toggle), any other applies its preset,
    /// which switches the rule set and turns triggers on.
    private func apply(_ useCase: UseCase) {
        if useCase.id == Self.manualID {
            model.triggersEnabled = false
        } else if let preset = Preset.builtIns.first(where: { $0.id == useCase.id }) {
            model.applyPreset(preset)
        }
        selectedUseCase = useCase.id
    }

    /// A pickable use case: applying it switches the whole rule set to the
    /// matching preset (a switch, not a merge) and turns triggers on.
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

    /// One general setup step: an SF Symbol, a title and explanation, and a
    /// trailing control (a toggle or a button).
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

/// The welcome checklist's frame in the scroll view's space: the height
/// sizes the window to the content, the top edge drives the "more below"
/// cue.
private struct ChecklistFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// The scroll viewport's height, compared against the checklist's to decide
/// whether the cue is needed at all.
private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    /// One step of the welcome window's one-time entrance: fade up in order,
    /// a quick stagger per section. With `animated` false (Reduce Motion) the
    /// reveal is instant.
    func entrance(_ order: Int, revealed: Bool, animated: Bool) -> some View {
        opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 10)
            .animation(
                animated ? .easeOut(duration: 0.4).delay(0.05 + Double(order) * 0.08) : nil,
                value: revealed
            )
    }
}
