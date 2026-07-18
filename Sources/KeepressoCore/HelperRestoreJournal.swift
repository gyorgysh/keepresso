import Foundation
import Darwin

/// Recovery work the privileged helper must settle before it can exit or
/// start another durable system transaction.
public enum HelperRestoreMarker: String, CaseIterable, Sendable {
    case sleepDisabled = "sleep-disabled"
    case awdlDown = "awdl-down"
    case fanForced = "fan-forced"
    case wakeClearPending = "wake-clear-pending"
}

/// Which half of a durable wake-schedule transaction must be retried.
public enum HelperWakeTransactionPhase: String, Codable, Equatable, Sendable {
    /// The desired schedule has not yet been completely applied.
    case pendingApply
    /// The system mutation landed; only durable journal cleanup remains.
    case applied
}

/// The complete wake schedule wanted by one in-flight helper transaction.
public struct HelperWakeTransaction: Codable, Equatable, Sendable {
    public var oneShot: String?
    public var repeatDays: String?
    public var repeatTime: String?
    public var phase: HelperWakeTransactionPhase

    public init(
        oneShot: String?,
        repeatDays: String?,
        repeatTime: String?,
        phase: HelperWakeTransactionPhase
    ) {
        self.oneShot = oneShot
        self.repeatDays = repeatDays
        self.repeatTime = repeatTime
        self.phase = phase
    }
}

/// One versioned, atomic recovery image for every privileged helper domain.
/// An empty image is still persisted so removed legacy marker files can never
/// be imported again after a crash.
public struct HelperRestoreSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumWakeFieldBytes = 4 * 1024

    public var schemaVersion: Int
    public var sleepOriginalDisablesleep: Bool?
    public var sleepRestorePending: Bool
    public var awdlRestorePending: Bool
    public var fanRestorePending: Bool
    public var wakeTransaction: HelperWakeTransaction?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sleepOriginalDisablesleep: Bool? = nil,
        sleepRestorePending: Bool = false,
        awdlRestorePending: Bool = false,
        fanRestorePending: Bool = false,
        wakeTransaction: HelperWakeTransaction? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sleepOriginalDisablesleep = sleepOriginalDisablesleep
        self.sleepRestorePending = sleepRestorePending
        self.awdlRestorePending = awdlRestorePending
        self.fanRestorePending = fanRestorePending
        self.wakeTransaction = wakeTransaction
    }

    public var hasRecoveryDebt: Bool {
        sleepRestorePending || awdlRestorePending || fanRestorePending || wakeTransaction != nil
    }

    /// Reject logically incomplete recovery images before they reach the
    /// engine. In particular, a sleep debt without its original setting can
    /// never be restored safely.
    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              sleepRestorePending == (sleepOriginalDisablesleep != nil)
        else { return false }
        guard let wakeTransaction else { return true }
        let hasRepeatDays = wakeTransaction.repeatDays != nil
        let hasRepeatTime = wakeTransaction.repeatTime != nil
        guard hasRepeatDays == hasRepeatTime else { return false }
        return [
            wakeTransaction.oneShot,
            wakeTransaction.repeatDays,
            wakeTransaction.repeatTime
        ].compactMap { $0 }.allSatisfy {
            !$0.contains("\0") && $0.lengthOfBytes(using: .utf8) <= Self.maximumWakeFieldBytes
        }
    }
}

/// Transactional persistence seam for the helper recovery journal. `nil` from
/// `snapshot()` means the durable state is unavailable or corrupt. Callers
/// must fail closed in that state.
public protocol HelperRestoreStatePersisting: AnyObject, Sendable {
    func snapshot() -> HelperRestoreSnapshot?

    /// Atomically replace the complete durable image. The mutation is applied
    /// to a copy and becomes visible only after the new journal is committed.
    @discardableResult
    func update(_ mutation: (inout HelperRestoreSnapshot) -> Void) -> Bool
}

/// Compatibility surface for older engine code and test fakes. Every marker
/// now maps into the single snapshot rather than a separate file.
public extension HelperRestoreStatePersisting {
    func markers() -> Set<HelperRestoreMarker> {
        guard let value = snapshot() else {
            return Set(HelperRestoreMarker.allCases)
        }
        var result: Set<HelperRestoreMarker> = []
        if value.sleepRestorePending { result.insert(.sleepDisabled) }
        if value.awdlRestorePending { result.insert(.awdlDown) }
        if value.fanRestorePending { result.insert(.fanForced) }
        if value.wakeTransaction != nil { result.insert(.wakeClearPending) }
        return result
    }

