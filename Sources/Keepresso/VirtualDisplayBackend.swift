import CoreGraphics
import KeepressoCore

/// Real ``VirtualDisplaying`` backed by the private CoreGraphics API via the
/// Objective-C ``KPVirtualDisplay`` wrapper. Experimental and off by default.
@MainActor
final class CGVirtualDisplayBackend: VirtualDisplaying {
    private let display = KPVirtualDisplay()

    var isSupported: Bool { KPVirtualDisplay.isSupported() }
    var isActive: Bool { display.isActive }
    private(set) var displayID: UInt32?
    var isMain: Bool {
        guard let displayID else { return false }
        return CGDisplayIsMain(displayID) != 0
    }

    private var originalMainDisplayID: CGDirectDisplayID?

    func start(_ config: VirtualDisplayConfig) -> Bool {
        stop() // replace any existing display and restore its layout
        let id = display.start(
            withWidth: UInt32(min(max(0, config.width), Int(UInt32.max))),
            height: UInt32(min(max(0, config.height), Int(UInt32.max))),
            hiDPI: config.hiDPI,
            name: "Keepresso Virtual Display"
        )
        displayID = id == 0 ? nil : id
        return displayID != nil
    }

    func promoteToMain() -> Bool {
        guard let displayID else { return false }
        if CGDisplayIsMain(displayID) != 0 { return true }

        let previousMain = CGMainDisplayID()
        guard previousMain != kCGNullDirectDisplay,
              previousMain != displayID else { return false }

        if arrange(main: displayID, extended: previousMain),
           CGDisplayIsMain(displayID) != 0,
           CGDisplayIsInMirrorSet(displayID) == 0 {
            originalMainDisplayID = previousMain
            return true
        }

        // Promotion is best-effort. The fallback explicitly keeps the virtual
        // display extended and unmirrored, never mirrored to the sleeping panel.
        _ = arrange(main: previousMain, extended: displayID)
        return false
    }

    func stop() {
        if let displayID, let originalMainDisplayID,
           CGDisplayIsOnline(originalMainDisplayID) != 0 {
            _ = arrange(main: originalMainDisplayID, extended: displayID)
        }
        originalMainDisplayID = nil
        display.stop()
        displayID = nil
    }

    private func arrange(
        main: CGDirectDisplayID,
        extended: CGDirectDisplayID
    ) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration else { return false }

        let secondaryX = Int32(clamping: max(
            1,
            Int(CGDisplayBounds(main).width.rounded(.up))
        ))
        guard CGConfigureDisplayMirrorOfDisplay(
            configuration, main, kCGNullDirectDisplay
        ) == .success,
        CGConfigureDisplayMirrorOfDisplay(
            configuration, extended, kCGNullDirectDisplay
        ) == .success,
        CGConfigureDisplayOrigin(configuration, main, 0, 0) == .success,
        CGConfigureDisplayOrigin(configuration, extended, secondaryX, 0) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        return CGCompleteDisplayConfiguration(configuration, .forAppOnly) == .success
    }
}
