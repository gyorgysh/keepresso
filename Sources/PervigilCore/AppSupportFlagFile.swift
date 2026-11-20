import Foundation

/// A file under `~/Library/Application Support/Pervigil/` whose presence is
/// the state: crash-recovery flags that must outlive the process. Empty, or
/// holding the pid of the app run that created it (see ``create(owner:)``).
public struct AppSupportFlagFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Pervigil/<name>`, falling back to the
    /// temporary directory if Application Support can't be resolved.
    public static func defaultURL(named name: String) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Pervigil", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    public var isPresent: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Create the flag (and its folder). Returns whether the write succeeded.
    ///
    /// `owner` stamps the flag with the pid of the app run that created it. A
    /// root watchdog loop outlives its app by up to one cycle, so after a
    /// quick relaunch the old loop is still winding down while the new run
    /// already has a flag of its own. The stamp lets the old loop tell that
    /// flag from its own and leave it alone.
    public func create(owner: Int32? = nil) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((owner.map(String.init) ?? "").utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
