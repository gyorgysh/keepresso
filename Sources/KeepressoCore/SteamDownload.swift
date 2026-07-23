import Foundation

/// Detection of an in-progress Steam download or update, so the Mac stays
/// awake until the game is ready. Reads Steam's own bookkeeping, no Steam
/// API and no permission involved: every library's `appmanifest_*.acf`
/// carries a `StateFlags` value whose `UpdateRunning` bit (0x400) turns on
/// exactly while Steam is downloading or verifying and turns off when the
/// download finishes, pauses, or Steam quits. Verified against a live
/// download: queued reads 2, running reads 1026, installed reads 4.
///
/// Leftover folders under `steamapps/downloading/` from aborted downloads
/// linger for months, which is why presence on disk is deliberately not the
/// signal.
public enum SteamDownload {
    /// The `StateFlags` bit Steam sets while an update is actively running.
    public static let updateRunningFlag = 0x400

    /// Whether a manifest's `StateFlags` means "downloading right now".
    /// Paused and merely-queued updates drop this bit, and a paused download
    /// should let the Mac sleep.
    public static func isActive(stateFlags: Int) -> Bool {
        stateFlags & updateRunningFlag != 0
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
            for manifest in manifests {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let flags = SteamDownload.stateFlags(fromACF: text)
                else { continue }
                if SteamDownload.isActive(stateFlags: flags) { return true }
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
