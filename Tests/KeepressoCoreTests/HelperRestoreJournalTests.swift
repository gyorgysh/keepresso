import Foundation
import Testing
@testable import KeepressoCore

private func journalFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-helper-journal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeJournalFixture(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

@Test func emptyRestoreJournalIsDurableAndPrivate() throws {
    let directory = try journalFixture()
    defer { removeJournalFixture(directory) }
    let state = FileRestoreState(directory: directory)

    #expect(state.snapshot() == HelperRestoreSnapshot())
    let journal = directory.appendingPathComponent("restore-journal.json")
    #expect(FileManager.default.fileExists(atPath: journal.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)

    let reloaded = FileRestoreState(directory: directory)
    #expect(reloaded.snapshot() == HelperRestoreSnapshot())
}

@Test func restoreJournalCommitsACompleteSnapshotAtomically() throws {
    let directory = try journalFixture()
    defer { removeJournalFixture(directory) }
    let state = FileRestoreState(directory: directory)
    #expect(state.snapshot() != nil)

    #expect(state.update { snapshot in
        snapshot.sleepOriginalDisablesleep = true
        snapshot.sleepRestorePending = true
        snapshot.awdlRestorePending = true
        snapshot.fanRestorePending = true
        snapshot.wakeTransaction = HelperWakeTransaction(
            oneShot: "08/01/26 06:30:00",
            repeatDays: "MWF",
            repeatTime: "07:00:00",
            phase: .pendingApply
        )
    })

    let reloaded = try #require(FileRestoreState(directory: directory).snapshot())
    #expect(reloaded.sleepOriginalDisablesleep == true)
    #expect(reloaded.sleepRestorePending)
    #expect(reloaded.awdlRestorePending)
    #expect(reloaded.fanRestorePending)
    #expect(reloaded.wakeTransaction?.repeatDays == "MWF")
    #expect(reloaded.wakeTransaction?.phase == .pendingApply)
}

@Test func legacyMarkersMigrateOnceIntoTheSingleJournal() throws {
    let directory = try journalFixture()
    defer { removeJournalFixture(directory) }
    for marker in HelperRestoreMarker.allCases {
        try Data().write(to: directory.appendingPathComponent(marker.rawValue))
    }
    try Data("1".utf8).write(
        to: directory.appendingPathComponent("sleep-restore-value")
    )

    let state = FileRestoreState(directory: directory)
    let migrated = try #require(state.snapshot())
    #expect(migrated.sleepOriginalDisablesleep == true)
    #expect(migrated.sleepRestorePending)
    #expect(migrated.awdlRestorePending)
    #expect(migrated.fanRestorePending)
    #expect(migrated.wakeTransaction?.phase == .pendingApply)
    for marker in HelperRestoreMarker.allCases {
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(marker.rawValue).path
        ))
    }

    // Once the journal exists, even a leftover legacy marker is ignored and
    // cannot revive a debt after an interrupted cleanup from an old release.
    try Data().write(to: directory.appendingPathComponent(HelperRestoreMarker.awdlDown.rawValue))
    #expect(FileRestoreState(directory: directory).snapshot() == migrated)
}

@Test func legacySleepMarkerWithoutBaselineMigratesTheOldDefaultExplicitly() throws {
    let directory = try journalFixture()
    defer { removeJournalFixture(directory) }
    try Data().write(
        to: directory.appendingPathComponent(HelperRestoreMarker.sleepDisabled.rawValue)
    )

    let migrated = try #require(FileRestoreState(directory: directory).snapshot())
    #expect(migrated.sleepRestorePending)
    #expect(migrated.sleepOriginalDisablesleep == false)
    #expect(migrated.isValid)
}

@Test func corruptJournalFailsClosedAndNeverReimportsLegacyFiles() throws {
    let directory = try journalFixture()
    defer { removeJournalFixture(directory) }
    let journal = directory.appendingPathComponent("restore-journal.json")
    try Data("not-json".utf8).write(to: journal)
    try Data().write(
        to: directory.appendingPathComponent(HelperRestoreMarker.awdlDown.rawValue)
    )

    let state = FileRestoreState(directory: directory)
    #expect(state.snapshot() == nil)
    #expect(!state.update { $0.awdlRestorePending = true })
    #expect(try Data(contentsOf: journal) == Data("not-json".utf8))
}

@Test func oversizedAndLogicallyInvalidJournalsFailClosed() throws {
    for data in [
        Data(repeating: 0x20, count: FileRestoreState.maximumJournalBytes + 1),
        try JSONEncoder().encode(HelperRestoreSnapshot(
            sleepOriginalDisablesleep: nil,
            sleepRestorePending: true
        )),
        try JSONEncoder().encode(HelperRestoreSnapshot(
            wakeTransaction: HelperWakeTransaction(
                oneShot: nil,
                repeatDays: "MWF",
                repeatTime: nil,
                phase: .pendingApply
            )
        ))
    ] {
        let directory = try journalFixture()
        defer { removeJournalFixture(directory) }
        try data.write(to: directory.appendingPathComponent("restore-journal.json"))
        #expect(FileRestoreState(directory: directory).snapshot() == nil)
    }
}

@Test func failedExclusiveTemporaryCreateLeavesTheCommittedSnapshotUntouched() throws {
    let directory = try journalFixture()
    defer { removeJournalFixture(directory) }
    let initial = FileRestoreState(directory: directory)
    #expect(initial.snapshot() == HelperRestoreSnapshot())
    try Data().write(to: directory.appendingPathComponent("blocked.tmp"))

    let blocked = FileRestoreState(directory: directory, temporaryName: { "blocked.tmp" })
    #expect(!blocked.update { $0.awdlRestorePending = true })
    #expect(FileRestoreState(directory: directory).snapshot() == HelperRestoreSnapshot())
}

@Test func legacySymlinkAndJournalSymlinkBothFailClosed() throws {
    let target = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-helper-target-\(UUID().uuidString)")
    try Data().write(to: target)
    defer { try? FileManager.default.removeItem(at: target) }

    let legacyDirectory = try journalFixture()
    defer { removeJournalFixture(legacyDirectory) }
    try FileManager.default.createSymbolicLink(
        at: legacyDirectory.appendingPathComponent(HelperRestoreMarker.fanForced.rawValue),
        withDestinationURL: target
    )
    #expect(FileRestoreState(directory: legacyDirectory).snapshot() == nil)

    let journalDirectory = try journalFixture()
    defer { removeJournalFixture(journalDirectory) }
    try FileManager.default.createSymbolicLink(
        at: journalDirectory.appendingPathComponent("restore-journal.json"),
        withDestinationURL: target
    )
    #expect(FileRestoreState(directory: journalDirectory).snapshot() == nil)
}
