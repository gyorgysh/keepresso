import Testing
import Foundation
@testable import KeepressoCore

private final class FakeDownloadScanner: DownloadFolderScanning {
    var present: Bool
    private(set) var scanCount = 0
    init(present: Bool) { self.present = present }
    func hasPartialDownloads(in folder: URL) -> Bool {
        scanCount += 1
        return present
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
    let scanner = FakeDownloadScanner(present: true)
    let trigger = DownloadInFolderTrigger(folder: URL(fileURLWithPath: "/tmp/Downloads"), scanner: scanner)

    #expect(!trigger.isSatisfied()) // nothing scanned yet
    trigger.tick()
    #expect(trigger.isSatisfied())
    scanner.present = false
    trigger.tick()
    #expect(!trigger.isSatisfied())

    // isSatisfied() is a pure read: it must never scan the disk itself (the menu
    // calls it every render).
    let before = scanner.scanCount
    for _ in 0 ..< 50 { _ = trigger.isSatisfied() }
    #expect(scanner.scanCount == before)
}

@MainActor
@Test func downloadRuleLingersForItsGraceBetweenFiles() {
    // Through the factory, a download rule is grace-wrapped so a gap between
    // files in a batch (one partial renamed away before the next appears)
    // doesn't drop the session.
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let scanner = FakeDownloadScanner(present: true)
    let factory = TriggerFactory(downloads: scanner, now: { clock })
    let trigger = factory.makeTrigger(for: .downloadInFolder(URL(fileURLWithPath: "/tmp/Downloads")))

    trigger.tick()
    #expect(trigger.isSatisfied()) // a partial is present

    scanner.present = false        // the file finished; none present now
    trigger.tick()
    #expect(trigger.isSatisfied()) // still held, inside the 30s grace

    clock = clock.addingTimeInterval(DownloadInFolderTrigger.releaseGrace + 1)
    trigger.tick()
    #expect(!trigger.isSatisfied()) // grace lapsed, free to sleep
}

@Test func downloadRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.downloadInFolder(URL(fileURLWithPath: "/Users/me/Downloads"))
    #expect(rule.label == "Downloading in \u{201C}Downloads\u{201D}")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}
