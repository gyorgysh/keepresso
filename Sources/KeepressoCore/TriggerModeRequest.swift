import Darwin
import Foundation

/// A one-use request from another local process running as the same login user.
/// The URL carries only the ticket ID and cannot specify a mode by itself.
public struct TriggerModeRequest: Codable, Sendable {
    public let id: UUID
    public let pid: Int32
    public let paused: Bool
    public let validUntil: Date

    public static func take(
        _ id: UUID,
        expectedPID: Int32,
        now: Date,
        directory: URL = StatusFile.defaultURL().deletingLastPathComponent()
    ) -> Self? {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return nil }
        defer { close(parent) }

        let user = geteuid()
        var folderInfo = stat()
        guard fstat(parent, &folderInfo) == 0, folderInfo.st_uid == user,
              folderInfo.st_mode & 0o022 == 0 else { return nil }

        let name = ".trigger-mode-\(id.uuidString).json"
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }

        let sizeLimit = 1_024
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == user, opened.st_mode & 0o022 == 0, opened.st_nlink == 1,
              opened.st_size > 0, opened.st_size <= sizeLimit,
              let data = try? file.read(upToCount: sizeLimit + 1),
              data.count <= sizeLimit else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let request = try? decoder.decode(Self.self, from: data),
              request.id == id, request.pid == expectedPID,
              request.validUntil > now, request.validUntil.timeIntervalSince(now) <= 5 else { return nil }

        var listed = stat()
        guard fstatat(parent, name, &listed, AT_SYMLINK_NOFOLLOW) == 0,
              listed.st_dev == opened.st_dev, listed.st_ino == opened.st_ino,
              unlinkat(parent, name, 0) == 0 else { return nil }
        return request
    }
}
