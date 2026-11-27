import Testing
import Foundation
@testable import KeepressoCore

private final class FakeDownloadScanner: DownloadFolderScanning {
    var newestWrite: Date?
    private(set) var scanCount = 0
    init(newestWrite: Date?) { self.newestWrite = newestWrite }
    func newestPartialDownloadWrite(in folder: URL) -> Date? {
        scanCount += 1
        return newestWrite
    }
}

@Test func partialDownloadExtensionsAreMatchedCaseInsensitively() {
    for name in ["Big Sur.dmg.crdownload", "movie.download", "iso.part", "x.partial", "y.opdownload", "Z.CRDOWNLOAD"] {
        #expect(FileManagerDownloadScanner.isPartialDownload(name), "expected \(name) to match")
    }
    for name in ["report.pdf", "archive.zip", "notes", "leftover.tmp", "photo.jpeg"] {
        #expect(!FileManagerDownloadScanner.isPartialDownload(name), "expected \(name) not to match")
    }
}

@MainActor
@Test func downloadTriggerReflectsTheLastScanAndReadsPurely() {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let scanner = FakeDownloadScanner(newestWrite: clock)
    let trigger = DownloadInFolderTrigger(
        folder: URL(fileURLWithPath: "/tmp/Downloads"), scanner: scanner, now: { clock })

    #expect(!trigger.isSatisfied())
    trigger.tick()
    #expect(trigger.isSatisfied())
    scanner.newestWrite = nil
    trigger.tick()
    #expect(!trigger.isSatisfied())

    let before = scanner.scanCount
    for _ in 0 ..< 50 { _ = trigger.isSatisfied() }
    #expect(scanner.scanCount == before)
}

@MainActor
@Test func downloadTriggerIgnoresAbandonedPartials() {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let scanner = FakeDownloadScanner(newestWrite: clock)
    let trigger = DownloadInFolderTrigger(
        folder: URL(fileURLWithPath: "/tmp/Downloads"), scanner: scanner, now: { clock })

    trigger.tick()
    #expect(trigger.isSatisfied())

    clock = clock.addingTimeInterval(DownloadInFolderTrigger.abandonedAfter + 1)
    trigger.tick()
    #expect(!trigger.isSatisfied())

    scanner.newestWrite = clock
    trigger.tick()
    #expect(trigger.isSatisfied())

    scanner.newestWrite = clock.addingTimeInterval(3600)
    trigger.tick()
    #expect(trigger.isSatisfied())
}

@MainActor
@Test func downloadRuleLingersForItsGraceBetweenFiles() {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let scanner = FakeDownloadScanner(newestWrite: clock)
    let factory = TriggerFactory(downloads: scanner, now: { clock })
    let trigger = factory.makeTrigger(for: .downloadInFolder(URL(fileURLWithPath: "/tmp/Downloads")))

    trigger.tick()
    #expect(trigger.isSatisfied())

    scanner.newestWrite = nil
    trigger.tick()
    #expect(trigger.isSatisfied())

    clock = clock.addingTimeInterval(DownloadInFolderTrigger.releaseGrace + 1)
    trigger.tick()
    #expect(!trigger.isSatisfied())
}

@Test func downloadRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.downloadInFolder(URL(fileURLWithPath: "/Users/me/Downloads"))
    #expect(rule.label == "Downloading in \u{201C}Downloads\u{201D}")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}
