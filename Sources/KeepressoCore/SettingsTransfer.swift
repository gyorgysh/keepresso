import Foundation

/// A version-stamped, portable snapshot of a user's Keepresso configuration for
/// backing it up or moving it between Macs.
///
/// The raw ``KeepressoSettings`` blob already round-trips as JSON, but a bare
/// blob is unlabelled: nothing tells an import that a file is actually a
/// Keepresso export, from which app version, or in which format. This envelope
/// wraps the settings with a format marker and a format version so import can
/// recognise the file and refuse anything it doesn't understand, mirroring the
/// `SettingsStore` seam rather than reaching for `Date()`/IO directly.
///
/// Field additions to ``KeepressoSettings`` don't bump ``currentFormatVersion``:
/// the forgiving ``KeepressoSettings/init(from:)`` already fills missing fields
/// with their defaults, so an export from an older app still imports. The
/// version is reserved for a change to this envelope's own shape.
public struct SettingsTransfer: Codable, Equatable, Sendable {
    /// Marks the file as a Keepresso settings export. Import rejects any file
    /// whose marker doesn't match ``formatName``.
    public var format: String
    /// The envelope format version. Import rejects a file newer than
    /// ``currentFormatVersion`` (a format this build can't read).
    public var version: Int
    /// The app's marketing version at export time. Informational only, so a
    /// human reading the file can see where it came from; never validated.
    public var appVersion: String?
    /// The exported configuration.
    public var settings: KeepressoSettings

    /// The marker written into every export's ``format`` field.
    public static let formatName = "keepresso.settings"
    /// The envelope format this build writes and can read up to.
    public static let currentFormatVersion = 1

    public init(settings: KeepressoSettings, appVersion: String? = nil) {
        self.format = Self.formatName
        self.version = Self.currentFormatVersion
        self.appVersion = appVersion
        self.settings = settings
    }
}

/// Why an import file was rejected, so the app can explain it to the user.
public enum SettingsTransferError: Error, Equatable, Sendable {
    /// The data isn't a Keepresso settings export (not JSON, or missing/wrong
    /// format marker).
    case unrecognizedFile
    /// A valid Keepresso export, but in a newer format this build can't read.
    case unsupportedVersion(Int)
}

extension SettingsTransfer {
    /// Encode `settings` as a portable, human-readable export blob. Keys are
    /// sorted and pretty-printed so the file is stable and diff-friendly (useful
    /// for keeping a config in version control).
    public static func exportData(_ settings: KeepressoSettings, appVersion: String? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SettingsTransfer(settings: settings, appVersion: appVersion))
    }

    /// Validate and decode an export blob into settings.
    ///
    /// - Throws: ``SettingsTransferError/unrecognizedFile`` when the data isn't a
    ///   Keepresso export, or ``SettingsTransferError/unsupportedVersion(_:)``
    ///   when it's from a newer format this build can't read.
    public static func importSettings(from data: Data) throws -> KeepressoSettings {
        let transfer: SettingsTransfer
        do {
            transfer = try JSONDecoder().decode(SettingsTransfer.self, from: data)
        } catch {
            throw SettingsTransferError.unrecognizedFile
        }
        guard transfer.format == Self.formatName else { throw SettingsTransferError.unrecognizedFile }
        guard transfer.version <= Self.currentFormatVersion else {
            throw SettingsTransferError.unsupportedVersion(transfer.version)
        }
        return transfer.settings
    }
}

extension KeepressoSettings {
    /// Neutralize the one code-execution vector an imported settings file can
    /// carry: `.shell` event hooks run arbitrary commands through `/bin/sh -c`
    /// (see ``SystemHookRunner``), so a crafted export could otherwise run a
    /// command the moment its event fires. Disable every `.shell` hook on
    /// import rather than delete it: the user keeps their commands, sees them
    /// in Preferences ▸ Automation, and re-enables the ones they trust with one
    /// click. `.webhook` (scheme-restricted to http/https) and `.runShortcut`
    /// (a user's own named Shortcut) aren't silent code execution, so they pass
    /// through untouched, as do hooks already disabled.
    ///
    /// - Returns: a copy with imported shell hooks switched off, and how many
    ///   were switched off, so the caller can tell the user.
    public func disarmingImportedShellHooks() -> (settings: KeepressoSettings, disabledCount: Int) {
        var copy = self
        var disabled = 0
        copy.eventHooks = eventHooks.map { hook in
            guard case .shell = hook.action, hook.enabled else { return hook }
            disabled += 1
            var off = hook
            off.enabled = false
            return off
        }
        return (copy, disabled)
    }
}
