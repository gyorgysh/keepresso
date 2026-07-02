import Foundation

/// A point-in-time reading of which volumes are mounted.
public struct VolumeSnapshot: Equatable, Sendable {
    /// User-visible names of every mounted volume except the boot volume
    /// (which is always mounted, so a rule on it would never do anything).
    public var volumeNames: Set<String>

    public init(volumeNames: Set<String>) {
        self.volumeNames = volumeNames
    }
}

/// Abstraction over the mounted-volume list so volume triggers can be tested
/// without plugging in a drive. Mirrors the ``WorkspaceMonitoring`` seam.
public protocol VolumeMonitoring: AnyObject {
    var current: VolumeSnapshot { get }
}

/// Real backend over `FileManager.mountedVolumeURLs`, an in-memory query of
/// the mount table (no process spawning, cheap enough to read every tick).
public final class FileManagerVolumeMonitor: VolumeMonitoring {
    public init() {}

    public var current: VolumeSnapshot {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        var names: Set<String> = []
        for url in urls where url.path != "/" {
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName)
                ?? url.lastPathComponent
            names.insert(name)
        }
        return VolumeSnapshot(volumeNames: names)
    }
}

/// Fires while a volume with the given name is mounted (an external drive, an
/// SD card, a network share). Pairs with disk keep-alive: one keeps the Mac
/// awake while the drive is there, the other keeps the drive spinning.
public final class VolumeMountedTrigger: Trigger {
    /// The user-visible volume name to look for, e.g. "Backup" or "media".
    public var volumeName: String

    private let monitor: VolumeMonitoring

    public init(volumeName: String, monitor: VolumeMonitoring = FileManagerVolumeMonitor()) {
        self.volumeName = volumeName
        self.monitor = monitor
    }

    public var label: String { "Volume \u{201C}\(volumeName)\u{201D} mounted" }

    public func isSatisfied() -> Bool {
        monitor.current.volumeNames.contains(volumeName)
    }
}
