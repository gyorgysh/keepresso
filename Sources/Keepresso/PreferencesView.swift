import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KeepressoCore

/// The Preferences window. Holds the settings that used to crowd the menu
/// dropdown: keep-awake options, triggers, the reminder, disk keep-alive, and
/// launch-at-login, grouped into tabs.
struct PreferencesView: View {
    @Bindable var model: AppModel
    @State private var section: Section = .general

    /// The Preferences sections. A plain top segmented control rather than a
    /// `TabView`, which macOS 26 renders as an obtrusive sidebar.
    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case triggers = "Triggers"
        case reminder = "Reminder"
        case automation = "Automation"
        case disk = "Disk"
        case display = "Display"
        case activity = "Activity"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .triggers: "bolt"
            case .reminder: "bell"
            case .automation: "arrow.triangle.branch"
            case .disk: "externaldrive"
            case .display: "display"
            case .activity: "list.bullet.rectangle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Label(LocalizedStringKey(section.rawValue), systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            content
                // topLeading, not top: a tab whose content hugs its width
                // (Triggers with the switch off) must still sit left like
                // every Form tab, not float centered.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // A fast crossfade between sections; no sliding.
                .animation(.easeOut(duration: 0.15), value: section)
        }
        // 580 fits seven labeled segments; 520 was enough for six.
        .frame(width: 580, height: 560)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        .centersAndFrontsWindow()
        // The helper can be approved (or revoked) over in System Settings at
        // any time; re-read on every open so the section tells the truth.
        .onAppear { model.helper.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralTab(model: model)
        case .triggers: TriggersTab(model: model)
        case .reminder: ReminderTab(model: model)
        case .automation: AutomationTab(model: model)
        case .disk: DiskTab(model: model)
        case .display: DisplayTab(model: model)
        case .activity: ActivityTab(model: model)
        }
    }
}

// MARK: - Activity (awake explainer)

/// Answers "why is my Mac awake?" (every process's live power assertions) and
/// "why did Keepresso act?" (the session decision log). Read-only.
private struct ActivityTab: View {
    @Bindable var model: AppModel