    @discardableResult
    func set(_ marker: HelperRestoreMarker, present: Bool) -> Bool {
        update { value in
            switch marker {
            case .sleepDisabled:
                value.sleepRestorePending = present
                if !present { value.sleepOriginalDisablesleep = nil }
            case .awdlDown:
                value.awdlRestorePending = present
            case .fanForced:
                value.fanRestorePending = present
            case .wakeClearPending:
                value.wakeTransaction = present
                    ? (value.wakeTransaction ?? HelperWakeTransaction(
                        oneShot: nil,
                        repeatDays: nil,
                        repeatTime: nil,
                        phase: .pendingApply
                    ))
                    : nil
            }
        }
    }
}

/// Source-compatible sleep snapshot helpers backed by the atomic journal.
public protocol HelperSleepRestoreValuePersisting: HelperRestoreStatePersisting {}

public extension HelperSleepRestoreValuePersisting {
    func sleepRestoreValue() -> Bool? {
        snapshot()?.sleepOriginalDisablesleep
    }

    @discardableResult
    func setSleepRestoreValue(_ value: Bool?) -> Bool {
        update { snapshot in
            snapshot.sleepOriginalDisablesleep = value
            snapshot.sleepRestorePending = value != nil
        }
    }
}

/// Root-owned single-file restore journal. All writes use a same-directory,
/// exclusively created temporary file followed by file and directory fsync.
public final class FileRestoreState: HelperSleepRestoreValuePersisting, @unchecked Sendable {
    public static let maximumJournalBytes = 64 * 1024

    private let directory: URL
    private let temporaryName: @Sendable () -> String
    private let lock = NSLock()

    public convenience init(
        directory: URL = URL(fileURLWithPath: "/var/db/sh.gyorgy.keepresso.helper")
    ) {
        self.init(
            directory: directory,
            temporaryName: { ".restore-journal.\(UUID().uuidString).tmp" }
        )
    }

    init(directory: URL, temporaryName: @escaping @Sendable () -> String) {
        self.directory = directory
        self.temporaryName = temporaryName
    }

