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

    /// The launch sweep, run synchronously before anything in the process
    /// touches `SMAppService` or BTM: even a plain status read makes BTM
    /// revalidate the helper's record, so the poisonous Trash copy has to be
    /// gone before the first contact, not cleaned up sometime after.
    ///
    /// The bookmark pass runs every launch (a few file stats). The deeper
    /// pass, reading BTM's own records and probing the obvious Trash path,
    /// runs only when this looks like the first launch after an update, so
    /// ordinary launches pay nothing for it.
    static func sweepAtStartup(afterUpdate: Bool) {
        let result = sweepAndRemember()
        // The copy Sparkle or Homebrew just trashed under our own name,
        // whether or not BTM has a record of it. Runs every launch (one file
        // stat when the Trash is clean), never gated on `afterUpdate` or the
        // bookmark: the bookmark can resolve to the new bundle at the same
        // path instead of following the old one into the Trash, and the
        // update flag can't fire on the first update from a build that
        // predates its record. Both gaps left the trashed 1.11.x copy behind
        // and got the helper disabled right after the update.
        removeTrashedCopyUnderOwnName()
        guard afterUpdate || result != .nothingToSweep else { return }
        // BTM's records name every copy it still tracks; any of them inside
        // a Trash folder is exactly the poison that gets the daemon disabled.
        if let bundleID = Bundle.main.bundleIdentifier,
           let dump = SFLToolBTMDumper().dumpBTM() {
            let findings = BTMInspection.findings(
                inDump: dump,
                bundleIdentifier: bundleID,
                helperLabel: HelperService.machServiceLabel
            )
            if !findings.staleCopyPaths.isEmpty {
                removeTrashedCopies(at: findings.staleCopyPaths)
            }
        }
    }

    /// The bookmark pass plus the direct probe under our own name, for the
    /// helper repair paths (verify, reinstall): a repair can't stick while a
    /// trashed copy remains, however it got missed at launch. Blocking file
    /// work; call it off the main actor.
    static func sweepNow() {
        _ = sweepAndRemember()
        removeTrashedCopyUnderOwnName()
    }

    /// Probe the user's Trash for a copy under this bundle's own file name
    /// and delete it. The Trash itself can't be enumerated without Full Disk
    /// Access, but a direct path needs none.
    private static func removeTrashedCopyUnderOwnName() {
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        else { return }
        let candidate = trash.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        removeTrashedCopies(at: [candidate.path])
    }

    /// Delete the trashed previous copy if there is one, then remember the
    /// current bundle for the run after the next update. Blocking file work;
    /// call it off the main actor (or from `sweepAtStartup`, before the UI
    /// exists).
    @discardableResult
    static func sweepAndRemember() -> StaleBundleSweepResult {
        let bundleURL = Bundle.main.bundleURL
        guard let bundleID = Bundle.main.bundleIdentifier else { return .nothingToSweep }
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
        return result
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

/// Detects the first launch after an update by comparing the build number
/// against the one recorded on the previous run. The flag drives the two
/// version-boundary chores: the deep stale-bundle sweep above, and retiring
/// the helper daemon so launchd's next spawn runs the freshly installed
/// binary instead of the old image it kept in memory.
enum UpdateArrival {
    private static let key = "LastRunBuild"

    /// Whether the build changed since the last run, recording the current
    /// one either way. A genuinely first launch reports false: there is no
    /// previous version to clean up after.
    static func checkAndRecord() -> Bool {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: key)
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return false }
        defaults.set(current, forKey: key)
        if let previous { return current != previous }
        // No build recorded: either a fresh install (nothing to clean up
        // after) or the first run after updating from a build that predates
        // this record. Saved settings tell the two apart, a fresh install
        // has none yet, so an update from any pre-record build still gets
        // its version-boundary chores (missing them is what got the helper
        // disabled on the 1.12.0 update).
        return defaults.data(forKey: UserDefaultsSettingsStore.defaultKey) != nil
    }
}
