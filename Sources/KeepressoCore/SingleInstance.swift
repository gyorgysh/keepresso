import Foundation

/// Decides whether a freshly launched copy of the app is a spurious duplicate
/// that should hand over to an instance already running from the same bundle.
///
/// macOS normally refuses to launch a second instance of a bundle that is
/// already running, and the app leans on that (the language-switch relaunch
/// even waits for the old process to exit before reopening). A click on one of
/// the app's notifications can slip past it: Notification Center asks Launch
/// Services to open the app, and for a background agent that arrived some other
/// way, a build run straight from Xcode, an odd relaunch, it spawns a second
/// copy instead of reactivating the first. Two instances means two menu-bar
/// cups, each holding its own power assertions. This guard collapses them.
///
/// Pure decision logic; the app supplies the running-instance list from
/// `NSRunningApplication` and acts on the result (activate the senior, quit).
public enum SingleInstanceGuard {
    /// One running copy of the app, as much as the decision needs to know.
    public struct Instance: Equatable, Sendable {
        public let pid: Int32
        public let bundleURL: URL?
        public let launchDate: Date?

        public init(pid: Int32, bundleURL: URL?, launchDate: Date?) {
            self.pid = pid
            self.bundleURL = bundleURL
            self.launchDate = launchDate
        }
    }

    /// The instance this one should yield to, or `nil` to keep running.
    ///
    /// A peer qualifies only when it runs from the *same* bundle location and
    /// started *earlier* than this instance: then this process is the newcomer,
    /// the duplicate, so it hands over to the original. Matching on the bundle
    /// path (not just the bundle identifier) keeps the relocation hand-off,
    /// which launches a copy at a different path, out of scope; requiring a
    /// strictly earlier launch means the two sides of any duplicate agree on
    /// which one quits, and a copy that can't date itself never quits blindly.
    public static func peerToYieldTo(current: Instance, peers: [Instance]) -> Instance? {
        guard let currentURL = current.bundleURL?.standardizedFileURL,
              let currentLaunch = current.launchDate else { return nil }
        return peers
            .filter { $0.pid != current.pid }
            .filter { $0.bundleURL?.standardizedFileURL == currentURL }
            .filter { ($0.launchDate ?? .distantFuture) < currentLaunch }
            .min { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
    }
}
