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
        if let preset = durationOptions.first(where: { $0.mode == mode }) { return preset.label }
        guard let duration = mode.duration else { return "Indefinitely" }
        let totalMinutes = Int((duration / 60).rounded())
        let hours = totalMinutes / 60, minutes = totalMinutes % 60
        if hours > 0 && minutes > 0 { return "\(hours) h \(minutes) min" }
        if hours > 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(max(1, minutes)) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.triggersEnabled && !model.triggersPaused {
                triggerSummary
            }

            Divider()

            if model.triggersEnabled && !model.triggersPaused {
                Text("Activation is controlled by triggers.\nEdit them in Preferences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Pause Triggers") { model.pauseTriggers() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            } else {
                if model.triggersEnabled {
                    Text("Triggers paused. Controlling manually for now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Keep awake", isOn: Binding(
                    get: { session.isActive },
                    set: { _ in model.toggleManual() }
                ))
                .toggleStyle(.switch)

                LabeledContent("For") {
                    Menu(Self.modeLabel(model.mode)) {
                        ForEach(Array(Self.durationOptions.enumerated()), id: \.offset) { _, option in
                            Button(option.label) { model.mode = option.mode }
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

                if model.triggersEnabled {
                    Button("Resume Triggers") { model.resumeTriggers() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
            }

            Divider()

            Toggle("Keep awake with lid closed", isOn: Binding(
                get: { model.closedDisplayEnabled },
                set: { model.setClosedDisplay($0) }
            ))
            .toggleStyle(.switch)
            .disabled(model.closedDisplayBusy)
            if model.closedDisplayBusy {
                Text("Waiting for your password…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.closedDisplayEnabled {
                Text("Stays awake on battery too; the display turns off when the lid closes. Turn it off before putting it in a bag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.closedDisplayError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        .frame(width: 280)
        .glassPanelBackground()
        .tint(.keepressoBrew)
        .onAppear { model.refreshClosedDisplay() }
        .onReceive(tick) { _ in
            displayedElapsed = session.elapsed
            liveRefresh &+= 1
        }
    }

    /// Opens a window scene and brings the app forward, then dismisses the
    /// dropdown. Keepresso is an `LSUIElement` agent, so opening a sibling
    /// `Window` scene doesn't deactivate it: the `.window`-style panel keeps key
    /// status and the new window orders behind it (the user-reported "menu stays
    /// open behind Preferences" bug). Capture the panel (it's the key window
    /// while a menu Button is being tapped) and close it after opening.
    /// `@Environment(\.dismiss)` isn't reliable for this panel across macOS
    /// versions, so target the `NSWindow` directly.
    private func open(_ id: String) {
        let panel = NSApp.keyWindow
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
        panel?.close()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            BrewingCupView(isActive: session.isActive)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.isActive ? "Brewing" : "Idle")
                    .font(.headline)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Duration editors

    /// Popover behind "Custom Duration…": hour/minute steppers that set the
    /// session duration (used the next time it starts, or restarting a running
    /// session, exactly like picking a preset duration).
    private struct CustomDurationEditor: View {
        @State private var hours: Int
        @State private var minutes: Int
        let apply: (TimeInterval) -> Void
        @Environment(\.dismiss) private var dismiss

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
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(hours == 0 && minutes == 0)
            }
            .padding(14)
            .frame(width: 180)
        }
    }

    /// Popover behind "Until a Time…": picks a wall-clock time and starts (or
    /// restarts) the session to end there, today or tomorrow.
    private struct UntilTimeEditor: View {
        let isActive: Bool
        let start: (Int, Int) -> Void
        @State private var time = Date().addingTimeInterval(60 * 60)
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Until", selection: $time, displayedComponents: .hourAndMinute)
                Text("If that time already passed today, it means tomorrow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(isActive ? "Update Session" : "Start") {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                    start(parts.hour ?? 0, parts.minute ?? 0)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding(14)
            .frame(width: 220)
        }
    }

    private var statusDetail: String {
        if model.triggersEnabled && !model.triggersPaused {
            return model.triggerSummary() ?? "No conditions yet"
        }
        guard session.isActive else { return "System can sleep" }
        if let remaining = session.remaining {
            return "Stops in \(MenuBarLabel.format(remaining))"
        }
        return "Awake for \(MenuBarLabel.format(displayedElapsed))"
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
                            .foregroundStyle(state.satisfied ? Color.green : Color.secondary)
                            .font(.caption)
                            .accessibilityLabel(state.satisfied ? "Met" : "Not met")
                        Text(state.rule.label)
                            .font(.caption)
                            .foregroundStyle(state.satisfied ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
        } else {
            Text("No conditions yet. Add some in Preferences ▸ Triggers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}
