import AppKit
import Observation
import Sparkle

/// App-side seam over the auto-updater so the menu depends on a protocol rather
/// than on Sparkle directly. The app target owns Sparkle's UI and bridges its
/// update-session callbacks into observable reminder state.
@MainActor
protocol Updating {
    /// Whether Sparkle can handle a manual check or focus an existing update
    /// session. Used to keep update actions enabled only when available.
    var canCheckForUpdates: Bool { get }

    /// A scheduled update is waiting for the user's attention.
    var updateAvailable: Bool { get }

    /// Begin a user-initiated update check, showing Sparkle's standard UI.
    func checkForUpdates()
}

extension Updating {
    var updateAvailable: Bool { false }
}

/// The real updater, backed by Sparkle's standard controller.
///
/// Configuration is read from Info.plist: `SUFeedURL` points at the `appcast.xml`
/// published on the GitHub Releases page, and `SUPublicEDKey` is the EdDSA public
/// key Sparkle uses to verify each update's signature. The matching private key
/// stays in the maintainer's Keychain and signs releases at packaging time, so a
/// tampered download is rejected before it can install.
@MainActor
@Observable
final class SparkleUpdater: NSObject, Updating, @preconcurrency SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var availabilityObservation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false
    private(set) var updateAvailable = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        // Sparkle delivers its updater state on the main thread. Bridge KVO
        // into Observation so Preferences also updates without a timer.
        availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    // Keep Sparkle's standard presentation, including urgent updates. Add a
    // visible reminder for scheduled alerts that might be behind other apps.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        updateAvailable = !state.userInitiated
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateAvailable = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateAvailable = false
    }
}
