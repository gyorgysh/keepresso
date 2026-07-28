import SwiftUI
import AppKit

/// The About window: app identity, version, who made it, and where to reach
/// them, over the license line.
struct AboutView: View {
    /// The author photo ships as a loose PNG resource next to the sources.
    private static let avatar = Bundle.main.image(forResource: "AuthorAvatar")

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.top, 4)

            VStack(spacing: 4) {
                Text("Keepresso")
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
        .tint(.keepressoBrew)
        .glassWindowBackground()
        .centersAndFrontsWindow()
    }

    /// Photo, credit line, name, and what the author does.
    private var author: some View {
        HStack(spacing: 12) {
            if let avatar = Self.avatar {
                Image(nsImage: avatar)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Made with ☕ by")
                    .font(.callout)
                Link(AppInfo.Author.name, destination: AppInfo.Author.site)
                    .font(.title3.weight(.semibold))
                Text("AI-native product engineer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Mail, personal site, and the author's GitHub, separated by hairlines.
    private var links: some View {
        HStack(spacing: 10) {
            linkItem(L("Contact"), symbol: "envelope", destination: AppInfo.Author.email)
            separator
            linkItem(AppInfo.Author.siteLabel, symbol: "globe", destination: AppInfo.Author.site)
            separator
            linkItem(
                "GitHub",
                symbol: "chevron.left.forwardslash.chevron.right",
                destination: AppInfo.Author.github
            )
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
