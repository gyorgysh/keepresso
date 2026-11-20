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

    /// Project home.
    static let repository = URL(string: "https://github.com/bubb4rd/pervigil")!

    /// The destination for a person's "Learn more". Pervigil has no website of
    /// its own yet, so this is the repository.
    static let website = repository

    /// Opened from the icon's right-click menu ("Support Pervigil…"). Points at
    /// the repository until there is a sponsorship page.
    static let donate = repository

    /// Who maintains it, and how to reach them. Shown in the About window.
    enum Author {
        static let name = "bubb4rd"
        static let github = URL(string: "https://github.com/bubb4rd")!
        static let issues = URL(string: "https://github.com/bubb4rd/pervigil/issues")!
    }

    /// The upstream project Pervigil is forked from, credited in the About
    /// window as its trademark policy asks.
    enum Upstream {
        static let name = "Keepresso"
        static let repository = URL(string: "https://github.com/gyorgysh/keepresso")!
    }
}
