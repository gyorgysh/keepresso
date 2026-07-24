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

    /// Idle-grace presets offered for the agent-activity rule: how long to keep
    /// holding after every agent session goes idle.
    private static let agentGracePresets: [(label: String, seconds: TimeInterval)] = [
        ("Instantly", 0),
        ("1 minute", 60),
        ("3 minutes", 180),
        ("5 minutes", 300),
        ("10 minutes", 600),
    ]

    /// The section header above the rules: "When [any/all] of these are
    /// true:" with the combine-mode picker inline. A header, not a row: the
    /// grouped Form's label/control row layout would tear the sentence apart.
    static func combineHeader(model: AppModel) -> some View {
        HStack(spacing: 6) {
            Text("When")
            Picker("", selection: Binding(
                get: { model.combine },
                set: { model.combine = $0 }
            )) {
                Text("any").tag(CombineMode.any)
                Text("all").tag(CombineMode.all)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Text("of these are true:")
            InfoButton(text: L("\u{201C}any\u{201D} keeps the Mac awake while at least one condition holds, so the rules pile up: add three and any of them is enough. \u{201C}all\u{201D} needs every one true at once, which narrows things down (on AC power and an external display connected means only while docked). Conditions are checked once a second, and Keepresso stops brewing as soon as they stop being met."))
        }
    }

    // A Group, not a VStack: RulesView sits inside a grouped Form section,
    // and a Group lets the Form explode each top-level view into its own
    // row (a VStack would cram the whole editor into one row and fight the
    // form's row layout).
    var body: some View {
        Group {
            if model.rules.isEmpty {
                Text("No conditions yet, so the Mac can sleep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(model.rules.enumerated()), id: \.offset) { index, rule in
                    ruleRow(index: index, rule: rule)
                }
                if model.rules.contains(where: isAgentRule) {
                    claudeCodeRows
                }
            }

            addConditionMenus
            processField

            // Heat deliberately isn't a condition here: a "too hot" rule that
            // merely stops satisfying could be overridden by any other rule in
            // "any" mode. Point the people who come looking to the real thing.
            // Laptops only, like the Thermal section itself: a desktop has no
            // lid, so there is no section to point at.
            if model.machineHasBattery {
                Text("Looking for heat? \u{201C}Pause when running hot\u{201D} lives in General \u{25B8} Thermal: a safety net that overrides these rules when the Mac runs hot with the lid closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: model.rules.count) { _, _ in
            // The rule rows use positional ids, so a removal elsewhere renumbers
            // them. Dismiss any open schedule editor rather than let its captured
            // index write its edit into whatever rule shifted into that slot.
            timeEditorIndex = nil
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
            if case .agentActivity(let agentRule) = rule {
                agentOptionsMenu(index: index, agentRule: agentRule)
            }
            if case .micInUse(let micRule) = rule {
                micOptionsMenu(index: index, micRule: micRule)
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

    /// In-place editor for a mic-scope rule: the apps it watches (click one to
    /// stop watching it) and an "Add app" submenu. Removing the last app drops
    /// the whole rule, since an empty scope would hold nothing awake.
    private func micOptionsMenu(index: Int, micRule: MicInUseRule) -> some View {
        Menu {
            Section("Keeping awake for calls in") {
                // Group by display name so a multi-id app (e.g. Telegram's two
                // builds) shows one row; removing it drops all of its ids.
                ForEach(displayNames(of: micRule.apps), id: \.self) { name in
                    Button {
                        let remaining = micRule.apps.filter { ($0.name ?? $0.bundleID) != name }
                        if remaining.isEmpty {
                            model.removeRule(at: index)
                        } else {
                            model.updateRule(at: index, to: .micInUse(MicInUseRule(apps: remaining)))
                        }
                    } label: {
                        // A checkmark reads "currently watched"; clicking removes it.
                        Label(name, systemImage: "checkmark")
                    }
                }
            }
            Divider()
            Menu("Add app") {
                micAppChoices { apps in
                    let fresh = apps.filter { a in !micRule.apps.contains { $0.bundleID == a.bundleID } }
                    guard !fresh.isEmpty else { return }
                    model.updateRule(at: index, to: .micInUse(MicInUseRule(apps: micRule.apps + fresh)))
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which apps count")
    }

    /// Ordered, de-duplicated display names for a mic rule's apps, so a multi-id
    /// app (variants sharing one name) collapses to a single editor row.
    private func displayNames(of apps: [ScopedApp]) -> [String] {
        var seen = Set<String>()
        return apps.compactMap { app in
            let name = app.name ?? app.bundleID
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// Shared app chooser for the mic-scope rule, used both when adding the rule
    /// and when adding apps to an existing one. Offers the apps using the mic
    /// right now (foolproof: real bundle id, no guessing), a short list of
    /// common call apps, and a "Choose app…" panel. Built lazily when the menu
    /// opens, so the live list is fresh.
    @ViewBuilder
    private func micAppChoices(_ add: @escaping ([ScopedApp]) -> Void) -> some View {
        let live = model.micAppsInUse()
        if !live.isEmpty {
            Section("Using the mic now") {
                ForEach(live, id: \.bundleID) { app in
                    Button(app.name) { add([ScopedApp(bundleID: app.bundleID, name: app.name)]) }
                }
            }
        }
        Section("Common call apps") {
            // A preset may carry several bundle ids (app variants) under one
            // name; they're added together as one grouped entry.
            ForEach(AppModel.callAppPresets, id: \.name) { preset in
                Button(preset.name) {
                    add(preset.bundleIDs.map { ScopedApp(bundleID: $0, name: preset.name) })
                }
            }
        }
        Divider()
        Button("Choose app\u{2026}") {
            if let picked = model.pickApplication() {
                add([ScopedApp(bundleID: picked.bundleID, name: picked.name)])
            }
        }
    }

    private func isAgentRule(_ rule: TriggerRule) -> Bool {
        if case .agentActivity = rule { return true }
        return false
    }

    /// Status row + action for the Claude Code hook connection, shown with
    /// the agent rule. Mirrors the three-state ``HelperStatusRows`` pattern.
    /// The status refresh on appear is a plain read of one small file; the
    /// settings merge itself runs only on the explicit click.
    @ViewBuilder
    private var claudeCodeRows: some View {
        Group {
            switch model.claudeHooks {
            case .installed:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Claude Code connected: sessions report working and waiting exactly.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Remove") { model.removeClaudeHooks() }
                }
            case .notInstalled:
                HStack(alignment: .top, spacing: 6) {
                    Text("Connect Claude Code for exact session tracking (adds hooks to its settings).")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Connect Claude Code") { model.installClaudeHooks() }
                }
            case .unreadable:
                Label(
                    "Claude Code's settings file couldn't be read, so it was left untouched.",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let error = model.claudeHooksError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.leading, 22)
        .onAppear { model.refreshClaudeHooksStatus() }
    }

    /// In-place editor for an agent rule's idle grace and waiting policy.
    private func agentOptionsMenu(index: Int, agentRule: AgentRule) -> some View {
        Menu {
            Picker("Grace period", selection: Binding(
                get: { agentRule.grace },
                set: {
                    model.updateRule(
                        at: index,
                        to: .agentActivity(AgentRule(
                            grace: $0,
                            countWaitingAsWorking: agentRule.countWaitingAsWorking
                        ))
                    )
                }
            )) {
                ForEach(Self.agentGracePresets, id: \.seconds) { preset in
                    Text(L(preset.label)).tag(preset.seconds)
                }
            }
            Toggle(
                "Count waiting as working",
                isOn: Binding(
                    get: { agentRule.countWaitingAsWorking },
                    set: {
                        model.updateRule(
                            at: index,
                            to: .agentActivity(AgentRule(
                                grace: agentRule.grace,
                                countWaitingAsWorking: $0
                            ))
                        )
                    }
                )
            )
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Agent rule options")
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
        addMenu("Power & Display", info: L("Conditions Keepresso reads straight from the hardware, with no permission needed: whether you're on AC power, on battery, or charging, and whether an external display is connected. Good for a Mac that should only stay awake while it's docked or plugged in, especially combined with \u{201C}all\u{201D} to mean exactly that.")) {
            powerDisplayItems
        }
        addMenu("Network & Devices", info: L("Conditions about what the Mac is connected to or busy with: a chosen Wi-Fi network, a VPN, a Bluetooth device such as headphones or a controller, a mounted volume, or sustained network throughput for a large download, upload, or sync. Reading Wi-Fi names needs Location permission and Bluetooth needs its own, both requested from this menu; the rest ask for nothing.")) {
            networkDevicesItems
        }
        addMenu("Apps & Activity", info: L("Conditions about what you're actually doing: an app running or frontmost, the camera or microphone in use, audio playing, a game in front, an AI agent working, a process by name, a download finishing in a folder you watch, CPU load above a threshold, a time window, or a calendar event in progress. The camera and microphone conditions read only the device's in-use signal (the green dot), never the stream, so neither asks for permission.")) {
            appsActivityItems
        }
    }

    /// One "Add" category: the menu of conditions, with an ``InfoButton``
    /// alongside explaining what the category covers and what it costs in
    /// permissions. The button sits outside the menu label, since a menu label
    /// can't hold a second control of its own.
    private func addMenu<Items: View>(
        _ title: LocalizedStringKey,
        info: String,
        @ViewBuilder items: () -> Items
    ) -> some View {
        HStack(spacing: 2) {
            Menu { items() } label: { Text(title) }
            InfoButton(text: info)
        }
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
            Menu("Microphone in use by app\u{2026}") {
                micAppChoices { apps in model.addRule(.micInUse(MicInUseRule(apps: apps))) }
            }
            .help("Keeps the Mac awake only while a chosen app is using the microphone, i.e. on a call (Discord, Slack, Zoom, and the like), so an idle browser tab or Voice Memos doesn't. Reads which app holds the mic, no permission needed. If you're on a call now, the app appears under \u{201C}Using the mic now\u{201D}.")
            Button("Audio playing") { model.addRule(.audioPlaying) }
        }
        Section("Gaming") {
            Button("Playing a game") { model.addRule(.gaming) }
                .help("Counts only while a game (or a cloud-gaming app) is the active window, not just running in the background. Keeps holding for 5 minutes after you switch away.")
            Button("Game controller connected") { model.addRule(.controllerConnected) }
                .help("Counts while any game controller is connected, wired or Bluetooth. Rides out a brief reconnect for half a minute.")
            Button("Steam is downloading") { model.addRule(.steamDownload) }
                .help("Counts while Steam is actively downloading or updating a game in any of its libraries, and lets the Mac sleep once the download finishes or is paused. Reads Steam's own bookkeeping, no permission needed.")
        }
        Section("AI agents") {
            Button("AI agent is working") { model.addRule(.agentActivity(AgentRule())) }
                .help("Keeps the Mac awake while a coding-agent session (claude, codex, gemini, aider, and the like) is actively working, judged by its CPU use, and lets it sleep once every session has gone idle for the grace period. The menu lists each detected session. A freshly started session can take a few seconds to read as working.")
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
        case .micInUse:                return "mic.fill"
        case .audioPlaying:            return "speaker.wave.2"
        case .vpnConnected:            return "lock.shield"
        case .bluetoothDevice:         return "antenna.radiowaves.left.and.right"
        case .calendarEvent:           return "calendar"
        case .gaming:                  return "gamecontroller"
        case .controllerConnected:     return "gamecontroller.fill"
        case .steamDownload:           return "arrow.down.app"
        case .throughput:              return "arrow.up.arrow.down"
        case .downloadInFolder:        return "arrow.down.circle"
        case .agentActivity:           return "sparkles"
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
