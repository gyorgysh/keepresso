import Foundation

/// Abstraction over the one directory read the download watch performs, so the
/// trigger logic is unit-testable without a real folder. Mirrors the other
/// filesystem seams (``DiskTouching``).
public protocol DownloadFolderScanning: AnyObject {
    /// Whether `folder` currently contains at least one in-progress download
    /// (a partial-download file, see ``FileManagerDownloadScanner``).
    func hasPartialDownloads(in folder: URL) -> Bool
}

/// Real ``DownloadFolderScanning`` over `FileManager`. A shallow listing of the
/// chosen folder, matching the partial-download extensions browsers and download
/// tools use for files still being written; those markers vanish (the file is
/// renamed to its final name) the moment a download completes, a clean signal.
public final class FileManagerDownloadScanner: DownloadFolderScanning {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func hasPartialDownloads(in folder: URL) -> Bool {
        // A shallow listing is enough: browsers write the partial at the top of
        // the download folder. Safari's `.download` is itself a folder, but its
        // name still carries the extension, so name matching catches it either way.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return false }
        return entries.contains { Self.isPartialDownload($0.lastPathComponent) }
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

/// Fires while a chosen folder holds at least one in-progress download, so the
/// Mac stays awake until the transfer finishes and then is free to sleep.
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

    private let scanner: DownloadFolderScanning
    private var active = false

    public init(folder: URL, scanner: DownloadFolderScanning = FileManagerDownloadScanner()) {
        self.folder = folder
        self.scanner = scanner
    }

    public var label: String { L("Downloading in \u{201C}%@\u{201D}", folder.lastPathComponent) }

    public func tick() { active = scanner.hasPartialDownloads(in: folder) }

    public func isSatisfied() -> Bool { active }
}
