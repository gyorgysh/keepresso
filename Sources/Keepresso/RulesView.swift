import SwiftUI
import KeepressoCore

/// The trigger rules editor, shown in Preferences ▸ Triggers when "Activate by
/// triggers" is on.
///
/// Conditions are added from a menu rather than typed: power/display rules are
/// fixed, and Wi-Fi / app rules are seeded from current system state (the joined
/// SSID, the list of running apps) so there are no free-text fields to get
/// wrong. App rules can be tuned in place (running/frontmost + grace period).
struct RulesView: View {
    @Bindable var model: AppModel
    @State private var location = LocationAuthorizer()
    @State private var bluetooth = BluetoothAuthorizer()
    /// Free-text entry for a custom "process running" rule.
    @State private var processQuery = ""
    /// Index of the time-window rule whose editor popover is open, if any.
    @State private var timeEditorIndex: Int?

    /// Common processes offered as one-click presets for the process rule.
    private static let processPresets = ["claude", "codex", "node", "python", "ffmpeg"]

    /// Threshold options for the CPU-load rule.
    private static let cpuThresholds = [25, 50, 75, 90]

    /// Grace presets offered for app rules.
    private static let gracePresets: [(label: String, seconds: TimeInterval)] = [
        ("No grace", 0),
        ("30 seconds", 30),
        ("2 minutes", 120),
        ("5 minutes", 300),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("When")
                    .font(.subheadline.weight(.semibold))
                Picker("", selection: Binding(
                    get: { model.combine },
                    set: { model.combine = $0 }
                )) {
                    Text("any").tag(CombineMode.any)
                    Text("all").tag(CombineMode.all)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Text("of these are true:")
                    .font(.subheadline)
            }

            if model.rules.isEmpty {
                Text("No conditions yet, so the Mac can sleep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(model.rules.enumerated()), id: \.offset) { index, rule in
                    ruleRow(index: index, rule: rule)
                }
            }

            addConditionMenu
            processField
        }
    }

    @ViewBuilder
    private func ruleRow(index: Int, rule: TriggerRule) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: rule))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(rule.label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            if case .app(let appRule) = rule {
                appOptionsMenu(index: index, appRule: appRule)
            }
            if case .timeWindow(let windowRule) = rule {
                timeOptionsButton(index: index, windowRule: windowRule)
            }
            if case .cpuLoad(let threshold) = rule {
                cpuOptionsMenu(index: index, threshold: threshold)
            }

            Button {
                model.removeRule(at: index)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove condition")
        }
    }

    /// In-place editor for a schedule rule's times and days, in a popover
    /// (menus can't host time pickers).
    private func timeOptionsButton(index: Int, windowRule: TimeWindowRule) -> some View {
        Button {
            timeEditorIndex = index
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Times & days")
        .popover(isPresented: Binding(
            get: { timeEditorIndex == index },
            set: { if !$0 { timeEditorIndex = nil } }
        )) {
            TimeWindowEditor(rule: windowRule) { model.updateRule(at: index, to: .timeWindow($0)) }
        }
    }

    /// In-place editor for an app rule's match mode and grace period.
    private func appOptionsMenu(index: Int, appRule: AppRule) -> some View {
        Menu {
            Picker("Match", selection: Binding(
                get: { appRule.match },
                set: { model.updateRule(at: index, to: .app(AppRule(
                    bundleID: appRule.bundleID, match: $0, grace: appRule.grace))) }
            )) {
                Text("While running").tag(AppMatch.running)
                Text("While frontmost").tag(AppMatch.frontmost)
            }
            Divider()
            Picker("Grace period", selection: Binding(
                get: { appRule.grace },
                set: { model.updateRule(at: index, to: .app(AppRule(
                    bundleID: appRule.bundleID, match: appRule.match, grace: $0))) }
            )) {
                ForEach(Self.gracePresets, id: \.seconds) { preset in
                    Text(preset.label).tag(preset.seconds)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("App match & grace period")
    }

    /// In-place editor for a CPU rule's threshold.
    private func cpuOptionsMenu(index: Int, threshold: Int) -> some View {
        Menu {
            Picker("Threshold", selection: Binding(
                get: { threshold },
                set: { model.updateRule(at: index, to: .cpuLoad(thresholdPercent: $0)) }
            )) {
                ForEach(Self.cpuThresholds, id: \.self) { percent in
                    Text("Above \(percent)%").tag(percent)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("CPU threshold")
    }

    private var addConditionMenu: some View {
        Menu {
            Section("Power") {
                Button("On AC power") { model.addRule(.powerSource(.onACPower)) }
                Button("On battery") { model.addRule(.powerSource(.onBattery)) }
                Button("Charging") { model.addRule(.powerSource(.charging)) }
            }
            Section("Display") {
                Button("External display connected") { model.addRule(.externalDisplay) }
            }
            Section("Network") {
                Button("VPN connected") { model.addRule(.vpnConnected) }
                if location.isAuthorized {
                    if let ssid = model.currentSSID() {
                        Button("On current Wi-Fi (\(ssid))") { model.addRule(.wifiSSID(ssid)) }
                    } else {
                        Text("No Wi-Fi network joined").foregroundStyle(.secondary)
                    }
                } else if location.canRequest {
                    Button("Allow Wi-Fi access\u{2026}") { location.request() }
                } else {
                    Text("Wi-Fi rules need Location access (System Settings ▸ Privacy)")
                        .foregroundStyle(.secondary)
                }
            }
            Section("App is running") {
                appButtons { .app(AppRule(bundleID: $0, match: .running)) }
            }
            Section("App is frontmost") {
                appButtons { .app(AppRule(bundleID: $0, match: .frontmost)) }
            }
            Section("Media") {
                Button("Camera in use") { model.addRule(.mediaInUse(.camera)) }
                Button("Microphone in use") { model.addRule(.mediaInUse(.microphone)) }
                Button("Audio playing") { model.addRule(.audioPlaying) }
            }
            Section("Bluetooth device connected") {
                if bluetooth.isAuthorized {
                    let devices = model.pairedBluetoothDevices()
                    if devices.isEmpty {
                        Text("No paired devices").foregroundStyle(.secondary)
                    } else {
                        ForEach(devices, id: \.self) { name in
                            Button(name) { model.addRule(.bluetoothDevice(name)) }
                        }
                    }
                } else if bluetooth.canRequest {
                    Button("Allow Bluetooth access\u{2026}") { bluetooth.request() }
                } else {
                    Text("Bluetooth rules need Bluetooth access (System Settings ▸ Privacy)")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Process is running") {
                ForEach(Self.processPresets, id: \.self) { name in
                    Button(name) { model.addRule(.process(name)) }
                }
            }
            Section("Volume is mounted") {
                let volumes = model.mountedVolumes()
                if volumes.isEmpty {
                    Text("No volumes mounted").foregroundStyle(.secondary)
                } else {
                    ForEach(volumes, id: \.self) { name in
                        Button(name) { model.addRule(.volumeMounted(name)) }
                    }
                }
            }
            Section("CPU load") {
                ForEach(Self.cpuThresholds, id: \.self) { percent in
                    Button("Above \(percent)%") { model.addRule(.cpuLoad(thresholdPercent: percent)) }
                }
            }
            Section("Schedule") {
                // Starting points; the row's slider button tunes times and days.
                Button("Work hours (weekdays 9:00-18:00)") {
                    model.addRule(.timeWindow(TimeWindowRule(
                        startMinutes: 9 * 60, endMinutes: 18 * 60, weekdays: [2, 3, 4, 5, 6])))
                }
                Button("Overnight (22:00-6:00)") {
                    model.addRule(.timeWindow(TimeWindowRule(startMinutes: 22 * 60, endMinutes: 6 * 60)))
                }
            }
        } label: {
            Label("Add condition", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Free-text entry for any other process name (matched against the full
    /// command line, so `node`, `ffmpeg server.js`, etc. all work).
    private var processField: some View {
        HStack(spacing: 6) {
            TextField("Other process, e.g. rsync", text: $processQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addProcess)
            Button("Add") { addProcess() }
                .disabled(processQuery.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addProcess() {
        let name = processQuery.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.addRule(.process(name))
        processQuery = ""
    }

    @ViewBuilder
    private func appButtons(_ make: @escaping (String) -> TriggerRule) -> some View {
        let apps = model.runningApps()
        if apps.isEmpty {
            Text("No apps running").foregroundStyle(.secondary)
        } else {
            ForEach(apps, id: \.bundleID) { app in
                Button(app.name) { model.addRule(make(app.bundleID)) }
            }
        }
    }

    private func icon(for rule: TriggerRule) -> String {
        switch rule {
        case .powerSource(.onACPower): return "powerplug"
        case .powerSource(.onBattery): return "battery.50"
        case .powerSource(.charging):  return "battery.100.bolt"
        case .externalDisplay:         return "display.2"
        case .wifiSSID:                return "wifi"
        case .app(let r):              return r.match == .frontmost ? "macwindow.on.rectangle" : "app.badge"
        case .process:                 return "terminal"
        case .timeWindow:              return "clock"
        case .volumeMounted:           return "externaldrive"
        case .cpuLoad:                 return "cpu"
        case .mediaInUse(.camera):     return "video"
        case .mediaInUse(.microphone): return "mic"
        case .audioPlaying:            return "speaker.wave.2"
        case .vpnConnected:            return "lock.shield"
        case .bluetoothDevice:         return "antenna.radiowaves.left.and.right"
        }
    }
}

/// Popover editor for a schedule rule: start/end time pickers plus one toggle
/// per weekday. Every change writes through immediately; there's no Save.
private struct TimeWindowEditor: View {
    let rule: TimeWindowRule
    let update: (TimeWindowRule) -> Void

    /// Day numbers in `Calendar` order (1 = Sunday) with display initials.
    private static let days: [(number: Int, initial: String)] =
        [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("From") {
                DatePicker("", selection: timeBinding(\.startMinutes), displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            LabeledContent("To") {
                DatePicker("", selection: timeBinding(\.endMinutes), displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            if rule.startMinutes >= rule.endMinutes {
                Text("Runs past midnight into the next day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                ForEach(Self.days, id: \.number) { day in
                    Toggle(day.initial, isOn: dayBinding(day.number))
                        .toggleStyle(.button)
                        .font(.caption)
                }
            }
            Text("No days selected means every day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 240)
    }

    /// Bridges minutes-from-midnight to the `DatePicker`'s `Date` (on an
    /// arbitrary reference day; only the time of day is kept).
    private func timeBinding(_ keyPath: WritableKeyPath<TimeWindowRule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = rule[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { newDate in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                var updated = rule
                updated[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                update(updated)
            }
        )
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { rule.weekdays.contains(day) },
            set: { on in
                var updated = rule
                if on { updated.weekdays.insert(day) } else { updated.weekdays.remove(day) }
                update(updated)
            }
        )
    }
}
