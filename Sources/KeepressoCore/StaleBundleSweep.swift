import Foundation

/// Outcome of one stale-bundle sweep, for logging and tests.
public enum StaleBundleSweepResult: Equatable, Sendable {
    /// No previous copy to consider: no bookmark yet, the bookmark no longer
    /// resolves (the old copy is really gone), or it still points at the
    /// running bundle (no update happened).
    case nothingToSweep
    /// A previous copy exists but stays untouched, with the reason: it lives
    /// outside any Trash folder, or it isn't this app.
    case leftAlone(path: String, reason: String)
    /// The trashed previous copy was deleted.
    case removed(path: String)
    /// The trashed previous copy was found but couldn't be deleted.
    case removalFailed(path: String, message: String)
}

/// Finds and deletes the previous copy of the app after an update has pushed
/// it into the Trash.
///
/// Why this matters: macOS Background Task Management tracks the app owning a
/// registered daemon by a file bookmark, and a bookmark follows the file it
/// names. Homebrew's cask upgrade and manual drag-installs both move the old
/// bundle to the Trash, so BTM's periodic revalidation resolves the record
/// into the Trash, decides the app is gone, and disables the helper daemon;
/// re-registering only helps until the next revalidation pass. Deleting the
/// trashed copy is the fix: once the bookmark can't resolve, the record
/// settles on the installed copy. The app finds its own previous copy the
/// same way BTM does, by resolving a bookmark it stored on the last run, and
/// same-team code signing exempts it from the App Management protection that
/// keeps other processes out of app bundles.
///
/// Pure decision logic behind injected file operations; the app wires in the
/// real bookmark store and `FileManager` (`StaleBundleCleaner`).
public enum StaleBundleSweep {
    /// Decide what to do about the bundle the previous run's bookmark points
    /// at, and do it via `removeItem`. Deletion is deliberately narrow: only
    /// a bundle that is not the running one, sits inside a Trash folder, and
    /// carries the expected bundle identifier is touched.
    public static func sweep(
        previousBookmark: Data?,
        currentBundleURL: URL,
        expectedBundleIdentifier: String,
        resolveBookmark: (Data) -> URL?,
        bundleIdentifier: (URL) -> String?,
        removeItem: (URL) throws -> Void
    ) -> StaleBundleSweepResult {
        guard let previousBookmark,
              let previous = resolveBookmark(previousBookmark)
        else { return .nothingToSweep }
        if previous.standardizedFileURL == currentBundleURL.standardizedFileURL {
            return .nothingToSweep
        }
        guard isInTrash(previous) else {
            return .leftAlone(path: previous.path, reason: "not in a Trash folder")
        }
        guard bundleIdentifier(previous) == expectedBundleIdentifier else {
            return .leftAlone(path: previous.path, reason: "bundle identifier differs")
        }
        do {
            try removeItem(previous)
            return .removed(path: previous.path)
        } catch {
            return .removalFailed(path: previous.path, message: error.localizedDescription)
        }
    }

    /// Whether a URL sits inside a Trash folder: the user's `~/.Trash` or a
    /// volume's `.Trashes`.
    public static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}