    public func snapshot() -> HelperRestoreSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return loadOrMigrateLocked()
    }

    @discardableResult
    public func update(_ mutation: (inout HelperRestoreSnapshot) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var value = loadOrMigrateLocked() else { return false }
        mutation(&value)
        value.schemaVersion = HelperRestoreSnapshot.currentSchemaVersion
        return persistLocked(value)
    }

    private enum JournalRead {
        case absent
        case valid(HelperRestoreSnapshot)
        case invalid
    }

    private func loadOrMigrateLocked() -> HelperRestoreSnapshot? {
        guard directoryIsSafeOrAbsentLocked() else { return nil }
        switch readJournalLocked() {
        case .valid(let value):
            return value
        case .invalid:
            return nil
        case .absent:
            guard let migrated = legacySnapshotLocked(), migrated.isValid else { return nil }
            guard persistLocked(migrated) else { return nil }
            removeLegacyFilesLocked()
            return migrated
        }
    }

    private func readJournalLocked() -> JournalRead {
        var pathInfo = stat()
        if lstat(journalURL.path, &pathInfo) != 0 {
            return errno == ENOENT ? .absent : .invalid
        }
        guard (pathInfo.st_mode & S_IFMT) == S_IFREG else { return .invalid }

        let descriptor = open(journalURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .invalid }
        defer { _ = close(descriptor) }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == geteuid(),
              (fileInfo.st_mode & mode_t(0o077)) == 0,
              fileInfo.st_size > 0,
              fileInfo.st_size <= off_t(Self.maximumJournalBytes)
        else { return .invalid }

        var bytes = [UInt8](repeating: 0, count: Int(fileInfo.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let amount = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: offset), remaining)
            }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { return .invalid }
            offset += amount
        }

        guard let value = try? JSONDecoder().decode(
            HelperRestoreSnapshot.self,
            from: Data(bytes)
        ), value.isValid
        else { return .invalid }
        return .valid(value)
    }

    private func persistLocked(_ value: HelperRestoreSnapshot) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard value.isValid,
              let data = try? encoder.encode(value),
              !data.isEmpty,
              data.count <= Self.maximumJournalBytes,
              prepareDirectoryLocked()
        else { return false }

        let component = temporaryName()
        guard !component.isEmpty,
              component.count <= 255,
              !component.contains("/")
        else { return false }
        let temporaryURL = directory.appendingPathComponent(component, isDirectory: false)
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return false }

        var keepTemporary = true
        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = close(descriptor) }
            if keepTemporary { _ = unlink(temporaryURL.path) }
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              writeAll(data, to: descriptor),
              fsync(descriptor) == 0
        else { return false }
        let closeResult = close(descriptor)
        descriptorOpen = false
        guard closeResult == 0 else { return false }

        guard rename(temporaryURL.path, journalURL.path) == 0 else { return false }
        keepTemporary = false
        return syncDirectoryLocked()
    }

    private func prepareDirectoryLocked() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid()
        else { return false }
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        return fchmod(descriptor, mode_t(S_IRWXU)) == 0
    }

    private func syncDirectoryLocked() -> Bool {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        return fsync(descriptor) == 0
    }

    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { return false }
                offset += amount
            }
            return true
        }
    }

    private func legacySnapshotLocked() -> HelperRestoreSnapshot? {
        var markers: Set<HelperRestoreMarker> = []
        for marker in HelperRestoreMarker.allCases {
            switch readLegacyFileLocked(marker.rawValue, maximumBytes: 0) {
            case .absent:
                break
            case .valid:
                markers.insert(marker)
            case .invalid:
                return nil
            }
        }

        let legacySleepValue: Bool?
        switch readLegacySleepValueLocked() {
        case .absent:
            // Helpers before the exact-baseline journal restored the
            // historical default 0. Preserve that behavior exactly once
            // during migration, then record it explicitly in the journal.
            legacySleepValue = markers.contains(.sleepDisabled) ? false : nil
        case .value(let value):
            legacySleepValue = markers.contains(.sleepDisabled) ? value : nil
        case .invalid:
            return nil
        }
        var value = HelperRestoreSnapshot(
            sleepOriginalDisablesleep: legacySleepValue,
            sleepRestorePending: markers.contains(.sleepDisabled),
            awdlRestorePending: markers.contains(.awdlDown),
            fanRestorePending: markers.contains(.fanForced)
        )
        if markers.contains(.wakeClearPending) {
            value.wakeTransaction = HelperWakeTransaction(
                oneShot: nil,
                repeatDays: nil,
                repeatTime: nil,
                phase: .pendingApply
            )
        }
        return value
    }

    private enum LegacySleepValue {
        case absent
        case value(Bool)
        case invalid
    }

    private func readLegacySleepValueLocked() -> LegacySleepValue {
        let read = readLegacyFileLocked("sleep-restore-value", maximumBytes: 16)
        guard case .valid(let data) = read else {
            if case .absent = read { return .absent }
            return .invalid
        }
        guard let text = String(data: data, encoding: .utf8) else { return .invalid }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return .value(true)
        case "0": return .value(false)
        default: return .invalid
        }
    }

    private enum LegacyRead {
        case absent
        case valid(Data)
        case invalid
    }

    private func readLegacyFileLocked(_ name: String, maximumBytes: Int) -> LegacyRead {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            return errno == ENOENT ? .absent : .invalid
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= off_t(maximumBytes)
        else { return .invalid }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .invalid }
        defer { _ = close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let amount = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: offset), remaining)
            }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { return .invalid }
            offset += amount
        }
        return .valid(Data(bytes))
    }

    private func removeLegacyFilesLocked() {
        for name in HelperRestoreMarker.allCases.map(\.rawValue) + ["sleep-restore-value"] {
            _ = unlink(directory.appendingPathComponent(name, isDirectory: false).path)
        }
        _ = syncDirectoryLocked()
    }

    private var journalURL: URL {
        directory.appendingPathComponent("restore-journal.json", isDirectory: false)
    }

    private func directoryIsSafeOrAbsentLocked() -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 { return errno == ENOENT }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid()
    }
}
