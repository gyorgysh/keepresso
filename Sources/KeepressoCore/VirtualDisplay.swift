import Foundation
import Observation

/// A persisted virtual-display configuration: the pixel size and whether to
/// expose it as a HiDPI (Retina) display.
///
/// On a headless Mac with no monitor, macOS synthesizes a fuzzy non-Retina
/// 1920x1080 framebuffer. Creating a higher-resolution HiDPI virtual display
/// makes VNC / Screen Sharing crisp. A HiDPI display at, say, 3840x2160 presents
/// a sharp 1920x1080 logical desktop (2x).
public struct VirtualDisplayConfig: Codable, Equatable, Sendable {
    /// Native pixel width.
    public var width: Int
    /// Native pixel height.
    public var height: Int
    /// Expose as a Retina (2x) display.
    public var hiDPI: Bool

    public init(width: Int, height: Int, hiDPI: Bool = true) {
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
    }

    public var label: String {
        "\(width)\u{00D7}\(height)" + (hiDPI ? " HiDPI" : "")
    }
}

/// Seam over creating/removing a virtual display. The real backend uses a
/// **private** CoreGraphics API (`CGVirtualDisplay`), so it lives in the app
/// behind this protocol; ``KeepressoCore`` stays clean and tests use a fake.
public protocol VirtualDisplaying: AnyObject {
    /// Whether the underlying API exists on this macOS (it's private and may
    /// vanish across releases).
    var isSupported: Bool { get }
    /// Whether a virtual display is currently held.
    var isActive: Bool { get }
    /// The display id to exclude from attached-display checks.
    var displayID: UInt32? { get }
    /// Create the virtual display. Returns false if unsupported or it failed.
    func start(_ config: VirtualDisplayConfig) -> Bool
    /// Tear down the virtual display.
    func stop()
}

/// No-op backend used by default in `KeepressoCore` (which can't link the
/// private API) and in tests. Reports unsupported and does nothing.
public final class NullVirtualDisplay: VirtualDisplaying {
    public init() {}
    public var isSupported: Bool { false }
    public var isActive: Bool { false }
    public var displayID: UInt32? { nil }
    public func start(_ config: VirtualDisplayConfig) -> Bool { false }
    public func stop() {}
}

/// Drives the experimental virtual-display feature. Off by default: a `nil`
/// ``config`` means no virtual display. Setting a config applies it immediately;
/// clearing it tears the display down. Mirrors ``DiskKeepAliveController``.
@MainActor
@Observable
public final class VirtualDisplayController {
    /// The desired virtual display, or `nil` for off. Applying happens on set.
    public var config: VirtualDisplayConfig? {
        didSet { apply() }
    }

    /// Set when the last apply failed, for the UI to surface.
    public private(set) var lastError: String?

    private let backend: VirtualDisplaying

    public init(backend: VirtualDisplaying = NullVirtualDisplay()) {
        self.backend = backend
    }

    /// Whether the private API is available on this system.
    public var isSupported: Bool { backend.isSupported }

    /// Whether a virtual display is currently held.
    public var isActive: Bool { backend.isActive }

    /// The active virtual display's CoreGraphics id, when one exists.
    public var displayID: UInt32? { backend.displayID }

    private func apply() {
        guard let config else {
            backend.stop()
            lastError = nil
            return
        }
        guard backend.isSupported else {
            lastError = L("Virtual displays aren't available on this macOS version.")
            return
        }
        lastError = backend.start(config) ? nil : L("Couldn't create the virtual display.")
    }
}

/// A conservative automatic-mode verdict. Unknown and transitional states hold
/// the current state so display reconfiguration cannot make the virtual display
/// flap on and off.
public enum VirtualDisplayAutoDecision: Equatable, Sendable {
    case start
    case stop
    case hold

    public static func decide(
        power: PowerSourceSnapshot.Provider,
        topology: DisplayTopologySnapshot?
    ) -> Self {
        if power == .ac { return .stop }
        guard let topology else { return .hold }
        if topology.hasExternalOnlineDisplay { return .stop }
        guard let builtIn = topology.builtIn else { return .hold }
        if builtIn.isOnline && builtIn.isActive { return .stop }
        if power == .battery,
           builtIn.isOnline,
           builtIn.isAsleep,
           !builtIn.isActive {
            return .start
        }
        return .hold
    }
}
