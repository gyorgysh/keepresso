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

        guard ensureExtended(displayID) else { return false }
        if makeMain(displayID),
           CGDisplayIsMain(displayID) != 0,
           CGDisplayIsInMirrorSet(displayID) == 0 {
            originalMainDisplayID = previousMain
            return true
        }
        // Promotion is best-effort. Its transaction is atomic, so failure leaves
        // the already-confirmed unmirrored extended arrangement in place.
        return false
    }

    func stop() {
        if let originalMainDisplayID,
           CGDisplayIsOnline(originalMainDisplayID) != 0 {
            _ = makeMain(originalMainDisplayID)
        }
        originalMainDisplayID = nil
        display.stop()
        displayID = nil
    }

    /// Shift the whole online desktop so `displayID` lands at (0, 0), which is
    /// how CoreGraphics defines the main display. Relative placement is kept.
    private func makeMain(_ displayID: CGDirectDisplayID) -> Bool {
        guard let displays = onlineDisplays(), displays.contains(displayID) else {
            return false
        }
        let targetOrigin = CGDisplayBounds(displayID).origin
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            NSLog("Keepresso: begin main-display configuration failed: %d", begin.rawValue)
            return false
        }

        for display in displays {
            let origin = CGDisplayBounds(display).origin
            let result = CGConfigureDisplayOrigin(
                configuration,
                display,
                Int32(clamping: Int((origin.x - targetOrigin.x).rounded())),
                Int32(clamping: Int((origin.y - targetOrigin.y).rounded()))
            )
            guard result == .success else {
                NSLog(
                    "Keepresso: configure display %u origin failed: %d",
                    display,
                    result.rawValue
                )
                CGCancelDisplayConfiguration(configuration)
                return false
            }
        }
        let complete = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
        if complete != .success {
            NSLog("Keepresso: complete main-display configuration failed: %d", complete.rawValue)
            return false
        }
        return CGDisplayIsMain(displayID) != 0
    }

    /// A virtual display starts extended. If macOS ever supplies it in a mirror
    /// set, explicitly break that set before attempting any main-display move.
    private func ensureExtended(_ displayID: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsInMirrorSet(displayID) != 0 else { return true }
        guard let displays = onlineDisplays() else { return false }

        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            NSLog("Keepresso: begin unmirror configuration failed: %d", begin.rawValue)
            return false
        }
        for display in displays where CGDisplayIsInMirrorSet(display) != 0 {
            let result = CGConfigureDisplayMirrorOfDisplay(
                configuration, display, kCGNullDirectDisplay
            )
            guard result == .success else {
                NSLog("Keepresso: unmirror display %u failed: %d", display, result.rawValue)
                CGCancelDisplayConfiguration(configuration)
                return false
            }
        }
        let complete = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
        if complete != .success {
            NSLog("Keepresso: complete unmirror configuration failed: %d", complete.rawValue)
            return false
        }
        return CGDisplayIsInMirrorSet(displayID) == 0
    }

    private func onlineDisplays() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return nil
        }
        return Array(displays.prefix(Int(count)))
    }
}
