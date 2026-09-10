import Foundation

/// Abstraction over the one directory read the download watch performs, so the
/// trigger logic is unit-testable without a real folder. Mirrors the other
/// filesystem seams (``DiskTouching``).
public protocol DownloadFolderScanning: AnyObject {
    /// When the most recently written in-progress download in `folder` was last
    /// written to, or `nil` when the folder holds no partial-download markers
    /// at all (see ``FileManagerDownloadScanner``).
    func newestPartialDownloadWrite(in folder: URL) -> Date?
}

/// Real ``DownloadFolderScanning`` over `FileManager`. A shallow listing of the
/// chosen folder, matching the partial-download extensions browsers and download
/// tools use for files still being written; those markers vanish (the file is
/// renamed to its final name) the moment a download completes, a clean signal.
///
/// They do not vanish when a download is cancelled, paused, or interrupted, so
/// each marker is reported with its last write time and the trigger decides
/// whether it is still moving.
public final class FileManagerDownloadScanner: DownloadFolderScanning {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func newestPartialDownloadWrite(in folder: URL) -> Date? {
        // A shallow listing is enough: browsers write the partial at the top of
        // the download folder. Safari's `.download` is itself a folder, but its
        // name still carries the extension, so name matching catches it either way.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return nil }
        var newest: Date?
        for entry in entries where Self.isPartialDownload(entry.lastPathComponent) {
            guard let written = lastWrite(of: entry) else { continue }
            if written > newest ?? .distantPast { newest = written }
        }
        return newest
    }

    /// The newest write anywhere in one marker. Safari's `.download` is a
    /// bundle whose own timestamp stops moving while the file inside it grows,
    /// so a folder marker is judged by what it contains. A marker we cannot
    /// stat at all counts as no evidence rather than as a live download: an
    /// unreadable leftover must not pin the Mac awake.
    private func lastWrite(of entry: URL) -> Date? {
        let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
        var newest = values?.contentModificationDate
        guard values?.isDirectory == true,
              let children = try? fileManager.contentsOfDirectory(
                  at: entry, includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else { return newest }
        for child in children {
            guard let written = try? child.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else { continue }
            if written > newest ?? .distantPast { newest = written }
        }
        return newest
    }

    /// Extensions browsers/download tools give a file that is still downloading:
    /// Chrome/Chromium `.crdownload`, Safari `.download`, Firefox `.part`, Edge
    /// `.partial`, Opera `.opdownload`. Deliberately **not** `.tmp`: countless
    /// unrelated apps leave `.tmp` files behind, and matching it would pin the
    /// Mac awake on a stray temp file that never gets cleaned up.
    static let partialExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "opdownload",
    ]

    /// Pure match, exposed for direct unit testing.
    static func isPartialDownload(_ name: String) -> Bool {
        partialExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// Fires while a chosen folder holds a download that is still moving, so the
/// Mac stays awake until the transfer finishes and then is free to sleep.
///
/// A marker's presence is not enough on its own. Cancel a download, pause one,
/// or lose the connection mid-file, and the browser leaves the partial behind
/// for good: a `.download` bundle from days ago would otherwise hold the Mac
/// awake forever, under a rule that claims something is downloading. So a
/// marker counts only while it is being written to, see ``abandonedAfter``.
///
/// The scan runs once per reconcile in ``tick()`` and the result is cached, so
/// ``isSatisfied()`` stays a pure read and the menu's live rule list doesn't hit
/// the disk on every render (the same discipline as ``CPULoadTrigger``). The
/// factory wraps this in a ``GracePeriodTrigger`` so a brief gap between files in
/// a batch download (one partial renamed away before the next appears) doesn't
/// drop the session.
public final class DownloadInFolderTrigger: Trigger {
    /// The folder being watched for partial-download files.
    public var folder: URL

    /// Seconds to keep holding after the last partial-download file disappears,
    /// bridging the gap between queued downloads in a batch.
    public static let releaseGrace: TimeInterval = 30

    /// How long a partial may sit unwritten before it counts as abandoned
    /// rather than in progress. A live download writes constantly, so this only
    /// has to outlast a slow server's quiet spell. A transfer that stalls this
    /// long and then resumes re-arms the trigger on the next tick.
    public static let abandonedAfter: TimeInterval = 300

    private let scanner: DownloadFolderScanning
    private let now: () -> Date
    private var active = false

    public init(
        folder: URL,
        scanner: DownloadFolderScanning = FileManagerDownloadScanner(),
        now: @escaping () -> Date = Date.init
    ) {
        self.folder = folder
        self.scanner = scanner
        self.now = now
    }

    public var label: String { L("Downloading in \u{201C}%@\u{201D}", folder.lastPathComponent) }

    public func tick() {
        guard let written = scanner.newestPartialDownloadWrite(in: folder) else {
            active = false
            return
        }
        // A timestamp in the future (a clock change, a file copied off another
        // machine) reads as fresh rather than as abandoned.
        active = now().timeIntervalSince(written) < Self.abandonedAfter
    }

    public func isSatisfied() -> Bool { active }
}
