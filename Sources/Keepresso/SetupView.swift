import SwiftUI
import AppKit
import KeepressoCore

/// The headless-readiness Setup screen (v0.6): probes the system for the
/// settings an always-on, headless Mac needs and shows each as ✅ / ⚠️ / 💡 / ❔
/// with a deep link to the right System Settings pane and/or a copyable command.
///
/// Read-only by design: Keepresso never mutates system state (most of these are
/// admin-only and we ship unsandboxed but unprivileged), so this validates and
/// guides rather than changing anything.
struct SetupView: View {
    @Bindable var model: AppModel

    private var checks: [ReadinessCheck] { model.readiness.checks }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(checks) { check in
                        CheckRow(check: check)
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 460, height: 520)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        .onAppear { model.refreshReadiness() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Headless Setup")
                    .font(.title2.bold())
                Text("Checks an always-on Mac (e.g. a headless Mac mini) needs. "
                     + "Keepresso can read these but can't change the system ones, so use the links and commands below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                model.refreshReadiness()
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
        }
        .padding(16)
    }
}

/// One readiness check: status glyph, title, current-state detail, and (when not
/// OK) its remediation affordances.
private struct CheckRow: View {
    let check: ReadinessCheck
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.headline)
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let remediation = check.remediation {
                    Text(remediation.hint)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

                    HStack(spacing: 10) {
                        if let url = remediation.settingsURL {
                            Button(linkLabel(for: url)) { NSWorkspace.shared.open(url) }
                                .buttonStyle(.link)
                        }
                        ForEach(remediation.links, id: \.url) { link in
                            Button(link.label) { NSWorkspace.shared.open(link.url) }
                                .buttonStyle(.link)
                        }
                        if let command = remediation.command {
                            Button(copied ? "Copied!" : "Copy command") { copy(command) }
                                .buttonStyle(.link)
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var glyph: String {
        switch check.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .tip: "lightbulb.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch check.status {
        case .ok: .green
        case .warning: .orange
        case .tip: .blue
        case .unknown: .secondary
        }
    }

    /// "Open Settings" for a System Settings deep link, otherwise a neutral
    /// "Learn more" (e.g. the MyHQ tip points at a web page).
    private func linkLabel(for url: URL) -> String {
        url.scheme?.hasPrefix("x-apple") == true ? "Open Settings" : "Learn more"
    }

    private func copy(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copied = true
    }
}
