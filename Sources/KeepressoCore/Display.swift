import Foundation
import CoreGraphics

/// A point-in-time reading of attached displays.
public struct DisplaySnapshot: Equatable, Sendable {
    /// Active displays that are *not* the built-in panel.
    public var externalDisplayCount: Int
    /// All active displays, built-in included.
    public var totalDisplayCount: Int

    public init(externalDisplayCount: Int, totalDisplayCount: Int) {
        self.externalDisplayCount = externalDisplayCount
        self.totalDisplayCount = totalDisplayCount
    }

    /// Whether at least one external display is connected.
    public var hasExternalDisplay: Bool { externalDisplayCount > 0 }
}

/// Abstraction over the active-display list so display triggers can be tested
/// without real hardware. Mirrors the ``PowerSourceMonitoring`` seam.
public protocol DisplayMonitoring: AnyObject {
    var current: DisplaySnapshot { get }
}

/// Real backend over CoreGraphics' active-display list.
///
/// Uses `CGDisplayIsBuiltin` to tell the laptop panel apart from external
/// monitors, no AppKit needed, keeping `KeepressoCore` UI-free.
public final class CoreGraphicsDisplayMonitor: DisplayMonitoring {
    public init() {}

    public var current: DisplaySnapshot {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return DisplaySnapshot(externalDisplayCount: 0, totalDisplayCount: 0)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return DisplaySnapshot(externalDisplayCount: 0, totalDisplayCount: 0)
        }
        ids = Array(ids.prefix(Int(count)))
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }.count
        return DisplaySnapshot(externalDisplayCount: external, totalDisplayCount: ids.count)
    }
}
