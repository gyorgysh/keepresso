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

    private static let durationOptions: [(label: String, mode: SessionMode)] = [
        ("Indefinitely", .indefinite),
        ("15 minutes", .timed(duration: 15 * 60)),
        ("1 hour", .timed(duration: 60 * 60)),
        ("4 hours", .timed(duration: 4 * 60 * 60)),
    ]

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

                Picker("For", selection: Binding(
                    get: { model.mode },
                    set: { model.mode = $0 }
                )) {
                    ForEach(Array(Self.durationOptions.enumerated()), id: \.offset) { _, option in
                        Text(option.label).tag(option.mode)
                    }
                }
                .pickerStyle(.menu)

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
        .tint(.keepressoBrew)
        .onAppear { model.refreshClosedDisplay() }
        .onReceive(tick) { _ in
            displayedElapsed = session.elapsed
            liveRefresh &+= 1
        }
    }

    /// Opens a window scene and brings the app forward (an `LSUIElement` agent
    /// has no Dock icon, so the new window can otherwise appear behind others).
    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
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

    private var statusDetail: String {
        if model.triggersEnabled && !model.triggersPaused {
            return model.triggerSummary() ?? "No conditions yet"
        }
        guard session.isActive else { return "System can sleep" }
        if let remaining = session.remaining {
            return "Stops in \(format(remaining))"
        }
        return "Awake for \(format(displayedElapsed))"
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

    private func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
