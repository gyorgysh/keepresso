import Testing
import Foundation
@testable import KeepressoCore

private let appID = "sh.gyorgy.keepresso"
private let installed = URL(fileURLWithPath: "/Applications/Keepresso.app")
private let trashed = URL(fileURLWithPath: "/Users/g/.Trash/Keepresso 16.43.20.app")

/// A sweep harness with a recorded removal, standing in for FileManager.
private final class FakeRemover {
    var removedPaths: [String] = []
    var failure: Error?

    func remove(_ url: URL) throws {
        if let failure { throw failure }
        removedPaths.append(url.path)
    }
}

private func sweep(
    bookmark: Data?,
    resolvesTo resolved: URL?,
    current: URL = installed,
    idAtResolved: String? = appID,
    remover: FakeRemover = FakeRemover()
) -> StaleBundleSweepResult {
    StaleBundleSweep.sweep(
        previousBookmark: bookmark,
        currentBundleURL: current,
        expectedBundleIdentifier: appID,
        resolveBookmark: { _ in resolved },
        bundleIdentifier: { _ in idAtResolved },
        removeItem: remover.remove
    )
}

@Test func sweepDeletesTheTrashedPreviousCopy() {
    let remover = FakeRemover()
    let result = sweep(bookmark: Data([1]), resolvesTo: trashed, remover: remover)
    #expect(result == .removed(path: trashed.path))
    #expect(remover.removedPaths == [trashed.path])
}

@Test func sweepAlsoCoversVolumeTrashes() {
    let volumeTrashed = URL(fileURLWithPath: "/Volumes/Data/.Trashes/501/Keepresso.app")
    #expect(sweep(bookmark: Data([1]), resolvesTo: volumeTrashed)
        == .removed(path: volumeTrashed.path))
}

@Test func sweepDoesNothingWithoutABookmark() {
    let remover = FakeRemover()
    #expect(sweep(bookmark: nil, resolvesTo: trashed, remover: remover) == .nothingToSweep)
    #expect(remover.removedPaths.isEmpty)
}

@Test func sweepDoesNothingWhenTheBookmarkNoLongerResolves() {
    #expect(sweep(bookmark: Data([1]), resolvesTo: nil) == .nothingToSweep)
}

@Test func sweepLeavesTheRunningBundleAlone() {
    // No update happened: the bookmark still points at the running copy.
    let remover = FakeRemover()
    #expect(sweep(bookmark: Data([1]), resolvesTo: installed, remover: remover) == .nothingToSweep)
    #expect(remover.removedPaths.isEmpty)

    // Even if the app somehow runs from the Trash, it must not delete itself.
    #expect(sweep(bookmark: Data([1]), resolvesTo: trashed, current: trashed) == .nothingToSweep)
}

@Test func sweepNeverDeletesOutsideATrashFolder() {
    // A copy the user parked somewhere is theirs to keep.
    let parked = URL(fileURLWithPath: "/Users/g/Desktop/Keepresso old.app")
    let remover = FakeRemover()
    let result = sweep(bookmark: Data([1]), resolvesTo: parked, remover: remover)
    #expect(result == .leftAlone(path: parked.path, reason: "not in a Trash folder"))
    #expect(remover.removedPaths.isEmpty)
}

@Test func sweepChecksTheBundleIdentifierBeforeDeleting() {
    // The bookmark resolving to something else entirely (reused inode,
    // renamed bundle) must not cost the user that file.
    let remover = FakeRemover()
    let wrongID = sweep(bookmark: Data([1]), resolvesTo: trashed,
                        idAtResolved: "com.example.other", remover: remover)
    #expect(wrongID == .leftAlone(path: trashed.path, reason: "bundle identifier differs"))

    let unreadable = sweep(bookmark: Data([1]), resolvesTo: trashed,
                           idAtResolved: nil, remover: remover)
    #expect(unreadable == .leftAlone(path: trashed.path, reason: "bundle identifier differs"))
    #expect(remover.removedPaths.isEmpty)
}

@Test func sweepReportsAFailedRemoval() {
    let remover = FakeRemover()
    remover.failure = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                              userInfo: [NSLocalizedDescriptionKey: "no permission"])
    let result = sweep(bookmark: Data([1]), resolvesTo: trashed, remover: remover)
    #expect(result == .removalFailed(path: trashed.path, message: "no permission"))
}

@Test func trashDetectionIsAnchoredToPathComponents() {
    #expect(StaleBundleSweep.isInTrash(URL(fileURLWithPath: "/Users/g/.Trash/App.app")))
    #expect(StaleBundleSweep.isInTrash(URL(fileURLWithPath: "/Volumes/X/.Trashes/501/App.app")))
    // A name merely containing ".Trash" is not a Trash folder.
    #expect(!StaleBundleSweep.isInTrash(URL(fileURLWithPath: "/Users/g/my.Trash.notes/App.app")))
    #expect(!StaleBundleSweep.isInTrash(URL(fileURLWithPath: "/Applications/App.app")))
}

// MARK: - The daemon's own validation for the removeTrashedBundle verb

@Test func daemonRemovesOnlyATrashedCopyOfTheApp() {
    #expect(StaleBundleSweep.daemonMayRemove(
        "/Users/g/.Trash/Keepresso.app",
        appBundleURL: installed,
        expectedBundleIdentifier: "sh.gyorgy.keepresso",
        bundleIdentifier: { _ in "sh.gyorgy.keepresso" }
    ))
    // An unreadable Info.plist doesn't veto: the bundle name and the Trash
    // location still identify the copy, and an unreadable plist is how the
    // poisonous copy survives the app-side sweep in the first place.
    #expect(StaleBundleSweep.daemonMayRemove(
        "/Users/g/.Trash/Keepresso.app",
        appBundleURL: installed,
        expectedBundleIdentifier: "sh.gyorgy.keepresso",
        bundleIdentifier: { _ in nil }
    ))
}

@Test func daemonRefusesAnythingElse() {
    let ownID: (URL) -> String? = { _ in "sh.gyorgy.keepresso" }
    // Outside a Trash folder.
    #expect(!StaleBundleSweep.daemonMayRemove(
        "/Applications/Keepresso.app", appBundleURL: installed,
        expectedBundleIdentifier: "sh.gyorgy.keepresso", bundleIdentifier: ownID
    ))
    // A different bundle name, even inside the Trash.
    #expect(!StaleBundleSweep.daemonMayRemove(
        "/Users/g/.Trash/Other.app", appBundleURL: installed,
        expectedBundleIdentifier: "sh.gyorgy.keepresso", bundleIdentifier: ownID
    ))
    // The right name but a different app's identifier.
    #expect(!StaleBundleSweep.daemonMayRemove(
        "/Users/g/.Trash/Keepresso.app", appBundleURL: installed,
        expectedBundleIdentifier: "sh.gyorgy.keepresso",
        bundleIdentifier: { _ in "com.example.impostor" }
    ))
    // The installed copy itself, if it ever ended up named by the caller.
    #expect(!StaleBundleSweep.daemonMayRemove(
        installed.path, appBundleURL: installed,
        expectedBundleIdentifier: "sh.gyorgy.keepresso", bundleIdentifier: ownID
    ))
    // Path traversal dressed up as a Trash path.
    #expect(!StaleBundleSweep.daemonMayRemove(
        "/Users/g/.Trash/../../../Applications/Keepresso.app", appBundleURL: installed,
        expectedBundleIdentifier: "sh.gyorgy.keepresso", bundleIdentifier: ownID
    ))
}
