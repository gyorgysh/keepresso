import Foundation

/// Static app metadata and external links, read once from the bundle so the
/// About window has a single source for the version string and repository URL.
enum AppInfo {
    /// Marketing version, e.g. "0.5.0".
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L("Unknown")
    }

    /// Build number, e.g. "3".
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? L("Unknown")
    }

    /// "0.5.0 (3)".
    static var versionString: String { "\(version) (\(build))" }

    /// Project home. Placeholder until the GitHub remote is set; update here when
    /// the repository URL is known.
    static let repository = URL(string: "https://github.com/gyorgysh/keepresso")!

    /// The public website: the destination for a person's "Learn more", where
    /// the repository is aimed at contributors.
    static let website = URL(string: "https://keepresso.com/?ref=\(referrer)")!

    /// Tags outbound links to sites we own, so analytics can tell app traffic
    /// apart from search and social. Left off mailto and GitHub, which have
    /// nothing to read it.
    static let referrer = "keepresso_app"

    /// Who made it, and how to reach them. Shown in the About window.
    enum Author {
        static let name = "Gyorgy"
        static let site = URL(string: "https://gyorgy.sh/?ref=\(AppInfo.referrer)")!
        static let siteLabel = "gyorgy.sh"
        static let email = URL(string: "mailto:gyorgy@pueev.com")!
        static let github = URL(string: "https://github.com/gyorgysh")!
    }
}
