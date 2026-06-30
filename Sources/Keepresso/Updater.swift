import Foundation
import Sparkle

/// App-side seam over the auto-updater so the menu depends on a protocol rather
/// than on Sparkle directly (mirroring how Core abstracts the system). There is
/// no pure logic to test here: the conformance is pure delegation to Sparkle,
/// so this seam lives in the app target, not in `KeepressoCore`.
@MainActor
protocol Updating {
    /// Whether a manual check can start right now. False while a check or an
    /// install is already in flight, so the menu item can disable itself.
    var canCheckForUpdates: Bool { get }

    /// Begin a user-initiated update check, showing Sparkle's standard UI.
    func checkForUpdates()
}

/// The real updater, backed by Sparkle's standard controller.
///
/// Configuration is read from Info.plist: `SUFeedURL` points at the `appcast.xml`
/// published on the GitHub Releases page, and `SUPublicEDKey` is the EdDSA public
/// key Sparkle uses to verify each update's signature. The matching private key
/// stays in the maintainer's Keychain and signs releases at packaging time, so a
/// tampered download is rejected before it can install.
@MainActor
final class SparkleUpdater: Updating {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true wires up and schedules the updater immediately.
        // The standard GitHub-Releases appcast flow needs no custom delegates.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Read live each time the menu draws (the menu re-renders every second), so
    /// no KVO bridging is needed to keep the item's enabled state current.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
