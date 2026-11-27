import SwiftUI
import AppKit
import KeepressoCore

struct CheckRow: View {
    let check: ReadinessCheck
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon

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
                            Button(copied ? L("Copied!") : L("Copy command")) { copy(command) }
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

    private var icon: some View {
        Group {
            if isBluetoothRow {
                BluetoothRune()
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 11, height: 17)
            } else if let symbol = Self.topicSymbols[check.id] {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .font(.title3)
            } else {
                Image(systemName: glyph)
                    .foregroundStyle(tint)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 22, height: 20)
        .overlay(alignment: .bottomTrailing) {
            if hasTopicIcon {
                Image(systemName: badgeGlyph)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white, tint)
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: 3, y: 3)
            }
        }
        .animation(.snappy(duration: 0.25), value: check.status)
        .accessibilityLabel(statusLabel)
    }

    /// SF Symbol per check id, keyed by the checks' stable ids. Bluetooth is
    /// missing on purpose: SF Symbols has no Bluetooth glyph (the mark is
    /// licensed), so those rows draw ``BluetoothRune`` instead.
    private static let topicSymbols: [String: String] = [
        "wake-for-network": "network",
        "auto-restart": "powerplug.fill",
        "system-sleep": "moon.zzz.fill",
        "filevault": "lock.fill",
        "auto-login": "person.fill",
        "remote-login": "apple.terminal.fill",
        "screen-sharing": "display",
        "tip-tokenstat": "sparkles",
        "perm-login-item": "power",
        "perm-location": "location.fill",
        "perm-calendar": "calendar",
        "perm-notifications": "bell.badge.fill",
        "stream-ethernet": "cable.connector.horizontal",
        "stream-wifi-channel": "wifi",
        "stream-game-mode": "gamecontroller.fill",
        "stream-browser-gaming": "globe",
        "stream-location-note": "location.fill",
        "stream-read-more": "book.fill",
        "wifi-radio": "wifi",
        "wifi-associated": "wifi",
        "wifi-address": "network",
        "wifi-captive": "globe",
        "wifi-dns": "server.rack",
        "wifi-path": "point.3.connected.trianglepath.dotted",
        "wifi-vpn": "lock.shield.fill",
        "wifi-custom-dns": "list.bullet.rectangle",
        "wifi-private-mac": "antenna.radiowaves.left.and.right",
        "wifi-private-relay": "eye.slash.fill",
    ]

    private var isBluetoothRow: Bool {
        check.id == "perm-bluetooth" || check.id == "stream-bluetooth"
    }

    private var hasTopicIcon: Bool {
        isBluetoothRow || Self.topicSymbols[check.id] != nil
    }

    private var badgeGlyph: String {
        switch check.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .tip: "info.circle.fill"
        case .unknown: "questionmark.circle.fill"
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

    private var statusLabel: String {
        switch check.status {
        case .ok: L("OK")
        case .warning: L("Needs attention")
        case .tip: L("Tip")
        case .unknown: L("Unknown")
        }
    }

    private func linkLabel(for url: URL) -> String {
        url.scheme?.hasPrefix("x-apple") == true ? L("Open Settings") : L("Learn more")
    }

    private func copy(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

struct BluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0, 0.75))
        path.addLine(to: point(1, 0.25))
        path.addLine(to: point(0.5, 0))
        path.addLine(to: point(0.5, 1))
        path.addLine(to: point(1, 0.75))
        path.addLine(to: point(0, 0.25))
        return path
    }
}
