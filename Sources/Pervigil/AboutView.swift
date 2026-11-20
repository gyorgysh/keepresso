import SwiftUI
import AppKit

/// The About window: app identity, version, who maintains it, where to reach
/// them, and the upstream credit, over the license line.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.top, 4)

            VStack(spacing: 4) {
                Text("Pervigil")
                    .font(.title.bold())
                Text(L("Version %@", AppInfo.versionString))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("A menu-bar app that keeps your Mac awake on your terms.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            author

            links

            Text("GNU GPL v3.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 360)
        .tint(.pervigilAccent)
        .glassWindowBackground()
        .centersAndFrontsWindow()
    }

    /// Maintainer credit and the upstream notice. Pervigil is a fork of
    /// Keepresso, and that project's trademark policy asks forks to say so here.
    private var author: some View {
        VStack(spacing: 6) {
            VStack(spacing: 1) {
                Text("Maintained by")
                    .font(.callout)
                Link(AppInfo.Author.name, destination: AppInfo.Author.github)
                    .font(.title3.weight(.semibold))
            }
            Text("An unofficial fork of Keepresso, not affiliated with its authors.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Issues, the repository, and the upstream project, separated by hairlines.
    private var links: some View {
        HStack(spacing: 10) {
            linkItem(L("Contact"), symbol: "envelope", destination: AppInfo.Author.issues)
            separator
            linkItem(
                "GitHub",
                symbol: "chevron.left.forwardslash.chevron.right",
                destination: AppInfo.repository
            )
            separator
            linkItem(AppInfo.Upstream.name, symbol: "arrow.triangle.branch", destination: AppInfo.Upstream.repository)
        }
        .font(.callout)
    }

    private var separator: some View {
        Text(verbatim: "|")
            .foregroundStyle(.quaternary)
    }

    private func linkItem(_ title: String, symbol: String, destination: URL) -> some View {
        Link(destination: destination) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
        }
    }
}
