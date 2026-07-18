import Darwin
import Foundation

/// The structured payload carried by one unattended audit record.
public enum UnattendedAuditRecordType: String, Codable, Equatable, Sendable {
    case agentLeaseLifecycle
    case unattendedDiagnostic
}

/// A versioned JSONL envelope for unattended activity.
///
/// The payload types are the privacy boundary. This record deliberately has
/// no free-form message, automation prompt, executable, or command arguments.
public struct UnattendedAuditRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let recordedAt: Date
    public let type: UnattendedAuditRecordType
    public let leaseLifecycle: AgentLeaseLifecycleEvent?
    public let unattendedDiagnostic: UnattendedDiagnosticEvent?

    public init(
        id: UUID = UUID(),
        leaseLifecycle event: AgentLeaseLifecycleEvent
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.recordedAt = event.date
        self.type = .agentLeaseLifecycle
        self.leaseLifecycle = event
        self.unattendedDiagnostic = nil
    }

    public init(
        id: UUID = UUID(),
        unattendedDiagnostic event: UnattendedDiagnosticEvent
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.recordedAt = event.date
        self.type = .unattendedDiagnostic
        self.leaseLifecycle = nil
        self.unattendedDiagnostic = event
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case recordedAt
        case type
        case leaseLifecycle
        case unattendedDiagnostic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported unattended audit schema version"
            )
        }

        let id = try container.decode(UUID.self, forKey: .id)
        let recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        let type = try container.decode(UnattendedAuditRecordType.self, forKey: .type)

        switch type {
        case .agentLeaseLifecycle:
            guard !container.contains(.unattendedDiagnostic) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .unattendedDiagnostic,
                    in: container,
                    debugDescription: "Lease audit record contains a diagnostic payload"
                )
            }
            self.leaseLifecycle = try container.decode(
                AgentLeaseLifecycleEvent.self,
                forKey: .leaseLifecycle
            )
            self.unattendedDiagnostic = nil

        case .unattendedDiagnostic:
            guard !container.contains(.leaseLifecycle) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .leaseLifecycle,
                    in: container,
                    debugDescription: "Diagnostic audit record contains a lease payload"
                )
            }
            self.leaseLifecycle = nil
            self.unattendedDiagnostic = try container.decode(
                UnattendedDiagnosticEvent.self,
                forKey: .unattendedDiagnostic
            )
        }

        self.schemaVersion = schemaVersion
        self.id = id
        self.recordedAt = recordedAt
        self.type = type
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(type, forKey: .type)

        switch type {
        case .agentLeaseLifecycle:
            guard let leaseLifecycle, unattendedDiagnostic == nil else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Lease audit record has invalid payloads"
                    )
                )
            }
            try container.encode(leaseLifecycle, forKey: .leaseLifecycle)

        case .unattendedDiagnostic:
            guard let unattendedDiagnostic, leaseLifecycle == nil else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Diagnostic audit record has invalid payloads"
                    )
                )
            }
            try container.encode(unattendedDiagnostic, forKey: .unattendedDiagnostic)
        }
    }
}

