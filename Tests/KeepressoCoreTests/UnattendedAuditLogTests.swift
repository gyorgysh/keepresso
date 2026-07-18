import Dispatch
import Foundation
import Testing
@testable import KeepressoCore

private func auditLeaseEvent(
    date: Date = Date(timeIntervalSince1970: 1_800_000_000),
    kind: AgentLeaseEventKind = .acquired
) -> AgentLeaseLifecycleEvent {
    let lease = AgentWakeLease(
        id: UUID(uuidString: "A1A1A1A1-A1A1-4A1A-8A1A-A1A1A1A1A1A1")!,
        metadata: AgentLeaseMetadata(
            owner: "codex-task-1",
            agent: "codex",
            task: "task-1",
            attributes: ["thread": "thread-1"]
        ),
        acquiredAt: date,
        heartbeatAt: date,
        expiresAt: date.addingTimeInterval(300),
        ttl: 300,
        maxLifetime: 3_600
    )
    return AgentLeaseLifecycleEvent(
        date: date,
        kind: kind,
        lease: lease
    )
}

private func auditDiagnosticEvent(
    index: Int = 1,
    date: Date = Date(timeIntervalSince1970: 1_800_000_001)
) -> UnattendedDiagnosticEvent {
    UnattendedDiagnosticEvent(
        id: UUID(),
        date: date,
        kind: .readinessRetryScheduled,
        automationID: "automation-\(index)",
        taskID: "task-\(index)",
        attempt: index,
        readinessIssues: [.networkUnavailable]
    )
}

private func temporaryAuditLocation() throws -> (directory: URL, file: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "keepresso-unattended-audit-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("unattended-log.jsonl"))
}

@Test func unattendedAuditEnvelopeRoundTripsBothPayloadTypes() throws {
    let leaseRecord = UnattendedAuditRecord(
        id: UUID(uuidString: "B2B2B2B2-B2B2-4B2B-8B2B-B2B2B2B2B2B2")!,
        leaseLifecycle: auditLeaseEvent()
    )
    let diagnosticRecord = UnattendedAuditRecord(
        id: UUID(uuidString: "C3C3C3C3-C3C3-4C3C-8C3C-C3C3C3C3C3C3")!,
        unattendedDiagnostic: auditDiagnosticEvent()
    )

    let leaseLine = try UnattendedAuditLogCodec.encodeLine(leaseRecord)
    let diagnosticLine = try UnattendedAuditLogCodec.encodeLine(diagnosticRecord)
    #expect(leaseLine.last == 0x0A)
    #expect(diagnosticLine.last == 0x0A)
    #expect(UnattendedAuditLogCodec.decode(leaseLine) == [leaseRecord])
    #expect(UnattendedAuditLogCodec.decode(diagnosticLine) == [diagnosticRecord])

    let object = try #require(
        JSONSerialization.jsonObject(with: leaseLine) as? [String: Any]
    )
    #expect(object["schemaVersion"] as? Int == UnattendedAuditRecord.currentSchemaVersion)
    #expect(object["type"] as? String == "agentLeaseLifecycle")
    #expect(object["leaseLifecycle"] != nil)
    #expect(object["unattendedDiagnostic"] == nil)
    #expect(object["prompt"] == nil)
    #expect(object["arguments"] == nil)
}

@Test func unattendedAuditDecoderSkipsOnlyTheCorruptLine() throws {
    let first = UnattendedAuditRecord(leaseLifecycle: auditLeaseEvent())
    let second = UnattendedAuditRecord(unattendedDiagnostic: auditDiagnosticEvent())
    var data = try UnattendedAuditLogCodec.encodeLine(first)
    data.append(Data([0xFF, 0xFE, 0x00, 0x0A]))
    data.append(try UnattendedAuditLogCodec.encodeLine(second))

    #expect(UnattendedAuditLogCodec.decode(data) == [first, second])
}

@Test func unattendedAuditAppendSeparatesAnExistingPartialLine() throws {
    let location = try temporaryAuditLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try Data("partial json".utf8).write(to: location.file)

    let log = UnattendedAuditLog(fileURL: location.file)
    log.record(auditDiagnosticEvent())

    let records = log.loadRecent()
    #expect(records.count == 1)
    #expect(records.first?.unattendedDiagnostic?.automationID == "automation-1")
}

@Test func unattendedAuditRotationKeepsNewestValidSuffixWithinLimit() throws {
    var data = Data()
    var records: [UnattendedAuditRecord] = []
    for index in 0 ..< 30 {
        let record = UnattendedAuditRecord(
            unattendedDiagnostic: auditDiagnosticEvent(
                index: index,
                date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            )
        )
        records.append(record)
        data.append(try UnattendedAuditLogCodec.encodeLine(record))
    }

    let rotated = UnattendedAuditLogCodec.rotate(data, maximumBytes: 2_000)
    let decoded = UnattendedAuditLogCodec.decode(rotated)
    #expect(rotated.count <= 2_000)
    #expect(!decoded.isEmpty)
    #expect(decoded.last == records.last)
    #expect(decoded.count < records.count)
}

@Test func unattendedAuditLogRecordsBothEventFamiliesAndLoadsRecent() throws {
    let location = try temporaryAuditLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let log = UnattendedAuditLog(fileURL: location.file)

    log.recordLeaseEvent(auditLeaseEvent())
    log.record(auditDiagnosticEvent(index: 1))
    log.record(auditDiagnosticEvent(index: 2))

    let recent = log.loadRecent(limit: 2)
    #expect(recent.count == 2)
    #expect(recent.allSatisfy { $0.type == .unattendedDiagnostic })
    #expect(recent.compactMap(\.unattendedDiagnostic?.automationID) == [
        "automation-1",
        "automation-2",
    ])
}

@Test func unattendedAuditLogUsesPrivateFileAndStableDefaultPath() throws {
    #expect(UnattendedAuditLog.defaultURL().path.hasSuffix(
        "/Library/Application Support/Keepresso/unattended-log.jsonl"
    ))

    let location = try temporaryAuditLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let log = UnattendedAuditLog(fileURL: location.file)
    log.record(auditDiagnosticEvent())

    let attributes = try FileManager.default.attributesOfItem(atPath: location.file.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == 0o600)
}

@Test func unattendedAuditLogSerializesConcurrentAppends() throws {
    let location = try temporaryAuditLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let log = UnattendedAuditLog(fileURL: location.file, maximumBytes: 2 * 1024 * 1024)
    let count = 200

    DispatchQueue.concurrentPerform(iterations: count) { index in
        log.record(auditDiagnosticEvent(
            index: index,
            date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
        ))
    }

    let records = log.loadRecent(limit: count + 1)
    let identifiers = Set(records.compactMap(\.unattendedDiagnostic?.automationID))
    #expect(records.count == count)
    #expect(identifiers.count == count)
}

@Test func unattendedAuditLogRotatesDuringAppend() throws {
    let location = try temporaryAuditLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let maximumBytes = 2_000
    let log = UnattendedAuditLog(fileURL: location.file, maximumBytes: maximumBytes)

    for index in 0 ..< 50 {
        log.record(auditDiagnosticEvent(index: index))
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: location.file.path)
    let size = try #require(attributes[.size] as? NSNumber)
    #expect(size.intValue <= maximumBytes)
    #expect(log.loadRecent(limit: 100).last?.unattendedDiagnostic?.automationID == "automation-49")
}
