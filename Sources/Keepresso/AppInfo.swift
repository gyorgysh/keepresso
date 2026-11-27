import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L("Unknown")
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? L("Unknown")
    }

    static var versionString: String { "\(version) (\(build))" }

    static let repository = URL(string: "https://github.com/gyorgysh/keepresso")!

    static let website = URL(string: "https://keepresso.com/?ref=\(referrer)")!

    static let donate = URL(string: "https://gyorgy.sh/donate?ref=\(referrer)")!

    static let referrer = "keepresso_app"

    enum Author {
        static let name = "Gyorgy"
        static let site = URL(string: "https://gyorgy.sh/?ref=\(AppInfo.referrer)")!
        static let siteLabel = "gyorgy.sh"
        static let email = URL(string: "mailto:gyorgy@pueev.com")!
        static let github = URL(string: "https://github.com/gyorgysh")!
    }
}
