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
    @State private var calendar = CalendarAuthorizer()
    /// Free-text entry for a custom "process running" rule.
    @State private var processQuery = ""
    /// Index of the time-window rule whose editor popover is open, if any.
    @State private var timeEditorIndex: Int?

    /// Common processes offered as one-click presets for the process rule.
    private static let processPresets = ["claude", "codex", "node", "python", "ffmpeg"]

    /// Threshold options for the CPU-load rule.
    private static let cpuThresholds = [25, 50, 75, 90]

    /// Threshold options for the network-activity rule, in KB/s.
    private static let throughputThresholds = [100, 500, 1024, 5120]

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

            addConditionMenus
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
            if case .throughput(let kb) = rule {
                throughputOptionsMenu(index: index, kilobytesPerSecond: kb)
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
                    bundleID: appRule.bundleID, name: appRule.name, match: $0, grace: appRule.grace))) }
            )) {
                Text("While running").tag(AppMatch.running)
                Text("While frontmost").tag(AppMatch.frontmost)
            }
            Divider()
            Picker("Grace period", selection: Binding(
                get: { appRule.grace },
                set: { model.updateRule(at: index, to: .app(AppRule(
                    bundleID: appRule.bundleID, name: appRule.name, match: appRule.match, grace: $0))) }
            )) {
                ForEach(Self.gracePresets, id: \.seconds) { preset in
                    Text(L(preset.label)).tag(preset.seconds)
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
                    Text(L("Above %d%%", percent)).tag(percent)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("CPU threshold")
    }

    /// In-place editor for a network-activity rule's threshold.
    private func throughputOptionsMenu(index: Int, kilobytesPerSecond: Int) -> some View {
        Menu {
            Picker("Threshold", selection: Binding(
                get: { kilobytesPerSecond },
                set: { model.updateRule(at: index, to: .throughput(kilobytesPerSecond: $0)) }
            )) {
                ForEach(Self.throughputThresholds, id: \.self) { kb in
                    Text(L("Above %@", NetworkThroughput.rateLabel(kilobytesPerSecond: kb))).tag(kb)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Network threshold")
    }

    /// Conditions are added from three menus grouped by what the user is
    /// thinking about, not by API. One flat menu held eleven scrolling
    /// sections by v1.6, which had become a chore to navigate.
    private var addConditionMenus: some View {
        // The three menu titles run long in some languages (Hungarian roughly
        // doubles them), and .fixedSize() means an overflowing row widens the
        // whole tab past the fixed window. Fall back to stacked menus when
        // one line doesn't fit.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                addConditionLabel
                HStack(spacing: 14) { addConditionTrio }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                addConditionLabel
                VStack(alignment: .leading, spacing: 6) { addConditionTrio }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.leading, 22)
            }
        }
        .font(.callout)
    }

    private var addConditionLabel: some View {
        Label("Add:", systemImage: "plus.circle")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var addConditionTrio: some View {
        Menu { powerDisplayItems } label: { Text("Power & Display") }
        Menu { networkDevicesItems } label: { Text("Network & Devices") }
        Menu { appsActivityItems } label: { Text("Apps & Activity") }
    }

    @ViewBuilder
    private var powerDisplayItems: some View {
        Section("Power") {
            Button("On AC power") { model.addRule(.powerSource(.onACPower)) }
            // Desktops are always on AC: a battery rule could never fire.
            if model.machineHasBattery {
                Button("On battery") { model.addRule(.powerSource(.onBattery)) }
                Button("Charging") { model.addRule(.powerSource(.charging)) }
            }
        }
        Section("Display") {
            Button("External display connected") { model.addRule(.externalDisplay) }
        }
    }

    @ViewBuilder
    private var networkDevicesItems: some View {
        Section("Network") {
            Button("VPN connected") { model.addRule(.vpnConnected) }
            if location.isAuthorized {
                if let ssid = model.currentSSID() {
                    Button(L("On current Wi-Fi (%@)", ssid)) { model.addRule(.wifiSSID(ssid)) }
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
        Section("Network activity") {
            ForEach(Self.throughputThresholds, id: \.self) { kb in
                Button(L("Above %@", NetworkThroughput.rateLabel(kilobytesPerSecond: kb))) {
                    model.addRule(.throughput(kilobytesPerSecond: kb))
                }
            }
        }
    }

    @ViewBuilder
    private var appsActivityItems: some View {
        Section("App is running") {
            appButtons { .app(AppRule(bundleID: $0.bundleID, name: $0.name, match: .running)) }
        }
        Section("App is frontmost") {
            appButtons { .app(AppRule(bundleID: $0.bundleID, name: $0.name, match: .frontmost)) }
        }
        Section("Media") {
            Button("Camera in use") { model.addRule(.mediaInUse(.camera)) }
            Button("Microphone in use") { model.addRule(.mediaInUse(.microphone)) }
            Button("Audio playing") { model.addRule(.audioPlaying) }
        }
        Section("Gaming") {
            Button("Playing a game") { model.addRule(.gaming) }
                .help("Counts only while a game (or a cloud-gaming app) is the active window, not just running in the background. Keeps holding for 5 minutes after you switch away.")
        }
        Section("Process is running") {
            ForEach(Self.processPresets, id: \.self) { name in
                Button(name) { model.addRule(.process(name)) }
            }
        }
        Section("Downloads") {
            Button("Watch a folder for downloads\u{2026}") { model.chooseDownloadFolder() }
                .help("Keeps the Mac awake while a partial-download file (.crdownload, .download, .part, and the like) exists in the chosen folder, then lets it sleep once the download finishes. Holds for 30 seconds between files in a batch.")
        }
        Section("CPU load") {
            ForEach(Self.cpuThresholds, id: \.self) { percent in
                Button(L("Above %d%%", percent)) { model.addRule(.cpuLoad(thresholdPercent: percent)) }
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
            if calendar.isAuthorized {
                Button("During calendar events") { model.addRule(.calendarEvent) }
            } else if calendar.canRequest {
                Button("Allow calendar access\u{2026}") { calendar.request() }
            } else {
                Text("The calendar rule needs Calendar access (System Settings ▸ Privacy)")
                    .foregroundStyle(.secondary)
            }
        }
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
    private func appButtons(_ make: @escaping ((name: String, bundleID: String)) -> TriggerRule) -> some View {
        let apps = model.runningApps()
        if apps.isEmpty {
            Text("No apps running").foregroundStyle(.secondary)
        } else {
            ForEach(apps, id: \.bundleID) { app in
                Button(app.name) { model.addRule(make(app)) }
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
        case .calendarEvent:           return "calendar"
        case .gaming:                  return "gamecontroller"
        case .throughput:              return "arrow.up.arrow.down"
        case .downloadInFolder:        return "arrow.down.circle"
        }
    }
}

/// Popover editor for a schedule rule: start/end time pickers plus one toggle
/// per weekday. Every change writes through immediately; there's no Save.
private struct TimeWindowEditor: View {
    let rule: TimeWindowRule
    let update: (TimeWindowRule) -> Void

    /// Day numbers in `Calendar` order (1 = Sunday) with the locale's own
    /// one-letter initials, rotated so the row starts on the locale's first
    /// weekday (Monday in most of Europe, Sunday in the US).
    private static let days: [(number: Int, initial: String)] = {
        let calendar = Calendar.current
        let initials = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { offset in
            let index = (calendar.firstWeekday - 1 + offset) % 7
            return (index + 1, initials[index])
        }
    }()

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
