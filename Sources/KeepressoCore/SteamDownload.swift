import Foundation

/// Detection of an in-progress Steam download or update, so the Mac stays
/// awake until the game is ready. Reads Steam's own bookkeeping, no Steam
/// API and no permission involved. Two conditions, both verified against a
/// live download:
///
/// 1. A library's `appmanifest_*.acf` has the `UpdateRunning` bit (0x400) in
///    `StateFlags`: queued reads 2, downloading reads 1026, installed reads
///    4. The bit alone is not enough: a download the user actively stops
///    KEEPS 1026, observed live.
/// 2. Chunks are actually landing: something under that library's
///    `steamapps/downloading/` was written within the last minute. Writes
///    are continuous during a real download and stop within seconds of a
///    pause, so this is the liveness half of the judgment.
///
/// Leftover folders under `steamapps/downloading/` from aborted downloads
/// linger for months, which is why presence on disk is deliberately not the
/// signal either.
public enum SteamDownload {
    /// The `StateFlags` bit Steam sets while an update is running (which
    /// includes paused-by-the-user, hence the recency check).
    public static let updateRunningFlag = 0x400

    /// How fresh the newest write under `downloading/` must be for a flagged
    /// update to count as actually downloading. Long enough to ride out
    /// brief verification reads, short enough that a paused download
    /// releases promptly (the trigger's own grace stacks on top).
    public static let writeRecencyWindow: TimeInterval = 60

    /// The flag half of the judgment: whether `StateFlags` claims a running
    /// update. Steam leaves this set while paused, so callers must also
    /// check write recency.
    public static func isActive(stateFlags: Int) -> Bool {
        stateFlags & updateRunningFlag != 0
    }

    /// Whether anything under `directory` was modified within
    /// ``writeRecencyWindow``. Walks lazily and stops at the first fresh
    /// file, which during a real download is one of the first visited.
    static func hasRecentWrite(
        under directory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-writeRecencyWindow)
        guard let walker = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let file as URL in walker {
            // Only real files count: Steam creates the folder skeleton the
            // moment a download is queued, so fresh directory mtimes say
            // nothing about bytes actually flowing.
            let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate, modified > cutoff {
                return true
            }
        }
        return false
    }

    /// Steam's default install root for the current user.
    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Steam", isDirectory: true)
    }

    /// Library paths out of `steamapps/libraryfolders.vdf` (the default
    /// library lists itself, extra volumes follow). VDF is a simple quoted
    /// key/value format; only `"path"` lines matter here.
    public static func libraryPaths(fromVDF text: String) -> [String] {
        var paths: [String] = []
        let pattern = #/"path"\s+"([^"]+)"/#
        for line in text.split(whereSeparator: \.isNewline) {
            if let match = line.firstMatch(of: pattern) {
                paths.append(String(match.1).replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return paths
    }

    /// The `StateFlags` value out of one `appmanifest_*.acf`, or nil when
    /// the file has none (malformed or truncated mid-write).
    public static func stateFlags(fromACF text: String) -> Int? {
        let pattern = #/"StateFlags"\s+"(\d+)"/#
        return text.firstMatch(of: pattern).flatMap { Int($0.1) }
    }
}

// MARK: - Monitor

/// Abstraction over "is Steam downloading?" so the trigger is testable
/// without a Steam install. Mirrors the other monitor seams.
public protocol SteamDownloadMonitoring: AnyObject {
    var isDownloading: Bool { get }
}

/// Real backend: sweep every Steam library's manifests for the running bit.
/// Manifests are small (under a kilobyte) and libraries hold at most a few
/// hundred, so a sweep is cheap; readings are still cached briefly like the
/// other filesystem probes.
public final class FileSteamDownloadMonitor: SteamDownloadMonitoring {
    private let cache: TTLCache<Bool>

    public convenience init() {
        self.init(probe: Self.probeSystem)
    }

    /// The probe and clock are injectable so the cache can be unit-tested.
    init(
        ttl: TimeInterval = 5,
        now: @escaping () -> Date = Date.init,
        probe: @escaping () -> Bool
    ) {
        cache = TTLCache(ttl: ttl, now: now, probe: probe)
    }

    public var isDownloading: Bool { cache.current }

    static func probeSystem() -> Bool {
        let fm = FileManager.default
        let defaultSteamapps = SteamDownload.defaultRoot()
            .appendingPathComponent("steamapps", isDirectory: true)
        // The default library's libraryfolders.vdf lists every library,
        // itself included; fall back to the default alone if it is missing.
        var libraries = [defaultSteamapps]
        let vdf = defaultSteamapps.appendingPathComponent("libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            let listed = SteamDownload.libraryPaths(fromVDF: text).map {
                URL(fileURLWithPath: $0).appendingPathComponent("steamapps", isDirectory: true)
            }
            if !listed.isEmpty { libraries = listed }
        }
        for library in libraries {
            let manifests = (try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
                ?? []
            let flagged = manifests.contains { manifest in
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let flags = SteamDownload.stateFlags(fromACF: text)
                else { return false }
                return SteamDownload.isActive(stateFlags: flags)
            }
            // The walk only runs when a manifest claims a running update, so
            // the common no-download case never touches the chunk folders.
            if flagged, SteamDownload.hasRecentWrite(
                under: library.appendingPathComponent("downloading", isDirectory: true)
            ) {
                return true
            }
        }
        return false
    }
}

// MARK: - Trigger

/// Fires while any Steam library has a download or update actively running.
public final class SteamDownloadTrigger: Trigger {
    /// Generous grace: between depots Steam briefly flips to verification
    /// and back, and a session dropping mid-multi-depot download would
    /// defeat the point.
    public static let releaseGrace: TimeInterval = 120

    private let monitor: SteamDownloadMonitoring

    public init(monitor: SteamDownloadMonitoring = FileSteamDownloadMonitor()) {
        self.monitor = monitor
    }

    public var label: String { L("Steam is downloading") }

    public func isSatisfied() -> Bool {
        monitor.isDownloading
    }
}
