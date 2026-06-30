import KeepressoCore

/// Real ``VirtualDisplaying`` backed by the private CoreGraphics API via the
/// Objective-C ``KPVirtualDisplay`` wrapper. Experimental and off by default.
@MainActor
final class CGVirtualDisplayBackend: VirtualDisplaying {
    private let display = KPVirtualDisplay()

    var isSupported: Bool { KPVirtualDisplay.isSupported() }
    var isActive: Bool { display.isActive }

    func start(_ config: VirtualDisplayConfig) -> Bool {
        display.stop() // replace any existing display
        let id = display.start(
            withWidth: UInt32(max(0, config.width)),
            height: UInt32(max(0, config.height)),
            hiDPI: config.hiDPI,
            name: "Keepresso Virtual Display"
        )
        return id != 0
    }

    func stop() { display.stop() }
}
