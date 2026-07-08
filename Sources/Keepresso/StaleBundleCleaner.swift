import Foundation
import KeepressoCore

/// App-side wiring for ``StaleBundleSweep``: remembers where this bundle runs
/// from (a bookmark in `UserDefaults`) and, on later runs, deletes that
/// previous copy once an update has pushed it into the Trash. Without this,
/// Background Task Management's own bookmark keeps resolving the helper's
/// record into the Trash and disabling the daemon after every Homebrew or
/// drag-install update (seen live on macOS 26: `invalidateLaunchItem` firing
/// minutes after each re-registration, as long as the old copy sat in
/// `~/.Trash`).
enum StaleBundleCleaner {
    private static let bookmarkKey = "PreviousBundleBookmark"

    /// Delete the trashed previous copy if there is one, then remember the
    /// current bundle for the run after the next update. Blocking file work;
    /// call it off the main actor.
    static func sweepAndRemember() {
        let bundleURL = Bundle.main.bundleURL
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        let result = StaleBundleSweep.sweep(
            previousBookmark: defaults.data(forKey: bookmarkKey),
            currentBundleURL: bundleURL,
            expectedBundleIdentifier: bundleID,
            resolveBookmark: { data in
                var isStale = false
                return try? URL(
                    resolvingBookmarkData: data,
                    options: [.withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            },
            bundleIdentifier: { Bundle(url: $0)?.bundleIdentifier },
            removeItem: { try FileManager.default.removeItem(at: $0) }
        )
        switch result {
        case .nothingToSweep:
            break
        case .leftAlone(let path, let reason):
            NSLog("Keepresso: previous copy at %@ left alone (%@)", path, reason)
        case .removed(let path):
            NSLog("Keepresso: deleted stale previous copy at %@", path)
        case .removalFailed(let path, let message):
            NSLog("Keepresso: couldn't delete stale previous copy at %@: %@", path, message)
        }
        if let bookmark = try? bundleURL.bookmarkData() {
            defaults.set(bookmark, forKey: bookmarkKey)
        }
    }

    /// Delete copies of the app that a BTM dump says are still tracked in a
    /// Trash folder. Catches strays from before the bookmark existed, with
    /// the same guards as the bookmark sweep: never the running bundle, only
    /// inside a Trash folder, only this app's bundle identifier. Blocking
    /// file work; call it off the main actor.
    static func removeTrashedCopies(at paths: [String]) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = Bundle.main.bundleURL.standardizedFileURL
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard url.standardizedFileURL != current,
                  StaleBundleSweep.isInTrash(url),
                  Bundle(url: url)?.bundleIdentifier == bundleID
            else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                NSLog("Keepresso: deleted stale copy at %@ (found in BTM's records)", path)
            } catch {
                NSLog("Keepresso: couldn't delete stale copy at %@: %@", path, error.localizedDescription)
            }
        }
    }
}
