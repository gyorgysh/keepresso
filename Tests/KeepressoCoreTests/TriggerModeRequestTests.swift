import Darwin
import Foundation
import Testing
@testable import KeepressoCore

@Test func triggerModeDoorbellParsesOnlyAnOpaqueTicket() throws {
    let id = UUID()
    let URLPrefix = "keepresso://apply-trigger-mode"
    let doorbell = try #require(URL(string: "\(URLPrefix)?id=\(id.uuidString)"))
    #expect(URLCommand.parse(doorbell) == .applyTriggerMode(id))

    for invalid in [
        URLPrefix,
        "\(URLPrefix)?paused=true",
        "\(URLPrefix)?id=invalid",
        "\(URLPrefix)?id=\(id.uuidString)&paused=true",
        "\(URLPrefix)?id=\(id.uuidString)&id=\(id.uuidString)",
        "\(URLPrefix)/path?id=\(id.uuidString)"
    ] {
        #expect(URLCommand.parse(try #require(URL(string: invalid))) == nil)
    }
}

private struct TriggerModeFixture {
    let directory: URL
    let id = UUID()
    let now = Date(timeIntervalSince1970: 1_000)
    let pid: Int32 = 41

    var file: URL { directory.appendingPathComponent(".trigger-mode-\(id.uuidString).json") }

    func write(id: UUID? = nil, pid: Int32? = nil, paused: Bool = true, validUntil: Date? = nil) throws {
        struct CompanionTicket: Encodable {
            let id: UUID
            let pid: Int32
            let paused: Bool
            let validUntil: Date
        }

        // Reflect the companion's exact JSON field names and atomic write.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CompanionTicket(
            id: id ?? self.id, pid: pid ?? self.pid, paused: paused, validUntil: validUntil ?? now + 5
        )).write(to: file, options: .atomic)
    }

    func take() -> TriggerModeRequest? {
        TriggerModeRequest.take(id, expectedPID: pid, now: now, directory: directory)
    }
}

private func withTriggerModeFixture(_ body: (TriggerModeFixture) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(TriggerModeFixture(directory: directory))
}

@Test func triggerModeTicketIsProcessBoundShortLivedAndConsumedOnce() throws {
    try withTriggerModeFixture { fixture in
        #expect(fixture.take() == nil)
        try fixture.write(id: UUID())
        #expect(fixture.take() == nil)
        try fixture.write(pid: 22)
        #expect(fixture.take() == nil)
        try fixture.write(validUntil: fixture.now)
        #expect(fixture.take() == nil)
        try fixture.write(validUntil: fixture.now + 6)
        #expect(fixture.take() == nil)
        try fixture.write(paused: false)
        #expect(fixture.take()?.paused == false)
        #expect(fixture.take() == nil)
    }
}

@Test func triggerModeTicketRejectsAnUntrustedFileTypeOrAccessMode() throws {
    try withTriggerModeFixture { fixture in
        try fixture.write()
        let target = fixture.directory.appendingPathComponent("unrelated.json")
        try FileManager.default.moveItem(at: fixture.file, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
        #expect(fixture.take() == nil)
        #expect(FileManager.default.fileExists(atPath: target.path))

        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.linkItem(at: target, to: fixture.file)
        #expect(fixture.take() == nil)

        try FileManager.default.removeItem(at: fixture.file)
        try Data(repeating: 65, count: 1_025).write(to: fixture.file)
        #expect(fixture.take() == nil)
        try fixture.write()
        #expect(chmod(fixture.file.path, 0o622) == 0)
        #expect(fixture.take() == nil)
        #expect(chmod(fixture.file.path, 0o600) == 0)
        #expect(chmod(fixture.directory.path, 0o722) == 0)
        #expect(fixture.take() == nil)
    }
}

@Test func triggerModeCapabilityAndAcknowledgmentAreOptionalStatusFields() throws {
    try withTriggerModeFixture { fixture in
        let url = fixture.directory.appendingPathComponent("status.json")
        StatusFile.write(.init(isActive: false, pid: fixture.pid, writtenAt: fixture.now), to: url)
        #expect(StatusFile.read(from: url)?.supportsTriggerModeControl == nil)
        #expect(StatusFile.read(from: url)?.lastTriggerModeRequestID == nil)
        StatusFile.write(.init(
            isActive: false, supportsTriggerModeControl: true, lastTriggerModeRequestID: fixture.id,
            pid: fixture.pid, writtenAt: fixture.now
        ), to: url)
        #expect(StatusFile.read(from: url)?.supportsTriggerModeControl == true)
        #expect(StatusFile.read(from: url)?.lastTriggerModeRequestID == fixture.id)
    }
}
