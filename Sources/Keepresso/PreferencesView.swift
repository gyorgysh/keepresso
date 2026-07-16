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
        case disk = "Disk"
        case display = "Display"
        case activity = "Activity"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .triggers: "bolt"
            case .reminder: "bell"
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
        // 520 fits six labeled segments; 480 truncated them once Activity joined.
        .frame(width: 520, height: 560)
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
                Text("Why each session started or stopped, newest first. Kept in memory; clears on relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { assertions = model.currentAssertions() }
        .onReceive(tick) { _ in assertions = model.currentAssertions() }
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
            // High up on purpose: this is the one-time set-and-forget step that
            // makes every privileged switch below (and AWDL pausing) silent.
            Section {
                HelperStatusRows(model: model)
            } header: {
                sectionHeader("Administrator helper", info: L("A small system service for the two switches that need administrator rights: closed-display mode below, and AWDL pausing in Gaming & Streaming. Without it, macOS asks for your password once per app run. With it, both are instant and silent: macOS asks once, when you approve the helper under Login Items, and the approval survives restarts and updates. It can only flip those specific switches, everything it changes is restored if Keepresso quits or crashes, and you can remove it here at any time. It also puts the keepresso command-line tool on your PATH (Homebrew installs already have it). After removal, System Settings can keep showing a stale Login Items row until macOS refreshes its list; the status shown here is the real one."))
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
            if model.machineHasBattery {
                closedDisplaySection
            }
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
        .animation(.snappy(duration: 0.25), value: model.closedDisplayError)
        .animation(.snappy(duration: 0.25), value: model.closedDisplayAutoError)
        .onAppear { model.refreshClosedDisplay() }
    }

    /// Closed-display mode only makes sense on a machine with a lid; battery
    /// presence is the proxy, so desktops never see this section.
    private var closedDisplaySection: some View {
        Section {
            Toggle("Keep awake with the lid closed", isOn: Binding(
                get: { model.closedDisplayEnabled },
                set: { model.setClosedDisplay($0) }
            ))
            .disabled(model.closedDisplayBusy)
            if model.closedDisplayBusy && !model.helperInstalled {
                AdminAuthNote(purpose: L("keep the Mac awake with the lid closed"))
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
            .disabled(model.closedDisplayAutoBusy)
            if model.closedDisplayAutoBusy && !model.helperInstalled {
                AdminAuthNote(purpose: L("switch closed-display mode with the session"))
            }
            if let error = model.closedDisplayAutoError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            sectionHeader("Closed-display mode", info: L("Normally a MacBook sleeps the moment you shut the lid unless a display is attached. This keeps it running with the lid shut and nothing plugged in, on power or battery. The screen itself still turns off when the lid closes (unless an external display is attached), so it isn't lighting up uselessly inside the closed lid. It works by flipping a system setting (pmset disablesleep), so it stays in effect until you turn it off: closed and on battery, the Mac can still drain over time, so don't leave it on in a bag. \u{201C}Only while brewing\u{201D} ties it to the session instead, on when a keep-awake session starts, off when it ends or Keepresso quits (even after a crash). Both need administrator rights: silent with the administrator helper installed (see the top of this tab), otherwise macOS asks for your password, once per app run for \u{201C}Only while brewing\u{201D}."))
        } footer: {
            sectionFooter("Keeps running with the lid shut and no external display.")
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
                Picker("On session end", selection: Binding(
                    get: { model.endAction },
                    set: { model.endAction = $0 }
                )) {
                    ForEach(SessionEndAction.allCases, id: \.self) { action in
                        Text(action.label).tag(action)
                    }
                }
            } header: {
                sectionHeader("Session end", info: L("These cover the times a session ends without you: a timer expiring, trigger conditions dropping, or a low-battery pause. Stopping it yourself stays silent, since you already know. The warning is a heads-up a few minutes before a timed session runs out, so you can extend it before the Mac drops off. The action runs when the session ends: sleep the display or start the screen saver, handy for a Mac you walk away from. It's off by default so a timed session never surprises you."))
            } footer: {
                sectionFooter("Fires when a session ends on its own, not when you stop it yourself.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.25), value: model.reminderEnabled)
        .animation(.snappy(duration: 0.25), value: model.reminderRepeats)
        .animation(.snappy(duration: 0.25), value: model.endingSoonEnabled)
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
