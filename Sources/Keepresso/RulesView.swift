import SwiftUI
import KeepressoCore

/// The trigger rules editor shown in the menu when "Activate by triggers" is on.
///
/// Conditions are added from a menu rather than typed: power/display rules are
/// fixed, and Wi-Fi / app rules are seeded from current system state (the joined
/// SSID, the list of running apps) so there are no free-text fields to get
/// wrong. App rules can be tuned in place (running/frontmost + grace period).
struct RulesView: View {
    @Bindable var model: AppModel
    @State private var location = LocationAuthorizer()
    /// Free-text entry for a custom "process running" rule.
    @State private var processQuery = ""

    /// Common processes offered as one-click presets for the process rule.
    private static let processPresets = ["claude", "codex", "node", "python", "ffmpeg"]

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
            Section("Process is running") {
                ForEach(Self.processPresets, id: \.self) { name in
                    Button(name) { model.addRule(.process(name)) }
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
        }
    }
}
