import SwiftUI
import AppKit
import KeepressoCore

struct HotspotPreferencesSection: View {
    @Bindable var model: AppModel
    @State private var location = LocationAuthorizer()
    @State private var password = ""
    @State private var saved = false
    @State private var saving = false
    @State private var credentialRevision = 0
    @State private var error: String?

    private func setting<Value>(_ key: WritableKeyPath<HotspotFallbackConfig, Value>) -> Binding<Value> {
        Binding(get: { model.hotspotConfig[keyPath: key] }, set: {
            var config = model.hotspotConfig; config[keyPath: key] = $0; model.hotspotConfig = config
        })
    }
    var body: some View {
        Section {
            Toggle("Automatic hotspot fallback", isOn: setting(\.enabled))
            if model.hotspotConfig.enabled {
                LabeledContent("Hotspot name") {
                    HStack {
                        TextField("", text: setting(\.ssid))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("Hotspot name"))
                            .frame(minWidth: 100, maxWidth: 240)
                        Menu {
                            ForEach(model.hotspot.nearby, id: \.self) { ssid in
                                Button { var config = model.hotspotConfig; config.ssid = ssid; model.hotspotConfig = config } label: {
                                    Text(verbatim: ssid)
                                }
                            }
                            Divider()
                            Button("Refresh") { Task { await model.hotspot.scan() } }
                        } label: { Text("Choose network") }
                        .disabled(model.hotspot.scanning || !location.isAuthorized)
                    }
                }
                LabeledContent("Hotspot password") {
                    HStack {
                        SecureField("", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("Hotspot password"))
                            .frame(minWidth: 100, maxWidth: 240)
                        Button("Save password") {
                            let ssid = model.hotspotConfig.ssid
                            let value = password
                            saving = true; credentialRevision &+= 1
                            Task {
                                do {
                                    try await model.saveHotspotPassword(value, ssid: ssid)
                                    if model.hotspotConfig.ssid == ssid {
                                        // Invalidate lookups started while the Keychain write was pending.
                                        credentialRevision &+= 1
                                        saved = true; password = ""; error = nil
                                    }
                                }
                                catch { if model.hotspotConfig.ssid == ssid { self.error = error.localizedDescription } }
                                saving = false
                            }
                        }
                        .disabled(saving || password.isEmpty || model.hotspotConfig.ssid.isEmpty || model.hotspotConfig.ssid.utf8.count > 32)
                    }
                }
                if saved {
                    HStack {
                        Label("Password saved in Keychain", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget password") {
                            let ssid = model.hotspotConfig.ssid
                            saving = true; credentialRevision &+= 1
                            Task {
                                defer { saving = false }
                                do {
                                    try await model.forgetHotspotPassword(ssid: ssid)
                                    if model.hotspotConfig.ssid == ssid {
                                        credentialRevision &+= 1
                                        saved = false
                                    }
                                }
                                catch { if model.hotspotConfig.ssid == ssid { self.error = error.localizedDescription } }
                            }
                        }
                        .disabled(saving)
                    }
                    .font(.caption)
                }
                Picker("Allow fallback", selection: setting(\.scope)) {
                    Text("During keep-awake sessions").tag(HotspotFallbackConfig.Scope.activeSession)
                    Text("While the lid is closed").tag(HotspotFallbackConfig.Scope.closedDisplay)
                    Text("Whenever Keepresso is running").tag(HotspotFallbackConfig.Scope.always)
                }
                DisclosureGroup("Connection options") {
                    Picker("Wait before connecting", selection: setting(\.delaySeconds)) {
                        ForEach(Array(Set([0.0, 5, 10, 30, 60, model.hotspotConfig.delaySeconds])).sorted(), id: \.self) { value in
                            Text(L("%d seconds", Int(value))).tag(value)
                        }
                    }
                    Picker("Retry every", selection: setting(\.retrySeconds)) {
                        ForEach(Array(Set([15.0, 30, 60, 120, 300, model.hotspotConfig.retrySeconds])).sorted(), id: \.self) { value in
                            Text(L("%d seconds", Int(value))).tag(value)
                        }
                    }
                    Picker("Minimum battery", selection: setting(\.minimumBatteryPercent)) {
                        Text("No minimum").tag(0)
                        ForEach(Array(Set([10, 20, 30, 50, model.hotspotConfig.minimumBatteryPercent])).filter { $0 > 0 }.sorted(), id: \.self) { value in Text(L("%d%%", value)).tag(value) }
                    }
                    Toggle("Notify when connected", isOn: setting(\.notifyOnConnect))
                }
                Label(status, systemImage: "personalhotspot")
                    .font(.caption).foregroundStyle(.secondary)
                if location.isLoading {
                    ProgressView().controlSize(.small)
                } else if !location.isAuthorized {
                    HStack {
                        Text("Allow Location access to find Wi-Fi networks.")
                        Spacer()
                        if location.canRequest { Button("Allow Location") { location.request() } }
                        Button("Open Settings") { openLocationSettings() }
                    }
                    .font(.caption)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                if let scanError = model.hotspot.scanError { Text(scanError).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Scan networks") { Task { await model.hotspot.scan() } }
                        .disabled(model.hotspot.scanning || !location.isAuthorized)
                    Button("Retry now") { model.hotspot.retryNow(); model.connectivityTick() }
                        .disabled(!saved || !location.isAuthorized)
                    Button("Wi-Fi Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
                    }
                }
            }
        } header: { Text("Hotspot fallback") } footer: {
            Text("Enable Personal Hotspot on your phone. For iPhone discovery, choose Automatic under Ask to join hotspots in macOS Wi-Fi settings. Mobile data charges may apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: model.hotspotConfig.ssid) {
            password = ""; error = nil; saved = false
            credentialRevision &+= 1
            let revision = credentialRevision
            let ssid = model.hotspotConfig.ssid
            let present = await model.hasHotspotPassword(ssid: ssid)
            if !Task.isCancelled && revision == credentialRevision { saved = present }
        }
        .task(id: location.isAuthorized && model.hotspotConfig.enabled) {
            if location.isAuthorized && model.hotspotConfig.enabled { await model.hotspot.scan() }
        }
    }
    private var status: String {
        if model.hotspotConfig.enabled {
            if model.hotspotConfig.ssid.isEmpty { return L("Choose network") }
            if !saved { return L("Save the hotspot password first.") }
        }
        switch model.hotspot.status {
        case .off: return L("Hotspot fallback is off.")
        case .waiting: return L("Waiting for the selected keep-awake conditions.")
        case .monitoring: return L("Monitoring the connection.")
        case .wifiOff: return L("Turn on Wi-Fi to connect to the hotspot.")
        case .connecting: return L("Connecting to hotspot…")
        case .connected: return L("Connected to hotspot")
        case .needsPassword: return L("Save the hotspot password first.")
        case .failed(let message): return message
        }
    }
    private func openLocationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }
}
