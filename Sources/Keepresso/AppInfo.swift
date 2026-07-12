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
}
