import SwiftUI
import KeepressoCore

/// The dropdown shown when the menu bar icon is clicked. Kept lean: status, the
/// quick toggle (or a live trigger summary), and entries that open the
/// Preferences, Setup, and About windows. Detailed settings live in Preferences.
struct MenuBarContent: View {
    @Bindable var model: AppModel

    /// The auto-updater behind the "Check for Updates…" item.
    let updater: any Updating

    /// Opens the window scenes declared in ``KeepressoApp``.
    @Environment(\.openWindow) private var openWindow

    /// The controller the views read live state from.
    private var session: SessionController { model.session }

    /// Text styles and metrics at the readability scale (grows on very dense
    /// screens; exactly 1 everywhere else). Recomputed each render, and the
    /// body re-renders every second, so display changes are picked up live.
    private var type: ScaledType { ScaledType() }

    /// Drives the live duration label and re-evaluates trigger state each second.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var displayedElapsed: TimeInterval = 0
    @State private var liveRefresh = 0
    @State private var showCustomDuration = false
    @State private var showUntilTime = false

    private static let durationOptions: [(label: String, mode: SessionMode)] = [
        ("Indefinitely", .indefinite),
        ("15 minutes", .timed(duration: 15 * 60)),
        ("1 hour", .timed(duration: 60 * 60)),
        ("4 hours", .timed(duration: 4 * 60 * 60)),
    ]

    /// The menu label for the current mode: a preset's name when it matches,
    /// otherwise the custom duration spelled out ("2 h 30 min").
    static func modeLabel(_ mode: SessionMode) -> String {
        if let preset = durationOptions.first(where: { $0.mode == mode }) { return L(preset.label) }
        guard let duration = mode.duration else { return L("Indefinitely") }
        return shortDuration(duration)
    }

