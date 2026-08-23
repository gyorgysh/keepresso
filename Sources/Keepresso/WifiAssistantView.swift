import SwiftUI
import AppKit
import CoreWLAN
import KeepressoCore

/// Diagnoses "associated but no internet / login page never appears" and
/// offers the safe next steps: open Captive Network Assistant, open the
/// portal URL, flush DNS if the helper is in. Opening the window does not
/// request Location or an administrator password.
struct WifiAssistantView: View {
    @Bindable var model: AppModel
    @State private var windowVisible = false
    @State private var copied = false
    @State private var actionNote: String?

    private var captive: CaptiveNetworkController { model.captive }

    var body: some View {
        Group {
            if windowVisible {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            actions
                            if let actionNote {
                                Text(actionNote)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(captive.checks) { check in
                                CheckRow(check: check)
                            }
                        }
                        .padding(16)
                    }
                    .scrollContentBackground(.hidden)
                }
                .onAppear { model.refreshCaptive() }
            } else {
                Color.clear
            }
        }
        .frame(width: 460, height: 520)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        .centersAndFrontsWindow()
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .onChange(of: windowVisible) { _, visible in
            if visible { model.refreshCaptive() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Public Wi-Fi")
                    .font(.title2.bold())
                Text("When a cafe or airport network associates but never shows a login page, start here. Nothing runs until you click a button.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                model.refreshCaptive()
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
        }
        .padding(16)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(captive.captiveDetected ? L("Open login page") : L("Open login page anyway")) {
                openLoginPage()
            }
            .buttonStyle(.borderedProminent)

            if let location = captive.portalLocation, let url = URL(string: location) {
                Button("Open portal URL") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button("Turn Wi-Fi off and on") { cycleWiFi() }
                    .buttonStyle(.bordered)
                Button("Flush DNS") { flushDNS() }
                    .buttonStyle(.bordered)
            }

            Button(copied ? L("Copied!") : L("Copy diagnostics")) {
                copyDiagnostics()
            }
            .buttonStyle(.link)
        }
    }

    private func openLoginPage() {
        let cna = URL(fileURLWithPath: "/System/Library/CoreServices/Captive Network Assistant.app")
        if FileManager.default.fileExists(atPath: cna.path) {
            NSWorkspace.shared.open(cna)
            actionNote = L("Opened Captive Network Assistant.")
            return
        }
        if let url = URL(string: "http://captive.apple.com/hotspot-detect.html") {
            NSWorkspace.shared.open(url)
            actionNote = L("Opened captive.apple.com in your browser.")
        }
    }

    private func cycleWiFi() {
        guard let iface = CWWiFiClient.shared().interface() else {
            actionNote = L("Couldn't reach the Wi-Fi interface.")
            return
        }
        do {
            try iface.setPower(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                do {
                    try iface.setPower(true)
                    actionNote = L("Wi-Fi was turned off and back on.")
                    model.refreshCaptive()
                } catch {
                    actionNote = L("Wi-Fi was turned off but could not be turned back on. Use Control Center.")
                }
            }
        } catch {
            let device = captive.snapshot.wifiDevice ?? "en0"
            let command = "networksetup -setairportpower \(device) off; sleep 2; networksetup -setairportpower \(device) on"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            actionNote = L("Couldn't toggle Wi-Fi from here. The command is on the clipboard.")
        }
    }

    private func flushDNS() {
        if model.flushDNS() {
            actionNote = L("DNS cache flushed.")
            model.refreshCaptive()
            return
        }
        let command = "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        actionNote = L("The helper isn't installed, so the flush command is on the clipboard.")
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(captive.snapshot.diagnosticsText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
