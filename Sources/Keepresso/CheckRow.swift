import SwiftUI
import AppKit
import KeepressoCore

/// One readiness check: status glyph, title, current-state detail, and (when not
/// OK) its remediation affordances.
struct CheckRow: View {
    let check: ReadinessCheck
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.25), value: check.status)
                .accessibilityLabel(statusLabel)

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
                                .contentTransition(.opacity)
                                .animation(.easeInOut(duration: 0.2), value: copied)
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

    /// Spoken status for VoiceOver, since the glyph's meaning is otherwise
    /// carried only by shape and color.
    private var statusLabel: String {
        switch check.status {
        case .ok: "OK"
        case .warning: "Needs attention"
        case .tip: "Tip"
        case .unknown: "Unknown"
        }
    }

    /// "Open Settings" for a System Settings deep link, otherwise a neutral
    /// "Learn more" (e.g. the MyAgens tip points at a web page).
    private func linkLabel(for url: URL) -> String {
        url.scheme?.hasPrefix("x-apple") == true ? "Open Settings" : "Learn more"
    }

    private func copy(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copied = true
        // Settle back to the offer after a moment, so the row doesn't read
        // "Copied!" forever.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