    /// A compact duration like "15 min", "1 h", or "2 h 30 min", shared by the
    /// mode label and the quick-stop buttons.
    static func shortDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = Int((duration / 60).rounded())
        let hours = totalMinutes / 60, minutes = totalMinutes % 60
        if hours > 0 && minutes > 0 { return L("%d h %d min", hours, minutes) }
        if hours > 0 { return L("%d h", hours) }
        return L("%d min", max(1, minutes))
    }

    /// A compact "M:SS" (or "Ns" under a minute) countdown for a grace window.
    static func graceCountdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s >= 60 { return L("%d:%02d", s / 60, s % 60) }
        return L("%ds", s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.helperAttention != nil {
                helperAttentionBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            heldByLine

            if model.triggersEnabled && !model.triggersPaused {
                triggerSummary
                    .transition(.opacity)
            }

            Divider()

            if model.triggersEnabled && !model.triggersPaused {
                Text("Activation is controlled by triggers.\nEdit them in Preferences.")
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Pause Triggers") { model.pauseTriggers() }
                    .prominentActionStyle()
                    .frame(maxWidth: .infinity)
            } else {
                if model.triggersEnabled {
                    Text("Triggers paused. Controlling manually for now.")
                        .font(type.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                    // The three short defaults share a line with the label;
                    // four shortcuts, or compound durations ("1 h 30 min",
                    // wordier in some languages), get the full panel width
                    // on their own row so the buttons never clip.
                    if quickStopButtonsFitInline {
                        LabeledContent("Stop in") { quickStopButtons }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Stop in")
                            quickStopButtons
                        }
                    }
                }

                if model.triggersEnabled {
                    Button("Resume Triggers") { model.resumeTriggers() }
                        .prominentActionStyle()
                        .frame(maxWidth: .infinity)
                }
            }

            Divider()

            // The same pmset switch wears two names: on a laptop it exists to
            // survive the lid closing, on a desktop (no lid, no battery) it
            // reads as a hard "never sleep" override.
            switchRow(model.machineHasBattery ? "Keep awake with lid closed" : "Disable system sleep",
                      isOn: Binding(
                get: { model.closedDisplayEnabled },
                set: { model.setClosedDisplay($0) }
            ), info: model.machineHasBattery
                ? L("Keeps the Mac running with the lid shut and no external display. This flips a system setting that needs administrator rights: silent with the administrator helper installed (Preferences ▸ General), otherwise macOS asks for your password.")
                : L("Stops the Mac from sleeping at all, even with no session running. This flips a system setting that needs administrator rights: silent with the administrator helper installed (Preferences ▸ General), otherwise macOS asks for your password."))
            .disabled(model.closedDisplayBusy)
            if model.closedDisplayBusy {
                AdminAuthNote(purpose: model.machineHasBattery
                    ? L("keep the Mac awake with the lid closed")
                    : L("disable system sleep"))
            }
            if model.closedDisplayEnabled {
                Text(model.machineHasBattery
                    ? L("Stays awake on battery too; the display turns off when the lid closes. Turn it off before putting it in a bag.")
                    : L("The Mac won't sleep at all until you turn this off. The display still sleeps as usual."))
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.closedDisplayError {
                Text(error)
                    .font(type.caption)
                    .foregroundStyle(.orange)
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
                Text(error)
                    .font(type.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            awdlStatusLine

            Divider()

            Group {
                Button("Preferences…") { open(KeepressoApp.preferencesWindowID) }
                    .keyboardShortcut(",")
                Button("Headless Setup…") { open(KeepressoApp.setupWindowID) }
                Button("Gaming & Streaming…") { open(KeepressoApp.streamingWindowID) }
                Button("About Keepresso") { open(KeepressoApp.aboutWindowID) }
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            .buttonStyle(.menuRow)

            Divider()

            Button("Quit Keepresso") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .buttonStyle(.menuRow)
        }
        .padding(14)
        .frame(width: 280 * type.scale)
        // Morph between the panel's states (triggers paused, closed-display
        // captions, the helper banner) instead of jump-cutting. Scoped to
        // these values so the per-second tick never animates layout.
        .animation(.snappy(duration: 0.25), value: session.isActive)
        .animation(.snappy(duration: 0.25), value: model.triggersEnabled)
        .animation(.snappy(duration: 0.25), value: model.triggersPaused)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayEnabled)
        .animation(.snappy(duration: 0.25), value: model.batteryAutoPauseEnabled)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayError)
        .animation(.snappy(duration: 0.25), value: model.helperAttention)
        .glassPanelBackground()
        .keepsPanelKey()
        .tint(.keepressoBrew)
        // Cascades to every text that sets no font of its own (toggles,
        // buttons, menu rows), so the whole panel scales together.
        .font(type.body)
        .onAppear { model.refreshClosedDisplay() }
        .onReceive(tick) { _ in
            displayedElapsed = session.elapsed
            liveRefresh &+= 1
        }
    }

    /// The quick "Stop in" shortcut buttons for the running session.
    private var quickStopButtons: some View {
        HStack(spacing: 6) {
            ForEach(model.quickStopDurations, id: \.self) { duration in
                Button(Self.shortDuration(duration)) {
                    model.stopSessionIn(duration)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .lineLimit(1)
            }
        }
    }

    /// Whether the shortcut buttons fit next to the "Stop in" label: at most
    /// three, none of them a compound duration (hours and minutes both).
    private var quickStopButtonsFitInline: Bool {
        model.quickStopDurations.count <= 3 && !model.quickStopDurations.contains {
            let minutes = Int(($0 / 60).rounded())
            return minutes > 60 && minutes % 60 != 0
        }
    }

    /// Dismisses the dropdown, then opens a window scene with the app brought
    /// forward. Keepresso is an `LSUIElement` agent, so opening a sibling
    /// `Window` scene doesn't deactivate it: the `.window`-style panel keeps key
    /// status and the new window orders behind it (the user-reported "menu stays
    /// open behind Preferences" bug). Capture the panel (it's the key window
    /// while a menu Button is being tapped) and close it *before* opening:
    /// a panel closed afterwards is still holding key status during the
    /// handoff, which is one way the new window ends up drawn inactive (gray
    /// controls) until the app is refocused by hand. `@Environment(\.dismiss)`
    /// isn't reliable for this panel across macOS versions, so target the
    /// `NSWindow` directly.
    private func open(_ id: String) {
        NSApp.keyWindow?.close()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            BrewingCupView(
                isActive: session.isActive,
                pausedLowBattery: session.pausedByBattery,
                scale: type.scale
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(session.pausedByBattery ? L("Paused") : (session.isActive ? L("Brewing") : L("Idle")))
                    .font(type.headline)
                    .contentTransition(.opacity)
                Text(statusDetail)
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Roll the digits of "Awake for" / "Stops in" like a
                    // timer instead of re-stamping the line every second.
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.25), value: statusDetail)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        // A faint warm wash behind the glass while brewing, like a lit burner.
        .background(
            Color.keepressoBrew.opacity(session.isActive ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .animation(.easeInOut(duration: 0.35), value: session.isActive)
    }

    /// A warning row shown while the privileged helper needs the user (approve
    /// again, or reinstall), so a missed attention window still leaves a
    /// visible cue in the place the user looks anyway. "Fix" reopens the
    /// walkthrough window.
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
                    : L("The helper isn't responding; reinstall it."))
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // Through open(_:) so the panel closes first; a window opened
            // while the panel holds key status comes up behind it, drawn
            // inactive (the exact bug open(_:) exists for).
            Button("Fix\u{2026}") { open(KeepressoApp.helperWindowID) }
        }
        .padding(8)
        .glassCard(cornerRadius: 8, tint: Color.orange.opacity(0.16))
    }

    // MARK: - Duration editors

    /// Popover behind "Custom Duration…": hour/minute steppers that set the
    /// session duration (used the next time it starts, or restarting a running
    /// session, exactly like picking a preset duration).
    private struct CustomDurationEditor: View {
        @State private var hours: Int
        @State private var minutes: Int
        let apply: (TimeInterval) -> Void
        @Environment(\.dismiss) private var dismiss
        private let type = ScaledType()

        init(initial: TimeInterval, apply: @escaping (TimeInterval) -> Void) {
            let totalMinutes = max(1, Int((initial / 60).rounded()))
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

    /// Popover behind "Until a Time…": picks a wall-clock time and starts (or
    /// restarts) the session to end there, today or tomorrow.
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
        // Battery auto-pause overrides everything else: say so, or an otherwise
        // satisfied session looks stuck for no visible reason.
        if session.pausedByBattery {
            return L("Battery below %d%%, letting the Mac sleep", model.pauseBelowBatteryPercent)
        }
        if model.triggersEnabled && !model.triggersPaused {
            return model.triggerSummary() ?? L("No conditions yet")
        }
        guard session.isActive else { return L("System can sleep") }
        if let remaining = session.remaining {
            return L("Stops in %@", MenuBarLabel.format(remaining))
        }
        return L("Awake for %@", MenuBarLabel.format(displayedElapsed))
    }

    /// A compact line naming another process that's holding the Mac awake, so an
    /// idle Keepresso still explains a Mac that won't sleep. Refreshes on the 1s
    /// tick (the whole body re-renders then).
    @ViewBuilder
    private var heldByLine: some View {
        let _ = liveRefresh // re-read the live assertion list each tick
        if let assertion = model.topExternalAssertion(), let effect = assertion.effect {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                    .font(type.caption)
                    .accessibilityHidden(true)
                Text("\(assertion.processName): \(effect.lowercased())")
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// AWDL watchdog state, so a user testing the app sees why Wi-Fi discovery
    /// is paused and, once they quit a game, the grace countdown before it
    /// resumes (yellow), rather than wondering why it's still off. Hidden when
    /// the watchdog isn't running. Refreshes on the 1s tick.
    @ViewBuilder
    private var awdlStatusLine: some View {
        let _ = liveRefresh
        // Only surface an active pause in the menu; the "watching" state would
        // just be persistent noise here (it lives in the Streaming window).
        if model.awdlStatus.isPausing, let status = AWDLStatusStyle(model.awdlStatus) {
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                    .font(type.caption)
                    .accessibilityHidden(true)
                Text(status.text)
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Live trigger summary

    @ViewBuilder
    private var triggerSummary: some View {
        let _ = liveRefresh // re-read live trigger state each tick
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

    /// How many per-instance sub-rows a rule may show before collapsing into a
    /// "+N more" line, so a wall of terminals can't swamp the menu.
    private static let maxDetailRows = 5

    /// The accent for one detail row: claude rows wear Claude's terracotta,
    /// every other agent keeps the generic green.
    private static func detailAccent(_ detail: RuleDetail) -> Color {
        detail.agent == "claude" ? .claudeAccent : .green
    }

    /// Indented per-instance rows under a rule: one detected agent session per
    /// line with a working/idle indicator and verdict.
    private func ruleDetailRows(_ details: [RuleDetail]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(details.prefix(Self.maxDetailRows).enumerated()), id: \.offset) { _, detail in
                let accent = Self.detailAccent(detail)
                HStack(spacing: 6) {
                    SparkView(animated: detail.animated)
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
            if details.count > Self.maxDetailRows {
                Text(L("+%d more", details.count - Self.maxDetailRows))
                    .font(type.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 22)
    }

}
