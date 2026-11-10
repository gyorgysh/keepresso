import Foundation

/// Which Claude Code versions are installed on this Mac, so hook events are
/// only written for installs that understand them.
///
/// Every Claude Code reads the same `~/.claude/settings.json`: the native CLI,
/// a Homebrew or npm CLI, and the copy the Claude desktop app runs. A newer
/// event name is only safe once all of them know it. Anything found whose
/// version can't be read counts against it, because guessing wrong costs the
/// user their whole settings file on an old install.
public struct ClaudeCodeVersions: Equatable, Sendable {
    /// Versions read from installs we could identify.
    public var known: [Version]
    /// Installs found on disk whose version couldn't be read.
    public var unknownCount: Int

    public init(known: [Version] = [], unknownCount: Int = 0) {
        self.known = known
        self.unknownCount = unknownCount
    }

    /// The first Claude Code with the StopFailure hook event.
    public static let stopFailureMinimum = Version(2, 1, 78)

    /// True only when at least one install was found, every one has a
    /// readable version, and all of them are new enough.
    public var supportsStopFailure: Bool {
        !known.isEmpty && unknownCount == 0
            && known.allSatisfy { $0 >= Self.stopFailureMinimum }
    }

    /// A dotted numeric version, compared component by component.
    public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
        public var parts: [Int]

        public init(_ parts: Int...) { self.parts = parts }

        /// Parses "2.1.317". Anything else (a hash, "latest", a prerelease
        /// suffix) is not a version we can vouch for.
        public init?(_ string: String) {
            let pieces = string.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count >= 2, pieces.count <= 4 else { return nil }
            var parts: [Int] = []
            for piece in pieces {
                guard !piece.isEmpty,
                      piece.utf8.allSatisfy({ (48...57).contains($0) }),
                      let n = Int(piece)
                else { return nil }
                parts.append(n)
            }
            self.parts = parts
        }

        /// Trailing zeros dropped, so 2.1 and 2.1.0 are one version for
        /// equality, hashing, and ordering alike.
        private var normalized: ArraySlice<Int> {
            var end = parts.count
            while end > 0, parts[end - 1] == 0 { end -= 1 }
            return parts[..<end]
        }

        public static func == (lhs: Version, rhs: Version) -> Bool {
            lhs.normalized == rhs.normalized
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(Array(normalized))
        }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            for i in 0..<max(lhs.parts.count, rhs.parts.count) {
                let a = i < lhs.parts.count ? lhs.parts[i] : 0
                let b = i < rhs.parts.count ? rhs.parts[i] : 0
                if a != b { return a < b }
            }
            return false
        }

        public var description: String { parts.map(String.init).joined(separator: ".") }
    }

    // MARK: - Detection

    /// File-system access, injectable for tests.
    public struct FileAccess: Sendable {
        public var exists: @Sendable (String) -> Bool
        /// The fully resolved path behind a symlink chain, or the path itself.
        public var resolve: @Sendable (String) -> String
        public var list: @Sendable (String) -> [String]?
        public var read: @Sendable (String) -> Data?

        public init(
            exists: @escaping @Sendable (String) -> Bool,
            resolve: @escaping @Sendable (String) -> String,
            list: @escaping @Sendable (String) -> [String]?,
            read: @escaping @Sendable (String) -> Data?
        ) {
            self.exists = exists
            self.resolve = resolve
            self.list = list
            self.read = read
        }

        public static let live = FileAccess(
            exists: { FileManager.default.fileExists(atPath: $0) },
            resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            list: { try? FileManager.default.contentsOfDirectory(atPath: $0) },
            read: { FileManager.default.contents(atPath: $0) })
    }

    /// Finds the Claude Code installs Keepresso knows how to recognize.
    ///
    /// - The CLI launchers: the native installer (`~/.local/bin`), the older
    ///   local install (`~/.claude/local`), Homebrew, `/usr/local`, and the
    ///   usual per-user npm, bun, Volta, and nvm bins. Resolved through their
    ///   symlinks, the version comes from the native installer's
    ///   `versions/<version>` folder, a Homebrew cask's
    ///   `Caskroom/claude-code/<version>` folder, or the npm package's
    ///   `package.json` (beside the target, or in a `node_modules` next to a
    ///   wrapper script). A launcher that resolves to none of those is
    ///   counted as unknown.
    /// - The Claude desktop app's own copy under
    ///   `~/Library/Application Support/Claude/claude-code/<version>`: the
    ///   app runs the newest one there, so only that one counts.
    public static func detect(home: String, files: FileAccess = .live) -> ClaudeCodeVersions {
        var result = ClaudeCodeVersions()
        var seen = Set<String>()
        var launchers = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let nodes = files.list(nvm) {
            for node in nodes.sorted() where !node.hasPrefix(".") {
                launchers.append("\(nvm)/\(node)/bin/claude")
            }
        } else if files.exists(nvm) {
            // An unreadable directory may hide an older CLI sharing settings.
            result.unknownCount += 1
        }
        for launcher in launchers where files.exists(launcher) {
            let target = files.resolve(launcher)
            // Two launchers pointing at one install count once.
            guard seen.insert(target).inserted else { continue }
            if let version = version(ofLauncherTarget: target, files: files)
                ?? packageVersion(
                    "\((launcher as NSString).deletingLastPathComponent)/node_modules/@anthropic-ai/claude-code",
                    files: files) {
                result.known.append(version)
            } else {
                result.unknownCount += 1
            }
        }
        let appDir = "\(home)/Library/Application Support/Claude/claude-code"
        if let entries = files.list(appDir) {
            if let newest = entries.compactMap(Version.init).max() {
                result.known.append(newest)
            } else if !entries.filter({ !$0.hasPrefix(".") }).isEmpty {
                result.unknownCount += 1
            }
        } else if files.exists(appDir) {
            result.unknownCount += 1
        }
        return result
    }

    static func version(ofLauncherTarget target: String, files: FileAccess) -> Version? {
        let components = target.split(separator: "/").map(String.init)
        // Native installer: .../claude/versions/<version>[/...]
        if let i = components.lastIndex(of: "versions"), i + 1 < components.count,
           i > 0, components[i - 1] == "claude",
           let v = Version(components[i + 1]) {
            return v
        }
        // Homebrew cask: .../Caskroom/claude-code/<version>/claude
        if let i = components.lastIndex(of: "Caskroom"), i + 2 < components.count,
           components[i + 1] == "claude-code",
           let v = Version(components[i + 2]) {
            return v
        }
        // npm or bun: .../node_modules/@anthropic-ai/claude-code/<entry>
        if let i = components.lastIndex(of: "claude-code"), i > 1,
           components[i - 1] == "@anthropic-ai", components[i - 2] == "node_modules" {
            return packageVersion("/" + components[...i].joined(separator: "/"), files: files)
        }
        return nil
    }

    /// The `version` field of the npm package at `directory`.
    static func packageVersion(_ directory: String, files: FileAccess) -> Version? {
        guard let data = files.read(directory + "/package.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let string = object["version"] as? String else { return nil }
        return Version(string)
    }
}
