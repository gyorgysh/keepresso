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

    func start(_ config: VirtualDisplayConfig) -> Bool {
        stop()
        let id = display.start(
            withWidth: UInt32(min(max(0, config.width), Int(UInt32.max))),
            height: UInt32(min(max(0, config.height), Int(UInt32.max))),
            hiDPI: config.hiDPI,
            name: "Keepresso Virtual Display"
        )
        displayID = id == 0 ? nil : id
        return displayID != nil
    }

    func stop() {
        display.stop()
        displayID = nil
    }
}
