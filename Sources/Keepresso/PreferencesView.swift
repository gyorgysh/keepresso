import SwiftUI
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

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .triggers: "bolt"
            case .reminder: "bell"
            case .disk: "externaldrive"
            case .display: "display"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 480, height: 560)
        .glassWindowBackground()
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralTab(model: model)
        case .triggers: TriggersTab(model: model).padding(20)
        case .reminder: ReminderTab(model: model)
        case .disk: DiskTab(model: model)
        case .display: DisplayTab(model: model)
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled

    private var session: SessionController { model.session }

    var body: some View {
        Form {
            Section("Keep awake") {
                Toggle("Prevent display sleep", isOn: optionBinding(\.preventDisplaySleep))
                Toggle("Prevent system sleep", isOn: optionBinding(\.preventSystemSleep))
            }
            Section {
                Toggle("Show countdown in menu bar", isOn: Binding(
                    get: { model.showCountdownInMenuBar },
                    set: { model.showCountdownInMenuBar = $0 }
                ))
            } footer: {
                Text("Shows the remaining time next to the menu-bar icon during a timed session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Pause on low battery", isOn: Binding(
                    get: { model.batteryAutoPauseEnabled },
                    set: { model.batteryAutoPauseEnabled = $0 }
                ))
                if model.batteryAutoPauseEnabled {
                    Picker("Below", selection: Binding(
                        get: { model.pauseBelowBatteryPercent },
                        set: { model.pauseBelowBatteryPercent = $0 }
                    )) {
                        ForEach([10, 15, 20, 30, 50], id: \.self) { percent in
                            Text("\(percent)%").tag(percent)
                        }
                    }
                }
            } footer: {
                Text("Lets the Mac sleep once battery charge drops below this level, even mid-session, so it doesn't run flat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep awake with the lid closed", isOn: Binding(
                    get: { model.closedDisplayEnabled },
                    set: { model.setClosedDisplay($0) }
                ))
                .disabled(model.closedDisplayBusy)
                if let error = model.closedDisplayError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Closed-display mode")
            } footer: {
                Text("Keeps running with the lid shut and no external display, on power or battery. The display itself still turns off when the lid closes (unless an external display is attached), so it's not lighting up uselessly inside the closed lid. Changing this needs your administrator password and flips a system setting (pmset disablesleep), so it stays in effect until you turn it off. On battery and closed it can still drain the battery over time, so don't leave it on in a bag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        LoginItem.setEnabled(newValue)
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { model.refreshClosedDisplay() }
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
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Activate by triggers", isOn: Binding(
                get: { model.triggersEnabled },
                set: { model.triggersEnabled = $0 }
            ))
            .toggleStyle(.switch)

            Text("When on, the listed conditions control the session instead of the manual switch.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.triggersEnabled && model.triggersPaused {
                HStack(spacing: 6) {
                    Text("Currently paused from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Resume") { model.resumeTriggers() }
                        .font(.caption)
                }
            }

            if model.triggersEnabled {
                Divider()
                presets
                Divider()
                RulesView(model: model)
            }
            Spacer(minLength: 0)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Presets")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.applyPreset(preset) }
                    }
                    if !model.presets.isEmpty { Divider() }
                    ForEach(model.presets) { preset in
                        Button("Remove \u{201C}\(preset.name)\u{201D}", role: .destructive) {
                            model.removePreset(preset)
                        }
                    }
                } label: {
                    Label("Apply or remove", systemImage: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 6) {
                TextField("Save current rules as\u{2026}", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(savePreset)
                Button("Save") { savePreset() }
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty || model.rules.isEmpty)
            }
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

    var body: some View {
        Form {
            Section {
                Toggle("Remind me it's still on", isOn: Binding(
                    get: { model.reminderEnabled },
                    set: { model.reminderEnabled = $0 }
                ))
                if model.reminderEnabled {
                    Picker(model.reminderRepeats ? "Every" : "After", selection: Binding(
                        get: { model.reminderAfter },
                        set: { model.reminderAfter = $0 }
                    )) {
                        ForEach(Self.options, id: \.interval) { option in
                            Text(option.label).tag(option.interval)
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
            } footer: {
                Text(model.reminderRepeats
                     ? "A recurring notification every interval while a session runs, so a Mac left awake keeps reminding you."
                     : "A one-time notification once a session has run this long, in case you forget the Mac is awake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                            Text(r.label).tag(Self.key(r.width, r.height))
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
                Text("Headless virtual display (experimental)")
            } footer: {
                Text("For a Mac with no monitor: creates a higher-resolution display so Screen Sharing and VNC look crisp instead of a fuzzy 1920 \u{00D7} 1080. It uses a private macOS API, so treat it as experimental and expect it may break on a macOS update. A hardware HDMI or DisplayPort dummy plug is a no-software alternative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                            Text(model.diskKeepAliveDirectory?.lastPathComponent ?? "—")
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
                            Text(option.label).tag(option.interval)
                        }
                    }
                }
            } footer: {
                Text("Writes a tiny marker file on the chosen volume periodically to stop an external drive or NAS from spinning down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