    /// Live assertions, refreshed while the pane is visible.
    @State private var assertions: [PowerAssertionInfo] = []
    @State private var unattendedRecords: [UnattendedAuditRecord] = []
    @State private var windowVisible = true
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                let relevant = assertions.filter { $0.effect != nil }
                if relevant.isEmpty {
                    Text("Nothing is holding the Mac awake right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(relevant) { assertion in
                        assertionRow(assertion)
                    }
                }
            } header: {
                Text("Keeping the Mac awake now")
            } footer: {
                Text("Every app's live power assertions, not just Keepresso's, the same data pmset -g assertions prints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                let stats = model.awakeStats
                if stats.totalHeldSeconds < 1 {
                    Text("No held-awake time in the last week.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stats.days.filter { $0.heldSeconds >= 1 }) { day in
                        HStack {
                            Text(day.dayStart, format: .dateTime.month(.abbreviated).day())
                                .font(.callout)
                            Spacer()
                            if let battery = day.batteryConsumed {
                                Text(L("−%d%% battery", battery))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(formatHeld(day.heldSeconds))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Total")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(formatHeld(stats.totalHeldSeconds))
                            .font(.callout.monospacedDigit().weight(.medium))
                    }
                }
            } header: {
                Text("Awake this week")
            } footer: {
                Text("How long Keepresso held the Mac awake each day, from the decision log. Battery drop is shown when both ends of a session had a reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                let events = model.session.log.events
                if events.isEmpty {
                    Text("No session activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events.reversed()) { event in
                        eventRow(event)
                    }
                }
            } header: {
                Text("Keepresso decisions")
            } footer: {
                Text("Why each session started or stopped, newest first. Saved on disk and restored after a relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if unattendedRecords.isEmpty {
                    Text("No Agent or unattended activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(unattendedRecords.reversed()) { record in
                        unattendedRecordRow(record)
                    }
                }
            } header: {
                Text("Agent and unattended log")
            } footer: {
                Text(L("Structured events only, with no automation prompts or command arguments. Saved at %@", model.unattendedAuditLogPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            assertions = model.currentAssertions()
            model.refreshAwakeStats()
            unattendedRecords = model.recentUnattendedAudit()
        }
        // The closed window keeps this content alive (see WindowVisibilityReader),
        // so the poll would keep enumerating assertions unseen. Pause it while
        // hidden and refresh on reopen.
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .onChange(of: windowVisible) { _, visible in
            guard visible else { return }
            assertions = model.currentAssertions()
            model.refreshAwakeStats()
            unattendedRecords = model.recentUnattendedAudit()
        }
        .onReceive(tick) { _ in
            guard windowVisible else { return }
            assertions = model.currentAssertions()
            unattendedRecords = model.recentUnattendedAudit()
        }
    }

    private func formatHeld(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return L("%dh %dm", h, m) }
        return L("%dm", max(m, 0))
    }

    private func assertionRow(_ assertion: PowerAssertionInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(assertion.processName)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(assertion.effect ?? assertion.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !assertion.name.isEmpty {
                Text(assertion.name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 1)
    }

    private func eventRow(_ event: SessionEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.began ? "play.circle.fill" : "stop.circle")
                .foregroundStyle(event.began ? Color.keepressoBrew : Color.secondary)
                .font(.caption)
            Text(event.reason)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer()
            Text(event.date, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func unattendedRecordRow(_ record: UnattendedAuditRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: record.type == .agentLeaseLifecycle
                ? "checkmark.shield"
                : "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(unattendedRecordTitle(record))
                    .font(.callout)
                    .lineLimit(2)
                if let detail = unattendedRecordDetail(record) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text(record.recordedAt, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func unattendedRecordTitle(_ record: UnattendedAuditRecord) -> String {
        if let event = record.leaseLifecycle {
            return L("Agent lease: %@", agentLeaseEventName(event.kind))
        }
        if let event = record.unattendedDiagnostic {
            return L("Unattended work: %@", unattendedEventName(event.kind))
        }
        return L("Unattended event")
    }

    private func agentLeaseEventName(_ kind: AgentLeaseEventKind) -> String {
        switch kind {
        case .acquired: return L("Lease acquired")
        case .heartbeat: return L("Lease heartbeat received")
        case .renewed: return L("Lease renewed")
        case .released: return L("Lease released")
        case .timedOut: return L("Lease timed out")
        case .restored: return L("Lease restored after restart")
        case .changed: return L("Lease changed by another process")
        }
    }

    private func unattendedEventName(_ kind: UnattendedDiagnosticKind) -> String {
        switch kind {
        case .discoveryCompleted: return L("Automation discovery completed")
        case .discoveryFailed: return L("Automation discovery failed")
        case .wakePlanned: return L("Wake planned")
        case .wakePreparationStarted: return L("Wake preparation started")
        case .readinessRetryScheduled: return L("Readiness retry scheduled")
        case .readinessReady: return L("Readiness checks passed")
        case .readinessTimedOut: return L("Readiness timed out")
        case .taskStarted: return L("Unattended task started")
        case .taskSucceeded: return L("Unattended task succeeded")
        case .taskFailed: return L("Unattended task failed")
        case .taskTimedOut: return L("Unattended task timed out")
        case .taskCancelled: return L("Unattended task cancelled")
        case .sleepEligible: return L("System is eligible to sleep")
        case .orchestrationCancelled: return L("Unattended orchestration cancelled")
        }
    }

    private func unattendedRecordDetail(_ record: UnattendedAuditRecord) -> String? {
        if let event = record.leaseLifecycle {
            return event.lease.metadata.task
                ?? event.lease.metadata.agent
                ?? event.lease.metadata.owner
        }
        return record.unattendedDiagnostic?.automationID
            ?? record.unattendedDiagnostic?.taskID
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = LoginItem.isEnabled
    /// The result of the last export/import, shown inline under the buttons.
    @State private var transferNote: TransferNote?

    /// A one-line outcome for the settings backup buttons.
    private struct TransferNote { let message: String; let isError: Bool }

    private var session: SessionController { model.session }

    /// The duration presets offered by the quick-stop shortcut pickers.
    private static let quickStopOptions: [TimeInterval] = [
        5 * 60, 10 * 60, 15 * 60, 20 * 60, 30 * 60, 45 * 60,
        60 * 60, 90 * 60, 2 * 60 * 60, 3 * 60 * 60, 4 * 60 * 60,
    ]

    /// The picker choices for one shortcut row: the shared presets plus the
    /// row's current value when it isn't one of them (an imported custom
    /// duration must not render as an empty selection).
    private func quickStopChoices(including current: TimeInterval) -> [TimeInterval] {
        Self.quickStopOptions.contains(current)
            ? Self.quickStopOptions
            : (Self.quickStopOptions + [current]).sorted()
    }

    /// The first preset not already used, seeding "Add Shortcut".
    private var nextFreeQuickStop: TimeInterval? {
        Self.quickStopOptions.first { !model.quickStopDurations.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Prevent display sleep", isOn: optionBinding(\.preventDisplaySleep))
                Toggle("Prevent system sleep", isOn: optionBinding(\.preventSystemSleep))
            } header: {
                sectionHeader("Keep awake", info: L("Two independent switches. Preventing system sleep keeps the Mac itself running: work finishes, downloads complete, and it stays reachable over the network, while the screen is still free to turn off. Preventing display sleep also keeps the screen lit, which is what you want for a dashboard or a video, and what drains a battery fastest. Most setups want system sleep prevented and display sleep left alone."))
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        LoginItem.setEnabled(newValue)
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
                Toggle("Start keep-awake on launch", isOn: Binding(
                    get: { model.startOnLaunch },
                    set: { model.startOnLaunch = $0 }
                ))
            } header: {
                sectionHeader("Startup", info: L("\u{201C}Launch at login\u{201D} starts Keepresso itself when you log in, so the cup is always in the menu bar. \u{201C}Start keep-awake on launch\u{201D} goes further and begins a session right away, using the default duration, for an always-on Mac that shouldn't need a rule to stay up. It's ignored while triggers are controlling activation, since your conditions decide then."))
            } footer: {
                sectionFooter("Starts a session as soon as Keepresso launches.")
            }
            Section {
                LabeledContent("Toggle shortcut") {
                    ShortcutRecorder(shortcut: Binding(
                        get: { model.hotKey },
                        set: { model.hotKey = $0 }
                    ))
                }
            } header: {
                sectionHeader("Global shortcut", info: L("System-wide, so it starts or stops keep-awake whatever app you're in. It needs at least one modifier key (Command, Option, Control, or Shift) so it can't fire while you're typing. Recording it asks for no Accessibility or Input Monitoring permission."))
            } footer: {
                sectionFooter("Starts or stops keep-awake from any app.")
            }
            Section {
                Picker("App language", selection: Binding(
                    get: { AppLanguage.current },
                    set: { switchLanguage(to: $0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
            } header: {
                sectionHeader("Language", info: L("Fifteen languages are available. Changing this relaunches Keepresso, so the menu, every window, and notifications all switch together instead of drifting apart. Set it back to \u{201C}Follow System\u{201D} to follow your Mac's language again."))
            } footer: {
                sectionFooter("Keepresso follows your system language by default.")
            }
            Section {
                LabeledContent("See-through") {
                    HStack(spacing: 8) {
                        Image(systemName: "snowflake")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(
                            value: Binding(
                                get: { Double(model.glassClarity) },
                                set: { model.glassClarity = Int($0) }
                            ),
                            in: 0...100,
                            step: 5
                        )
                        .frame(width: 180)
                        .accessibilityLabel(L("Window transparency"))
                        Image(systemName: "circle.dotted")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(verbatim: "\(model.glassClarity)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 38, alignment: .trailing)
                    }
                }
            } header: {
                sectionHeader("Appearance", info: L("How see-through the menu-bar dropdown is. Frosty (0%) backs its glass with blur and a wash of the window color, so text stays crisp on any wallpaper. Sliding toward 100% thins that backing away until the panel is the system's bare Liquid Glass, letting the desktop shine through, with some contrast cost on busy or very dark wallpapers. Changes apply instantly, only to the dropdown (windows like this one keep their standard look), and the system's Reduce Transparency accessibility setting always wins."))
            } footer: {
                sectionFooter("The menu-bar dropdown's glass, from frosty to clear Liquid Glass.")
            }
            // High up on purpose: this is the one-time set-and-forget step that
            // makes every privileged switch below (and AWDL pausing) silent.
            Section {
                HelperStatusRows(model: model)
            } header: {
                sectionHeader("Administrator helper", info: L("Install and approve the helper before relying on unattended wake or closed-lid work."))
            } footer: {
                sectionFooter("Handles the privileged switches for Keepresso, with no password prompts.")
            }
            Section {
                Toggle("Keep me active", isOn: Binding(
                    get: { model.simulateUserActivity },
                    set: { model.simulateUserActivity = $0 }
                ))
            } header: {
                sectionHeader("Presence", info: L("Keeping the Mac awake stops it sleeping, but it doesn't reset app-level or enterprise idle detection: remote-desktop and VDI sessions, meeting presence (Teams, Slack), and corporate idle-logout can still mark you away or log you out. This tells macOS you're active as well, which those do notice. It only steps in once you've been idle a few seconds, so it never nudges the pointer while you're using the Mac or gaming. Off by default, and some managed Macs flag simulated activity, so check your policy first."))
            } footer: {
                sectionFooter("Also tells macOS you're active, so you aren't marked away.")
            }
            Section {
                Toggle("Show countdown in menu bar", isOn: Binding(
                    get: { model.showCountdownInMenuBar },
                    set: { model.showCountdownInMenuBar = $0 }
                ))
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Shows the remaining time next to the menu-bar icon during a timed session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(model.quickStopDurations.enumerated()), id: \.offset) { index, duration in
                    HStack {
                        Picker(L("Shortcut %d", index + 1), selection: Binding(
                            get: { duration },
                            set: { newValue in
                                var durations = model.quickStopDurations
                                durations[index] = newValue
                                model.quickStopDurations = durations
                            }
                        )) {
                            ForEach(quickStopChoices(including: duration), id: \.self) { option in
                                Text(MenuBarContent.shortDuration(option)).tag(option)
                            }
                        }
                        Button {
                            var durations = model.quickStopDurations
                            durations.remove(at: index)
                            model.quickStopDurations = durations
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("Remove shortcut"))
                    }
                }
                Button("Add Shortcut") {
                    guard let next = nextFreeQuickStop else { return }
                    model.quickStopDurations = model.quickStopDurations + [next]
                }
                .disabled(model.quickStopDurations.count >= KeepressoSettings.maxQuickStopDurations
                          || nextFreeQuickStop == nil)
            } header: {
                sectionHeader("Quick stop shortcuts", info: L("While a session runs, the menu shows these as one-click \u{201C}Stop in\u{201D} buttons. Clicking one converts the running session to end that much later, so the Mac goes back to sleeping on its own without you remembering to switch it off. It continues the session rather than restarting it, and clicking another button simply replaces the countdown. Up to four, and the list stays sorted."))
            } footer: {
                sectionFooter("One-click \u{201C}Stop in\u{201D} buttons shown in the menu while a session runs.")
            }
            if model.machineHasBattery {
                Section {
                    Toggle("Pause on low battery", isOn: Binding(
                        get: { model.batteryAutoPauseEnabled },
                        set: { model.batteryAutoPauseEnabled = $0 }
                    ))
                    if model.batteryAutoPauseEnabled {
                        LabeledContent("Below") {
                            BatteryThresholdSlider(percent: Binding(
                                get: { model.pauseBelowBatteryPercent },
                                set: { model.pauseBelowBatteryPercent = $0 }
                            ))
                        }
                    }
                } header: {
                    sectionHeader("Battery", info: L("A safety net for a session you forget about. If the charge falls this low, Keepresso pauses the session and lets the Mac sleep, even mid-session, and tells you why in a notification. The menu-bar cup shows the pause as a last sip of low-power yellow. Plugging in resumes it on its own. This is the same slider as the one in the menu, so the two always agree."))
                } footer: {
                    sectionFooter("Lets the Mac sleep once charge drops below this level.")
                }
            }
            // The thermal net is a lid-closed safety: a desktop has no lid to
            // trap heat behind, so it gets no section (battery is the same
            // laptop proxy the closed-display wording uses below).
            if model.machineHasBattery {
                thermalSection
            }
            closedDisplaySection
            Section {
                HStack {
                    Button("Export Settings\u{2026}") { exportSettings() }
                    Button("Import Settings\u{2026}") { importSettings() }
                }
                if let note = transferNote {
                    Label(note.message, systemImage: note.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(note.isError ? .orange : .secondary)
                }
            } header: {
                sectionHeader("Backup", info: L("Writes everything you've configured (settings, trigger rules, and presets) to a JSON file, to keep as a backup or to carry to another Mac. The file is version-stamped and checked on import, so a file from a newer Keepresso is refused rather than half-read. Importing replaces your current configuration and ends any running session."))
            } footer: {
                sectionFooter("Save your settings, triggers, and presets to a JSON file.")
            }
            Section {
                Button("Show Welcome Screen\u{2026}") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: KeepressoApp.welcomeWindowID)
                }
            } header: {
                Text("Welcome")
            } footer: {
                Text("Reopen the first-run welcome, with quick one-click setup for how you use your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Slide the conditional rows (battery threshold, error notes) in and
        // out instead of popping them.
        .animation(.snappy(duration: 0.25), value: model.batteryAutoPauseEnabled)
        .animation(.snappy(duration: 0.25), value: model.thermalSafety)
        .animation(.snappy(duration: 0.25), value: model.fanDryRun.phase)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayError)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayAutoError)
        .onAppear { model.refreshClosedDisplay() }
    }

    /// The fan boost strength a fresh "Boost fans first" toggle starts at.
    private static let defaultFanBoostPercent = 80

    /// The thermal safety net: with the lid closed and the sleep override
    /// holding the Mac awake, watch a heat signal, and once it stays over the
    /// threshold for the sustain window, pause the session and lift the
    /// override so the Mac can sleep and cool. The battery pause's sibling,
    /// so it sits right beside it. Laptops only: the arming condition needs
    /// a lid.
    private var thermalSection: some View {
        Section {
            Toggle("Pause when running hot", isOn: Binding(
                get: { model.thermalSafety != nil },
                set: { model.thermalSafety = $0 ? ThermalSafetyConfig() : nil }
            ))
            if let config = model.thermalSafety {
                Picker("Watch", selection: Binding(
                    get: { if case .sensors = config.mode { return 1 } else { return 0 } },
                    set: { kind in
                        var updated = config
                        updated.mode = kind == 1
                            ? .sensors(ids: [], celsius: ThermalSafetyConfig.celsiusRange.upperBound - 15)
                            : .pressure(atOrAbove: .serious)
                        model.thermalSafety = updated
                    }
                )) {
                    Text("System thermal pressure").tag(0)
                    Text("Temperature sensors").tag(1)
                }
                switch config.mode {
                case .pressure(let level):
                    Picker("At or above", selection: Binding(
                        get: { level },
                        set: { newLevel in
                            var updated = config
                            updated.mode = .pressure(atOrAbove: newLevel)
                            model.thermalSafety = updated
                        }
                    )) {
                        // Labels come from Core so the level names localize once.
                        ForEach([ThermalPressureLevel.fair, .serious, .critical], id: \.self) { level in
                            Text(verbatim: level.label).tag(level)
                        }
                    }
                case .sensors(let ids, let celsius):
                    ThermalSensorPicker(model: model, selectedIDs: Binding(
                        get: { ids },
                        set: { newIDs in
                            var updated = config
                            updated.mode = .sensors(ids: newIDs, celsius: celsius)
                            model.thermalSafety = updated
                        }
                    ))
                    LabeledContent("Above") {
                        TemperatureThresholdSlider(celsius: Binding(
                            get: { celsius },
                            set: { newCelsius in
                                var updated = config
                                updated.mode = .sensors(ids: ids, celsius: newCelsius)
                                model.thermalSafety = updated
                            }
                        ))
                    }
                }
                Picker("Sustained for", selection: Binding(
                    get: { Int(config.sustainSeconds) },
                    set: { seconds in
                        var updated = config
                        updated.sustainSeconds = TimeInterval(seconds)
                        model.thermalSafety = updated
                    }
                )) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                // Everything above (watching, thresholds, the pause itself)
                // is unprivileged and always works. Everything below is the
                // helper-only territory: fan writes are root-enforced by the
                // SMC, and the automatic closed-display lift at the pause
                // stage must be prompt-free. Without the helper the whole
                // group collapses to one row that says what's locked and
                // offers the install, instead of live-looking toggles with
                // warning captions under each.
                if model.helperInstalled {
                    if model.machineHasFans {
                        Toggle("Boost fans first", isOn: Binding(
                            get: { config.fanBoostPercent != nil },
                            set: { boost in
                                var updated = config
                                updated.fanBoostPercent = boost ? Self.defaultFanBoostPercent : nil
                                model.thermalSafety = updated
                            }
                        ))
                        if let percent = config.fanBoostPercent {
                            LabeledContent("To") {
                                FanBoostSlider(percent: Binding(
                                    get: { percent },
                                    set: { newPercent in
                                        var updated = config
                                        updated.fanBoostPercent = newPercent
                                        model.thermalSafety = updated
                                    }
                                ))
                            }
                            FanTestRows(model: model)
                        }
                    }
                } else {
                    ThermalHelperLockedRow(model: model)
                }
            }
        } header: {
            sectionHeader("Thermal", info: L("A safety net for a Mac left running with the lid closed, slid into a bag with a session still holding it awake. It acts only in that trapped state: lid shut, with \u{201C}Keep awake with the lid closed\u{201D} overriding sleep. Watch macOS's own thermal pressure (works everywhere, \u{201C}Serious\u{201D} is where throttling bites) or specific temperature sensors, and if the reading stays over the threshold for the chosen time, Keepresso escalates: first, optionally, it boosts the fans (never below what the system chose, needs the administrator helper), and if it stays hot for the same time again, it pauses the session and switches the sleep override off, so the Mac can finally sleep and cool, telling you why in a notification. Opening the lid, or readings recovering, undoes everything: fan control returns to the system, the override comes back, and the session resumes. Die sensors on modern Macs routinely run at 90-100 \u{00B0}C under load, so thresholds around 95-100 \u{00B0}C are sensible."))
        } footer: {
            sectionFooter("If the Mac runs hot with the lid closed, the session pauses so it can sleep and cool down.")
        }
    }

    /// The pmset disablesleep switch. On a laptop it's "closed-display mode"
    /// (keep running with the lid shut); a desktop has no lid, so the same
    /// switch is presented as a hard "disable sleep" override. Shown on both,
    /// so a desktop that latched the setting always has a way to unlatch it.
    private var closedDisplaySection: some View {
        Section {
            Toggle(model.machineHasBattery ? "Keep awake with the lid closed" : "Disable system sleep",
                   isOn: Binding(
                get: { model.closedDisplayEnabled },
                set: { model.setClosedDisplay($0) }
            ))
            .disabled(model.closedDisplayBusy
                || (!model.closedDisplayEnabled
                    && model.batteryAutoPauseEnabled
                    && !model.helperInstalled))
            if model.closedDisplayBusy && !model.helperInstalled {
                AdminAuthNote(purpose: model.machineHasBattery
                    ? L("keep the Mac awake with the lid closed")
                    : L("disable system sleep"))
            }
            if let error = model.closedDisplayError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Only while brewing", isOn: Binding(
                get: { model.closedDisplayOnlyWhileBrewing },
                set: { model.closedDisplayOnlyWhileBrewing = $0 }
            ))
            .disabled(model.closedDisplayAutoBusy
                || (!model.helperInstalled && !model.closedDisplayOnlyWhileBrewing))
            if !model.helperInstalled {
                Label(
                    L("Install and approve the helper before relying on unattended wake or closed-lid work."),
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = model.closedDisplayAutoError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            model.machineHasBattery
                ? sectionHeader("Closed-display mode", info: L("Keeps the Mac running with the lid shut and no external display. This flips a system setting that needs administrator rights: silent with the administrator helper installed (Preferences ▸ General), otherwise macOS asks for your password."))
                : sectionHeader("Disable sleep", info: L("Stops the Mac from sleeping at all, even with no session running. This flips a system setting that needs administrator rights: silent with the administrator helper installed (Preferences ▸ General), otherwise macOS asks for your password."))
        } footer: {
            model.machineHasBattery
                ? sectionFooter("Keeps running with the lid shut and no external display.")
                : sectionFooter("Stops the Mac from sleeping at all until you turn it off.")
        }
    }

    /// Persist a new language choice and relaunch so every surface switches
    /// at once (the `AppleLanguages` override only resolves at process start).
    private func switchLanguage(to language: AppLanguage) {
        guard language != AppLanguage.current else { return }
        language.apply()
        AppLanguage.relaunch()
    }

    // MARK: - Settings backup

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = L("Export Keepresso Settings")
        panel.nameFieldStringValue = "Keepresso Settings.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportSettingsData().write(to: url)
            transferNote = TransferNote(message: L("Exported to %@.", url.lastPathComponent), isError: false)
        } catch {
            transferNote = TransferNote(message: L("Couldn't export settings: %@", error.localizedDescription), isError: true)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = L("Import Keepresso Settings")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.importSettings(from: Data(contentsOf: url))
            transferNote = TransferNote(message: L("Settings imported."), isError: false)
        } catch let error as SettingsTransferError {
            transferNote = TransferNote(message: Self.message(for: error), isError: true)
        } catch {
            transferNote = TransferNote(message: L("Couldn't read the file: %@", error.localizedDescription), isError: true)
        }
    }

    private static func message(for error: SettingsTransferError) -> String {
        switch error {
        case .unrecognizedFile:
            return L("That file isn't a Keepresso settings export.")
        case .unsupportedVersion:
            return L("That export was made by a newer version of Keepresso.")
        }
    }

    private func optionBinding(_ keyPath: WritableKeyPath<SleepPreventionOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { session.options[keyPath: keyPath] },
            set: { newValue in model.updateOptions { $0[keyPath: keyPath] = newValue } }
        )
    }
}

// MARK: - Triggers

private struct TriggersTab: View {
    @Bindable var model: AppModel
    @State private var newPresetName = ""

    var body: some View {
        Form {
            Section {
                Toggle("Activate by triggers", isOn: Binding(
                    get: { model.triggersEnabled },
                    set: { model.triggersEnabled = $0 }
                ))
                if model.triggersEnabled && model.triggersPaused {
                    HStack(spacing: 6) {
                        Text("Currently paused from the menu bar.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Resume") { model.resumeTriggers() }
                            .font(.caption)
                    }
                }
            } header: {
                sectionHeader("Triggers", info: L("A trigger is a condition Keepresso watches, checked once a second. With triggers on, they take over: Keepresso starts brewing the moment your conditions are met and stops when they aren't, so you never leave the Mac awake by accident. The manual switch in the menu steps aside while they're active. \u{201C}Pause Triggers\u{201D} in the menu bar stops them temporarily without touching your rules."))
            } footer: {
                sectionFooter("The listed conditions control the session instead of the manual switch.")
            }
            if model.triggersEnabled {
                Section {
                    presetRows
                } header: {
                    sectionHeader("Presets", info: L("A preset is a named bundle of trigger rules you apply in one click. The built-ins cover common setups (AI Agent, Meetings, Cloud Gaming, Remote Control, and more), and applying one replaces your current rules. Save your own rules under a name to reuse them or move between setups. Renaming a built-in makes it yours, and Keepresso stops updating it. \u{201C}Restore default presets\u{201D} brings back any built-in you removed."))
                }
                Section {
                    RulesView(model: model)
                } header: {
                    RulesView.combineHeader(model: model)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.25), value: model.triggersEnabled)
        .animation(.snappy(duration: 0.25), value: model.triggersPaused)
    }

    @ViewBuilder
    private var presetRows: some View {
        HStack {
            Menu {
                ForEach(model.presets) { preset in
                    Button(preset.displayName) { model.applyPreset(preset) }
                }
                if !model.presets.isEmpty { Divider() }
                ForEach(model.presets) { preset in
                    Button(L("Remove \u{201C}%@\u{201D}", preset.displayName), role: .destructive) {
                        model.removePreset(preset)
                    }
                }
                if !model.missingBuiltInPresets.isEmpty {
                    Divider()
                    Button("Restore default presets") { model.restoreDefaultPresets() }
                }
            } label: {
                Label("Apply or remove", systemImage: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }

        HStack(spacing: 6) {
            TextField("Save current rules as\u{2026}", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(savePreset)
            Button("Save") { savePreset() }
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty || model.rules.isEmpty)
        }
    }

    private func savePreset() {
        model.saveCurrentRulesAsPreset(named: newPresetName)
        newPresetName = ""
    }
}

// MARK: - Reminder

private struct ReminderTab: View {
    @Bindable var model: AppModel

    private static let options: [(label: String, interval: TimeInterval)] = [
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60),
        ("2 hours", 2 * 60 * 60),
        ("4 hours", 4 * 60 * 60),
        ("8 hours", 8 * 60 * 60),
    ]

    /// Lead times for the "ending soon" heads-up.
    private static let noticeOptions: [(label: String, interval: TimeInterval)] = [
        ("1 minute before", 60),
        ("2 minutes before", 2 * 60),
        ("5 minutes before", 5 * 60),
        ("10 minutes before", 10 * 60),
    ]

    /// The picker rows: the presets plus the current value when it isn't one
    /// of them, so an imported custom lead time doesn't render as an empty
    /// selection.
    private func noticeChoices(including current: TimeInterval) -> [TimeInterval] {
        let presets = Self.noticeOptions.map(\.interval)
        return presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    private func noticeLabel(_ interval: TimeInterval) -> String {
        if let preset = Self.noticeOptions.first(where: { $0.interval == interval }) {
            return L(preset.label)
        }
        return L("%@ before", MenuBarContent.shortDuration(interval))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Remind me it's still on", isOn: Binding(
                    get: { model.reminderEnabled },
                    set: { model.reminderEnabled = $0 }
                ))
                if model.reminderEnabled {
                    Picker(model.reminderRepeats ? L("Every") : L("After"), selection: Binding(
                        get: { model.reminderAfter },
                        set: { model.reminderAfter = $0 }
                    )) {
                        ForEach(Self.options, id: \.interval) { option in
                            Text(L(option.label)).tag(option.interval)
                        }
                    }
                    Toggle("Repeat the reminder", isOn: Binding(
                        get: { model.reminderRepeats },
                        set: { model.reminderRepeats = $0 }
                    ))
                    Toggle("Play a sound", isOn: Binding(
                        get: { model.reminderSound },
                        set: { model.reminderSound = $0 }
                    ))
                }
            } header: {
                sectionHeader("Reminder", info: L("A nudge while a session is running, so a Mac left awake doesn't stay awake all night unnoticed. Left off, a one-time reminder tells you once, after the session has run this long. \u{201C}Repeat\u{201D} tells you again at every interval until you stop the session. This never stops anything itself, it only reminds you, and the sound is optional. If you'd rather the session end on its own, use a timed session or a quick-stop button instead."))
            } footer: {
                Text(model.reminderRepeats
                     ? L("A recurring notification every interval while a session runs, so a Mac left awake keeps reminding you.")
                     : L("A one-time notification once a session has run this long, in case you forget the Mac is awake."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Section {
                Toggle("Notify when a session ends", isOn: Binding(
                    get: { model.notifyOnEnd },
                    set: { model.notifyOnEnd = $0 }
                ))
                Toggle("Warn before a timed session ends", isOn: Binding(
                    get: { model.endingSoonEnabled },
                    set: { model.endingSoonEnabled = $0 }
                ))
                if model.endingSoonEnabled {
                    Picker("Warn", selection: Binding(
                        get: { model.endingSoonNotice },
                        set: { model.endingSoonNotice = $0 }
                    )) {
                        ForEach(noticeChoices(including: model.endingSoonNotice), id: \.self) { interval in
                            Text(noticeLabel(interval)).tag(interval)
                        }
                    }
                }
            } header: {
                sectionHeader("Session end", info: L("These cover the times a session ends without you: a timer expiring, or trigger conditions dropping. Stopping it yourself stays silent, since you already know. The warning is a heads-up a few minutes before a timed session runs out, so you can extend it before the Mac drops off. Actions that put the Mac to sleep live under Automation."))
            } footer: {
                sectionFooter("Notifications fire when a session ends on its own, not when you stop it yourself.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.25), value: model.reminderEnabled)
        .animation(.snappy(duration: 0.25), value: model.reminderRepeats)
        .animation(.snappy(duration: 0.25), value: model.endingSoonEnabled)
    }
}

// MARK: - Automation (end action + outbound hooks + wake)

private struct AutomationTab: View {
    @Bindable var model: AppModel
    @State private var draft: HookDraft?
    @State private var editingID: UUID?

    var body: some View {
        Form {
            unattendedPolicySection
            codexAutomationSection
            endActionSection
            scheduledWakeSection
            eventHooksSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.25), value: model.endAction)
        .animation(.snappy(duration: 0.25), value: model.unattendedPowerPolicy)
        .animation(.snappy(duration: 0.25), value: model.codexAutomation)
        .animation(.snappy(duration: 0.25), value: model.wakeSchedule != nil)
        .animation(.snappy(duration: 0.25), value: model.helperInstalled)
        .animation(.snappy(duration: 0.25), value: model.helper.awaitingApproval)
        .animation(.snappy(duration: 0.25), value: model.helper.daemonOutdated)
        .sheet(item: $draft) { draft in
            HookEditorSheet(
                draft: draft,
                title: editingID == nil ? L("Add Hook") : L("Edit Hook"),
                onCancel: {
                    model.hooksEditing = false
                    self.draft = nil
                    editingID = nil
                },
                onSave: { saved in
                    commit(saved)
                    model.hooksEditing = false
                    self.draft = nil
                    editingID = nil
                }
            )
        }
        .onAppear {
            model.helper.refresh()
            model.refreshSystemWakeState()
        }
        .onDisappear {
            model.hooksEditing = false
        }
    }

    // MARK: End action

    private var unattendedPolicySection: some View {
        Section {
            Toggle("Lock screen before unattended work", isOn: Binding(
                get: { model.unattendedPowerPolicy.lockScreenOnStart },
                set: { enabled in
                    var policy = model.unattendedPowerPolicy
                    policy.lockScreenOnStart = enabled
                    model.unattendedPowerPolicy = policy
                }
            ))
            Toggle("Turn display off before unattended work", isOn: Binding(
                get: { model.unattendedPowerPolicy.sleepDisplayOnStart },
                set: { enabled in
                    var policy = model.unattendedPowerPolicy
                    policy.sleepDisplayOnStart = enabled
                    model.unattendedPowerPolicy = policy
                }
            ))
            Picker("After all unattended work", selection: Binding(
                get: { model.unattendedPowerPolicy.endAction },
                set: { action in
                    var policy = model.unattendedPowerPolicy
                    policy.endAction = action
                    model.unattendedPowerPolicy = policy
                }
            )) {
                ForEach(SessionEndAction.allCases, id: \.self) { action in
                    Text(action.label).tag(action)
                }
            }
        } header: {
            sectionHeader("Unattended Agent work", info: L("Scheduled and Agent-driven jobs use a separate secure policy. By default Keepresso locks the login session, turns off the display while preserving the system assertion, and sleeps the Mac after the final job finishes."))
        } footer: {
            sectionFooter("These defaults do not change interactive keep-awake sessions.")
        }
    }

    private var endActionSection: some View {
        Section {
            Picker("On session end", selection: Binding(
                get: { model.endAction },
                set: { model.endAction = $0 }
            )) {
                ForEach(SessionEndAction.allCases, id: \.self) { action in
                    Text(action.label).tag(action)
                }
            }
            if let note = endActionAvailabilityNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            sectionHeader("After the session ends", info: L("When a keep-awake session ends on its own (a timer expiring, or trigger conditions dropping), Keepresso can put the display to sleep, lock the screen, start the screen saver, or sleep the Mac. Off by default so a timed session never surprises you. Manual stops, and the battery and thermal safety pauses, never run this action. A brief debounce cancels it if the session restarts right away."))
        } footer: {
            sectionFooter("Fires a few seconds after a natural end, not on a manual stop or a safety pause.")
        }
    }

    // MARK: Codex automation

    private var codexAutomationSection: some View {
        Section {
            if model.wakeHelperGate == .ready {
                Toggle("Follow local Codex automations", isOn: Binding(
                    get: { model.codexAutomation.enabled },
                    set: { enabled in updateCodex { $0.enabled = enabled } }
                ))
                if model.codexAutomation.enabled {
                    Picker("Wake before run", selection: Binding(
                        get: { model.codexAutomation.wakeLeadTime },
                        set: { value in updateCodex { $0.wakeLeadTime = value } }
                    )) {
                        Text(L("1 minute")).tag(60 as TimeInterval)
                        Text(L("5 minutes")).tag(5 * 60 as TimeInterval)
                        Text(L("10 minutes")).tag(10 * 60 as TimeInterval)
                        Text(L("15 minutes")).tag(15 * 60 as TimeInterval)
                    }
                    Picker("Readiness timeout", selection: Binding(
                        get: { model.codexAutomation.readinessTimeout },
                        set: { value in updateCodex { $0.readinessTimeout = value } }
                    )) {
                        Text(L("1 minute")).tag(60 as TimeInterval)
                        Text(L("2 minutes")).tag(2 * 60 as TimeInterval)
                        Text(L("5 minutes")).tag(5 * 60 as TimeInterval)
                        Text(L("10 minutes")).tag(10 * 60 as TimeInterval)
                    }
                    Picker("Wait for Agent lease", selection: Binding(
                        get: { model.codexAutomation.leaseHandoffTimeout },
                        set: { value in updateCodex { $0.leaseHandoffTimeout = value } }
                    )) {
                        Text(L("5 minutes")).tag(5 * 60 as TimeInterval)
                        Text(L("10 minutes")).tag(10 * 60 as TimeInterval)
                        Text(L("20 minutes")).tag(20 * 60 as TimeInterval)
                        Text(L("30 minutes")).tag(30 * 60 as TimeInterval)
                    }
                    Toggle("Require network", isOn: Binding(
                        get: { model.codexAutomation.requireNetwork },
                        set: { enabled in updateCodex { $0.requireNetwork = enabled } }
                    ))
                    Toggle("Require external power", isOn: Binding(
                        get: { model.codexAutomation.requireExternalPower },
                        set: { enabled in updateCodex { $0.requireExternalPower = enabled } }
                    ))
                    if model.machineHasBattery, !model.codexAutomation.requireExternalPower {
                        Toggle("Require minimum battery", isOn: Binding(
                            get: { model.codexAutomation.minimumBatteryPercentage != nil },
                            set: { enabled in
                                updateCodex { $0.minimumBatteryPercentage = enabled ? 30 : nil }
                            }
                        ))
                        if let minimum = model.codexAutomation.minimumBatteryPercentage {
                            Picker("Minimum battery", selection: Binding(
                                get: { minimum },
                                set: { value in
                                    updateCodex { $0.minimumBatteryPercentage = value }
                                }
                            )) {
                                ForEach([20, 30, 40, 50, 60, 80], id: \.self) { percent in
                                    Text(L("%d%%", percent)).tag(percent)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("%d active local automation(s)", model.codexAutomations.count))
                        if let plan = model.codexWakePlanning.wakePlan {
                            Text(L("Next run: %@", plan.scheduledRun.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )))
                            if let wake = plan.scheduledWake {
                                Text(L("Next wake: %@", wake.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )))
                            } else {
                                Text(L("Preparation window is open now"))
                            }
                        } else {
                            Text(L("No enabled local Codex automation found"))
                        }
                        if model.codexAutomationIssueCount > 0 {
                            Text(L("%d automation file(s) could not be used", model.codexAutomationIssueCount))
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    LabeledContent("MCP server") {
                        Text(model.bundledMCPServerPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Reveal Keepresso Agent Skill") {
                        model.revealBundledAgentSkill()
                    }
                }
            } else {
                if model.codexAutomation.enabled {
                    Label(
                        L("Codex automation wake is saved but inactive until the administrator helper is ready."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                    Button("Turn Off Codex Automation Wake", role: .destructive) {
                        updateCodex { $0.enabled = false }
                    }
                }
                AutomationHelperLockedRow(model: model, context: .wakeSchedule)
            }
        } header: {
            sectionHeader("Codex automation wake", info: L("Keepresso extracts only scheduling metadata from enabled local Codex automations. It wakes the Mac before the nearest run, waits for power, battery, network, and the Codex app, then holds the Mac until the Agent acquires an explicit lease or the handoff times out."))
        } footer: {
            sectionFooter("Automation prompt text is discarded during parsing and is never retained, displayed, or logged. Configure the Keepresso Skill or MCP server so each Agent acquires, renews, and releases its own lease.")
        }
    }

    private func updateCodex(_ body: (inout CodexAutomationSettings) -> Void) {
        var policy = model.codexAutomation
        body(&policy)
        model.codexAutomation = policy
    }

    /// Contextual note under the end-action picker: only when the chosen
    /// action has a privilege or TCC catch, so "Do nothing" stays quiet.
    private var endActionAvailabilityNote: String? {
        switch model.endAction {
        case .none, .sleepDisplay, .startScreensaver:
            return nil
        case .lockScreen:
            return L("Locks via System Events. macOS may ask once for Automation access for Keepresso.")
        case .sleepMac:
            if model.helperInstalled && !model.helper.daemonOutdated && !model.helper.awaitingApproval {
                return L("Sleeps the Mac through the administrator helper (instant, no extra prompts).")
            }
            if model.helper.awaitingApproval {
                return L("The helper is waiting for approval in System Settings. Until then, sleep falls back to System Events, which may ask for Automation access once.")
            }
            if model.helper.daemonOutdated {
                return L("The helper is updating itself. Until that finishes, sleep falls back to System Events, which may ask for Automation access once.")
            }
            return L("Without the administrator helper, sleep uses System Events and may ask for Automation access once. Install the helper under Preferences ▸ General for instant, silent sleep.")
        }
    }

    // MARK: Scheduled wake

    private var scheduledWakeSection: some View {
        Section {
            switch model.wakeHelperGate {
            case .ready:
                wakeScheduleEditor
            case .needsHelper, .awaitingApproval, .helperUpdating:
                if model.wakeSchedule != nil {
                    // Settings survived without a live helper: say so, do not
                    // pretend the controls are live, offer clear + unlock.
                    Label {
                        Text(L("A wake schedule is saved, but it is not active on this Mac until the administrator helper is ready. The system will not wake from this plan."))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .foregroundStyle(.secondary)
                    wakeScheduleSummary
                    Button("Turn Off Wake Schedule", role: .destructive) {
                        model.wakeSchedule = nil
                    }
                }
                AutomationHelperLockedRow(model: model, context: .wakeSchedule)
            }
        } header: {
            sectionHeader("Scheduled wake", info: L("Wake the Mac at a set time through the administrator helper (pmset schedule / repeat), then optionally start a keep-awake session so it does not fall back asleep before the job runs. Pair with an end-of-session action above for wake, work, sleep. Scheduled wake is reliable on AC power. On battery the firmware may skip it. macOS only allows one system-wide repeating power schedule, so enabling ours replaces whatever was there. The controls stay locked until the helper is installed and ready, the same rule as the thermal fan boost."))
        } footer: {
            wakeScheduleFooter
        }
    }

    @ViewBuilder
    private var wakeScheduleEditor: some View {
        Toggle("Wake schedule", isOn: Binding(
            get: { model.wakeSchedule != nil },
            set: { on in
                // Enabling is only offered when the helper is ready; the
                // model also refuses a bare enable without it.
                model.wakeSchedule = on ? (model.wakeSchedule ?? WakeScheduleConfig()) : nil
            }
        ))
        if model.wakeSchedule != nil {
            Toggle("One-shot wake", isOn: Binding(
                get: { model.wakeSchedule?.oneShot != nil },
                set: { on in
                    updateWake {
                        $0.oneShot = on
                            ? ($0.oneShot ?? Date().addingTimeInterval(3600))
                            : nil
                    }
                }
            ))
            if model.wakeSchedule?.oneShot != nil {
                DatePicker(
                    "Wake at",
                    selection: Binding(
                        get: { model.wakeSchedule?.oneShot ?? Date() },
                        set: { date in updateWake { $0.oneShot = date } }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
            Toggle("Repeat daily / weekly", isOn: Binding(
                get: { model.wakeSchedule?.repeatingEnabled ?? false },
                set: { on in updateWake { $0.repeatingEnabled = on } }
            ))
            if model.wakeSchedule?.repeatingEnabled == true {
                DatePicker(
                    "Time",
                    selection: Binding(
                        get: {
                            // Wall-clock components on both sides, never
                            // elapsed time since midnight: on a DST
                            // transition day the two differ by an hour, and
                            // pmset takes wall-clock time.
                            let secs = model.wakeSchedule?.repeatSecondsFromMidnight ?? 0
                            let calendar = Calendar.current
                            return calendar.date(
                                bySettingHour: secs / 3600,
                                minute: (secs % 3600) / 60,
                                second: secs % 60,
                                of: calendar.startOfDay(for: Date())
                            ) ?? Date()
                        },
                        set: { date in
                            let parts = Calendar.current.dateComponents(
                                [.hour, .minute], from: date)
                            updateWake {
                                $0.repeatSecondsFromMidnight =
                                    (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60
                            }
                        }
                    ),
                    displayedComponents: [.hourAndMinute]
                )
                Text(L("Uses every day (MTWRFSU). macOS allows only one system-wide repeating power schedule."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Start keep-awake on wake", isOn: Binding(
                get: { model.wakeSchedule?.startSessionOnWake ?? true },
                set: { on in updateWake { $0.startSessionOnWake = on } }
            ))
            if model.wakeSchedule?.startSessionOnWake == true {
                Picker("Session length", selection: Binding(
                    get: { model.wakeSchedule?.sessionDurationSeconds ?? 0 },
                    set: { value in
                        updateWake { $0.sessionDurationSeconds = value > 0 ? value : nil }
                    }
                )) {
                    Text(L("Indefinite")).tag(TimeInterval(0))
                    Text(L("30 minutes")).tag(30 * 60 as TimeInterval)
                    Text(L("1 hour")).tag(60 * 60 as TimeInterval)
                    Text(L("2 hours")).tag(2 * 60 * 60 as TimeInterval)
                    Text(L("4 hours")).tag(4 * 60 * 60 as TimeInterval)
                }
                Text(L("When the Mac wakes near this schedule, Keepresso starts a session so it does not fall back asleep. Works best with triggers off for that window, or with a trigger that stays satisfied."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.wakeSchedule?.isActive != true {
                Label(L("Turn on a one-shot time, a repeating time, or both. With neither, nothing is installed on the system."), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Compact read-only summary when the schedule is saved but inactive.
    @ViewBuilder
    private var wakeScheduleSummary: some View {
        if let config = model.wakeSchedule {
            VStack(alignment: .leading, spacing: 2) {
                if let oneShot = config.oneShot {
                    Text(L("One-shot: %@", oneShot.formatted(date: .abbreviated, time: .shortened)))
                }
                if config.repeatingEnabled {
                    Text(L("Repeating: every day at %@", config.repeatTimeString))
                }
                if config.startSessionOnWake {
                    Text(L("Starts keep-awake on wake"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func updateWake(_ body: (inout WakeScheduleConfig) -> Void) {
        guard var config = model.wakeSchedule else { return }
        body(&config)
        model.wakeSchedule = config
    }

    @ViewBuilder
    private var wakeScheduleFooter: some View {
        // When locked, the row above already names the helper requirement.
        // Only show the AC caveat and live system state once the editor is open.
        if model.wakeHelperGate == .ready {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Reliable on AC power. On battery the firmware may skip the wake."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.systemWakeState.scheduledWakes.isEmpty {
                    let next = model.systemWakeState.scheduledWakes
                        .map { $0.formatted(date: .abbreviated, time: .shortened) }
                        .joined(separator: ", ")
                    Text(L("System one-shot wakes: %@", next))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let repeating = model.systemWakeState.repeatingSummary {
                    Text(L("System repeating: %@", repeating))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Event hooks

    private var eventHooksSection: some View {
        Section {
            if model.eventHooks.isEmpty {
                Text(L("No event hooks yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.eventHooks) { hook in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { hook.enabled },
                            set: { enabled in
                                var hooks = model.eventHooks
                                if let i = hooks.firstIndex(where: { $0.id == hook.id }) {
                                    hooks[i].enabled = enabled
                                    model.eventHooks = hooks
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hook.event.label)
                                Text(hook.action.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.switch)
                        Spacer(minLength: 8)
                        Button {
                            beginEdit(hook)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit hook")
                    }
                }
                .onDelete(perform: deleteHooks)
            }
            Button("Add Hook…") {
                beginAdd()
            }
        } header: {
            sectionHeader("Event hooks", info: L("When something happens in Keepresso, run a Shortcut, POST a webhook, or run a shell command. Useful for a push to your phone when an overnight agent finishes (ntfy, or a Shortcut that sends a notification). Hooks are suspended while you edit them, so a half-written command never runs. No administrator helper needed. User-authored shell commands are intentional in this unsandboxed app: only add commands you trust."))
        } footer: {
            sectionFooter("Run a Shortcut, post a webhook, or a shell command on session and trigger events. No helper required.")
        }
    }

    private func beginAdd() {
        model.hooksEditing = true
        editingID = nil
        draft = HookDraft(
            event: .sessionEnded,
            kind: .shortcut,
            shortcutName: "",
            webhookURL: "",
            shellCommand: ""
        )
    }

    private func beginEdit(_ hook: EventHook) {
        model.hooksEditing = true
        editingID = hook.id
        draft = HookDraft(from: hook)
    }

    private func commit(_ draft: HookDraft) {
        guard let action = draft.action else { return }
        var hooks = model.eventHooks
        if let id = editingID, let i = hooks.firstIndex(where: { $0.id == id }) {
            hooks[i].event = draft.event
            hooks[i].action = action
        } else {
            hooks.append(EventHook(event: draft.event, action: action))
        }
        model.eventHooks = hooks
    }

    private func deleteHooks(at offsets: IndexSet) {
        var hooks = model.eventHooks
        hooks.remove(atOffsets: offsets)
        model.eventHooks = hooks
    }
}

/// Locked stand-in for Automation features that need the administrator
/// helper (scheduled wake). Same idea as ``ThermalHelperLockedRow``, but
/// stacked: a side-by-side lock + long sentence + button squeezes the text
/// into narrow columns and ugly mid-phrase wraps.
private struct AutomationHelperLockedRow: View {
    @Bindable var model: AppModel
    enum Context { case wakeSchedule }
    let context: Context

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusSymbolColor)
            }
            if showsInstallButton {
                Button("Install Helper…") { model.installHelper() }
            } else if model.helper.awaitingApproval {
                Button("Open Login Items") { model.helper.openApprovalSettings() }
            }
            if let error = model.helper.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsInstallButton: Bool {
        !model.helper.awaitingApproval && !model.helper.daemonOutdated
    }

    private var statusSymbol: String {
        if model.helper.awaitingApproval { return "hourglass" }
        if model.helper.daemonOutdated { return "arrow.triangle.2.circlepath" }
        return "lock"
    }

    private var statusSymbolColor: Color {
        model.helper.awaitingApproval ? .orange : .secondary
    }

    private var statusText: String {
        if model.helper.awaitingApproval {
            return L("One step left: allow Keepresso under Login Items in System Settings. Scheduled wake unlocks by itself.")
        }
        if model.helper.daemonOutdated {
            return L("The helper is updating itself (no password). Scheduled wake unlocks when that finishes, usually under a minute.")
        }
        switch context {
        case .wakeSchedule:
            return L("Scheduled wake needs the administrator helper, the same one closed-display mode and fan boost use. Install once, and macOS asks for approval in System Settings.")
        }
    }
}

/// Editable fields for one hook, independent of the live settings list.
private struct HookDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case shortcut, webhook, shell
        var id: String { rawValue }
        /// Short enough for a three-way segmented control without clipping.
        var label: String {
            switch self {
            case .shortcut: return L("Shortcut")
            case .webhook:  return L("Webhook")
            case .shell:    return L("Shell")
            }
        }
    }

    let id = UUID()
    var event: HookEvent
    var kind: Kind
    var shortcutName: String
    var webhookURL: String
    var shellCommand: String

    init(
        event: HookEvent,
        kind: Kind,
        shortcutName: String,
        webhookURL: String,
        shellCommand: String
    ) {
        self.event = event
        self.kind = kind
        self.shortcutName = shortcutName
        self.webhookURL = webhookURL
        self.shellCommand = shellCommand
    }

    init(from hook: EventHook) {
        self.event = hook.event
        switch hook.action {
        case .runShortcut(let name):
            self.kind = .shortcut
            self.shortcutName = name
            self.webhookURL = ""
            self.shellCommand = ""
        case .webhook(let url):
            self.kind = .webhook
            self.shortcutName = ""
            self.webhookURL = url
            self.shellCommand = ""
        case .shell(let command):
            self.kind = .shell
            self.shortcutName = ""
            self.webhookURL = ""
            self.shellCommand = command
        }
    }

    var action: HookAction? {
        switch kind {
        case .shortcut:
            let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .runShortcut(name: name)
        case .webhook:
            let url = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : .webhook(url: url)
        case .shell:
            let command = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : .shell(command: command)
        }
    }
}

private struct HookEditorSheet: View {
    @State var draft: HookDraft
    let title: String
    let onCancel: () -> Void
    let onSave: (HookDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            Form {
                Picker("When", selection: $draft.event) {
                    ForEach(HookEvent.allCases, id: \.self) { event in
                        Text(event.label).tag(event)
                    }
                }
                // Short labels only: "Run a Shortcut" / "POST a webhook" /
                // "Run a shell command" overflow a three-way segment and clip
                // to "hortcut" at this sheet width.
                Picker("Do", selection: $draft.kind) {
                    ForEach(HookDraft.Kind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                switch draft.kind {
                case .shortcut:
                    TextField("Shortcut name", text: $draft.shortcutName)
                        .textFieldStyle(.roundedBorder)
                case .webhook:
                    TextField("https://…", text: $draft.webhookURL)
                        .textFieldStyle(.roundedBorder)
                case .shell:
                    TextField("/bin/sh -c …", text: $draft.shellCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.action == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Display (experimental virtual display)

private struct DisplayTab: View {
    @Bindable var model: AppModel

    private static let resolutions: [(label: String, width: Int, height: Int)] = [
        ("1920 \u{00D7} 1080", 1920, 1080),
        ("2560 \u{00D7} 1440", 2560, 1440),
        ("2880 \u{00D7} 1620", 2880, 1620),
        ("3840 \u{00D7} 2160 (4K)", 3840, 2160),
    ]
    private static let defaultConfig = VirtualDisplayConfig(width: 2560, height: 1440, hiDPI: true)

    private static func key(_ width: Int, _ height: Int) -> String { "\(width)x\(height)" }

    var body: some View {
        Form {
            Section {
                Toggle("Create a virtual display", isOn: Binding(
                    get: { model.virtualDisplayEnabled },
                    set: { on in model.setVirtualDisplay(on ? Self.defaultConfig : nil) }
                ))
                .disabled(!model.virtualDisplaySupported)

                if !model.virtualDisplaySupported {
                    Text("Not available on this macOS version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let config = model.virtualDisplayConfig {
                    Picker("Resolution", selection: Binding(
                        get: { Self.key(config.width, config.height) },
                        set: { newKey in
                            guard let r = Self.resolutions.first(where: { Self.key($0.width, $0.height) == newKey }) else { return }
                            model.setVirtualDisplay(VirtualDisplayConfig(width: r.width, height: r.height, hiDPI: config.hiDPI))
                        }
                    )) {
                        ForEach(Self.resolutions, id: \.label) { r in
                            Text(L(r.label)).tag(Self.key(r.width, r.height))
                        }
                    }
                    Toggle("HiDPI (Retina)", isOn: Binding(
                        get: { config.hiDPI },
                        set: { model.setVirtualDisplay(VirtualDisplayConfig(width: config.width, height: config.height, hiDPI: $0)) }
                    ))
                    if let error = model.virtualDisplayError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                sectionHeader("Headless virtual display (experimental)", info: L("A Mac with no monitor attached falls back to a fuzzy 1920 \u{00D7} 1080, which is what makes Screen Sharing and VNC look soft. This creates a higher-resolution HiDPI display in software, so the remote picture is crisp without plugging anything in. It uses a private macOS API, so treat it as experimental and expect it may break on a macOS update. A hardware HDMI or DisplayPort dummy plug does the same job with no software at all."))
            } footer: {
                sectionFooter("For a Mac with no monitor: a sharper picture over Screen Sharing and VNC.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.25), value: model.virtualDisplayEnabled)
    }
}

// MARK: - Disk

private struct DiskTab: View {
    @Bindable var model: AppModel

    private static let intervals: [(label: String, interval: TimeInterval)] = [
        ("Every 1 minute", 60),
        ("Every 5 minutes", 5 * 60),
        ("Every 10 minutes", 10 * 60),
        ("Every 30 minutes", 30 * 60),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Keep a disk spinning", isOn: Binding(
                    get: { model.diskKeepAliveEnabled },
                    set: { on in on ? model.chooseDiskFolder() : model.disableDiskKeepAlive() }
                ))
                if model.diskKeepAliveEnabled {
                    LabeledContent("Folder") {
                        HStack(spacing: 6) {
                            Text(model.diskKeepAliveDirectory?.lastPathComponent ?? L("None"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Change…") { model.chooseDiskFolder() }
                                .buttonStyle(.link)
                        }
                    }
                    Picker("Touch", selection: Binding(
                        get: { model.diskKeepAliveInterval },
                        set: { model.diskKeepAliveInterval = $0 }
                    )) {
                        ForEach(Self.intervals, id: \.interval) { option in
                            Text(L(option.label)).tag(option.interval)
                        }
                    }
                }
            } header: {
                sectionHeader("Disk", info: L("Many external drives and NAS volumes park or disconnect after a few minutes idle, and the next thing that touches them stalls while they spin back up. Keepresso rewrites a tiny hidden marker file in the folder you choose, just enough activity to keep the volume awake. Pick an interval shorter than the drive's own idle timeout. This runs whenever Keepresso is running, with or without a keep-awake session, so a drive stays ready even when the Mac is free to sleep."))
            } footer: {
                sectionFooter("Stops an external drive or NAS from spinning down.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.25), value: model.diskKeepAliveEnabled)
    }
}