/// Stable single-line JSON codec and bounded suffix rotation.
public enum UnattendedAuditLogCodec {
    public static func encodeLine(_ record: UnattendedAuditRecord) throws -> Data {
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    /// Decodes each line independently so damaged or partial lines do not hide
    /// valid records before or after them.
    public static func decode(_ data: Data) -> [UnattendedAuditRecord] {
        data.split(separator: 0x0A).compactMap { bytes in
            try? decoder.decode(UnattendedAuditRecord.self, from: Data(bytes))
        }
    }

    /// Keeps the newest complete records whose encoded lines fit the limit.
    public static func rotate(_ data: Data, maximumBytes: Int) -> Data {
        let limit = max(0, maximumBytes)
        guard data.count > limit else { return data }
        guard limit > 0 else { return Data() }

        var suffix: [Data] = []
        var suffixBytes = 0
        for record in decode(data).reversed() {
            guard let line = try? encodeLine(record), line.count <= limit else { continue }
            guard suffixBytes + line.count <= limit else { break }
            suffix.append(line)
            suffixBytes += line.count
        }

        var rotated = Data(capacity: suffixBytes)
        for line in suffix.reversed() {
            rotated.append(line)
        }
        return rotated
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

private final class UnattendedAuditProcessLockRegistry: @unchecked Sendable {
    static let shared = UnattendedAuditProcessLockRegistry()

    private let lock = NSLock()
    private var locks: [String: NSLock] = [:]

    func mutex(for path: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = locks[path] { return existing }
        let created = NSLock()
        locks[path] = created
        return created
    }
}

private enum UnattendedAuditFileError: Error {
    case cannotOpen(path: String, errorNumber: Int32)
    case cannotLock(path: String, errorNumber: Int32)
    case cannotWrite(path: String, errorNumber: Int32)
    case cannotReplace(path: String, errorNumber: Int32)
}

/// Thread-safe persistent recorder for unattended diagnostics and AI leases.
///
/// Appends are also protected by a sibling `flock`, allowing independently
/// launched Keepresso processes to share the same bounded JSONL file safely.
public final class UnattendedAuditLog: UnattendedDiagnosticRecording, @unchecked Sendable {
    public static let defaultMaximumBytes = 1 * 1024 * 1024
    public static let defaultRecentLimit = 200

    public let fileURL: URL
    public let maximumBytes: Int

    private let fileManager: FileManager
    private let lockURL: URL
    private let processMutex: NSLock

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Keepresso", isDirectory: true)
            .appendingPathComponent("unattended-log.jsonl", isDirectory: false)
    }

    public init(
        fileURL: URL? = nil,
        maximumBytes: Int = UnattendedAuditLog.defaultMaximumBytes,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultURL(fileManager: fileManager)
        self.maximumBytes = max(0, maximumBytes)
        self.lockURL = self.fileURL.appendingPathExtension("lock")
        self.processMutex = UnattendedAuditProcessLockRegistry.shared.mutex(for: lockURL.path)
    }

    public func record(_ event: UnattendedDiagnosticEvent) {
        append(UnattendedAuditRecord(unattendedDiagnostic: event))
    }

    public func recordLeaseEvent(_ event: AgentLeaseLifecycleEvent) {
        append(UnattendedAuditRecord(leaseLifecycle: event))
    }

    /// Loads the newest valid records in chronological order.
    public func loadRecent(limit: Int = UnattendedAuditLog.defaultRecentLimit) -> [UnattendedAuditRecord] {
        guard limit > 0 else { return [] }
        return (try? withExclusiveLock {
            let data = (try? Data(contentsOf: fileURL)) ?? Data()
            return Array(UnattendedAuditLogCodec.decode(data).suffix(limit))
        }) ?? []
    }

    private func append(_ record: UnattendedAuditRecord) {
        guard maximumBytes > 0,
              let line = try? UnattendedAuditLogCodec.encodeLine(record),
              line.count <= maximumBytes
        else { return }

        try? withExclusiveLock {
            let existingBytes = fileSize()
            let needsSeparator = needsLineSeparator(existingBytes: existingBytes)
            var appendPayload = Data(capacity: line.count + (needsSeparator ? 1 : 0))
            if needsSeparator { appendPayload.append(0x0A) }
            appendPayload.append(line)

            if existingBytes + appendPayload.count <= maximumBytes {
                try appendLocked(appendPayload)
                return
            }

            var combined = (try? Data(contentsOf: fileURL)) ?? Data()
            if needsSeparator { combined.append(0x0A) }
            combined.append(line)
            let rotated = UnattendedAuditLogCodec.rotate(
                combined,
                maximumBytes: maximumBytes
            )
            try replaceLocked(rotated)
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        processMutex.lock()
        defer { processMutex.unlock() }

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw UnattendedAuditFileError.cannotOpen(
                path: lockURL.path,
                errorNumber: errno
            )
        }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fchmod(descriptor, mode_t(0o600))

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw UnattendedAuditFileError.cannotLock(
                path: lockURL.path,
                errorNumber: errno
            )
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func fileSize() -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let number = attributes[.size] as? NSNumber
        else { return 0 }
        return number.intValue
    }

    private func needsLineSeparator(existingBytes: Int) -> Bool {
        guard existingBytes > 0 else { return false }
        let descriptor = Darwin.open(fileURL.path, O_RDONLY)
        guard descriptor >= 0 else { return true }
        defer { Darwin.close(descriptor) }

        var byte: UInt8 = 0
        let count = Darwin.pread(
            descriptor,
            &byte,
            1,
            off_t(existingBytes - 1)
        )
        return count != 1 || byte != 0x0A
    }

    private func appendLocked(_ data: Data) throws {
        let descriptor = Darwin.open(
            fileURL.path,
            O_CREAT | O_WRONLY | O_APPEND,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw UnattendedAuditFileError.cannotOpen(
                path: fileURL.path,
                errorNumber: errno
            )
        }
        defer { Darwin.close(descriptor) }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw UnattendedAuditFileError.cannotWrite(
                path: fileURL.path,
                errorNumber: errno
            )
        }
        try write(data, to: descriptor, path: fileURL.path)
        guard Darwin.fsync(descriptor) == 0 else {
            throw UnattendedAuditFileError.cannotWrite(
                path: fileURL.path,
                errorNumber: errno
            )
        }
    }

    private func replaceLocked(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".unattended-log-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw UnattendedAuditFileError.cannotOpen(
                path: temporaryURL.path,
                errorNumber: errno
            )
        }

        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try write(data, to: descriptor, path: temporaryURL.path)
        guard Darwin.fsync(descriptor) == 0 else {
            throw UnattendedAuditFileError.cannotWrite(
                path: temporaryURL.path,
                errorNumber: errno
            )
        }
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw UnattendedAuditFileError.cannotReplace(
                path: fileURL.path,
                errorNumber: errno
            )
        }
        shouldRemoveTemporaryFile = false
    }

    private func write(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw UnattendedAuditFileError.cannotWrite(
                        path: path,
                        errorNumber: errno
                    )
                }
                offset += written
            }
        }
    }
}
