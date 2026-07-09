import SwiftUI
import AppKit

/// The About window: app identity, version, license, and a link to the project.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.top, 4)

            VStack(spacing: 4) {
                Text("Keepresso")
                    .font(.title.bold())
                Text("Version \(AppInfo.versionString)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("A menu-bar app that keeps your Mac awake on your terms.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link("View on GitHub", destination: AppInfo.repository)
                .font(.callout)

            Text("GNU GPL v3.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 320)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        .centersAndFrontsWindow()
    }
}
