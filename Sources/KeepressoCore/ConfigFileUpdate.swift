import Foundation

/// Read-transform-write for a config file another program also writes.
///
/// Claude Code, Cursor, Codex and the rest rewrite their own config files
/// (settings changes, plugin installs, trust prompts). If one of them saves
/// between our read and our write, writing our transform of the old contents
/// would silently drop its change. So the file is read again just before the
/// write, and when it moved, the transform is redone on the new contents.
/// After a few tries it gives up and writes nothing. This is best-effort:
/// an uncoordinated writer can still change the file after the final read.
public enum ConfigFileUpdate {
    /// The file kept changing under us on every attempt.
    public struct KeptChangingError: Error, Equatable {
        public init() {}
    }

    /// - Parameters:
    ///   - read: The file's current bytes, `nil` when it doesn't exist yet.
    ///     Its errors (an unreadable file, say) propagate unchanged.
    ///   - write: Replaces the file, called at most once.
    ///   - transform: Builds the new contents from the current ones.
    public static func apply(
        attempts: Int = 3,
        read: () throws -> Data?,
        write: (Data) throws -> Void,
        transform: (Data?) throws -> Data
    ) throws {
        for _ in 0..<max(1, attempts) {
            let original = try read()
            let updated = try transform(original)
            guard try read() == original else { continue }
            guard updated != original else { return }
            try write(updated)
            return
        }
        throw KeptChangingError()
    }
}
