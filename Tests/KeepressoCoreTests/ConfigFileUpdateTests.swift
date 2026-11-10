import Testing
import Foundation
@testable import KeepressoCore

/// A file whose successive reads return the given contents in turn (the
/// last one repeats), recording what gets written.
private final class FakeFile {
    var reads: [Data?]
    var written: [Data] = []
    init(_ reads: [String?]) { self.reads = reads.map { $0.map { Data($0.utf8) } } }
    func read() -> Data? { reads.count > 1 ? reads.removeFirst() : reads[0] }
}

private func appendX(_ data: Data?) -> Data {
    Data(((data.map { String(decoding: $0, as: UTF8.self) } ?? "") + "x").utf8)
}

@Test func writesTheTransformWhenTheFileHoldsStill() throws {
    let file = FakeFile(["a"])
    try ConfigFileUpdate.apply(read: file.read, write: { file.written.append($0) }, transform: appendX)
    #expect(file.written == [Data("ax".utf8)])
}

@Test func redoesTheTransformOnContentsChangedMidUpdate() throws {
    // Read "a", the tool saves "b" before our write: the merge is redone on
    // "b", so the tool's change survives.
    let file = FakeFile(["a", "b", "b", "b"])
    try ConfigFileUpdate.apply(read: file.read, write: { file.written.append($0) }, transform: appendX)
    #expect(file.written == [Data("bx".utf8)])
}

@Test func givesUpWithoutWritingWhenTheFileNeverSettles() {
    let file = FakeFile(["1", "2", "3", "4", "5", "6", "7"])
    #expect(throws: ConfigFileUpdate.KeptChangingError()) {
        try ConfigFileUpdate.apply(read: file.read, write: { file.written.append($0) }, transform: appendX)
    }
    #expect(file.written.isEmpty)
}

@Test func aMissingFileIsCreated() throws {
    let file = FakeFile([nil])
    try ConfigFileUpdate.apply(read: file.read, write: { file.written.append($0) }, transform: appendX)
    #expect(file.written == [Data("x".utf8)])
}

@Test func readErrorsPropagateAndNothingIsWritten() {
    var written = false
    #expect(throws: AgentHooks.SettingsUnreadableError.self) {
        try ConfigFileUpdate.apply(
            read: { throw AgentHooks.SettingsUnreadableError() },
            write: { _ in written = true },
            transform: appendX)
    }
    #expect(!written)
}

@Test func unchangedConfigIsNotRewritten() throws {
    let file = FakeFile(["settings"])
    try ConfigFileUpdate.apply(read: file.read, write: { file.written.append($0) },
                               transform: { $0 ?? Data() })
    #expect(file.written.isEmpty)
}

@Test func noOpTransformStillRetriesConcurrentChanges() throws {
    let file = FakeFile(["a", "b", "b", "b"])
    try ConfigFileUpdate.apply(read: file.read, write: { file.written.append($0) }, transform: {
        $0 == Data("a".utf8) ? Data("a".utf8) : Data("bx".utf8)
    })
    #expect(file.written == [Data("bx".utf8)])
}
