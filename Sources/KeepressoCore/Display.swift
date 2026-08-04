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

/// The display state needed to decide whether a headless virtual display is
/// necessary. Online external displays include inactive displays, but exclude
/// Keepresso's own virtual display when its id is supplied.
public struct DisplayTopologySnapshot: Equatable, Sendable {
    public struct BuiltInDisplay: Equatable, Sendable {
        public var isOnline: Bool
        public var isActive: Bool
        public var isAsleep: Bool

        public init(isOnline: Bool, isActive: Bool, isAsleep: Bool) {
            self.isOnline = isOnline
            self.isActive = isActive
            self.isAsleep = isAsleep
        }
    }

    public var builtIn: BuiltInDisplay?
    public var externalOnlineDisplayCount: Int

    public init(builtIn: BuiltInDisplay?, externalOnlineDisplayCount: Int) {
        self.builtIn = builtIn
        self.externalOnlineDisplayCount = externalOnlineDisplayCount
    }

    public var hasExternalOnlineDisplay: Bool { externalOnlineDisplayCount > 0 }
}

public protocol DisplayTopologyMonitoring: AnyObject {
    func current(excluding displayID: UInt32?) -> DisplayTopologySnapshot?
}

/// Real backend over CoreGraphics' online-display list. Unlike
/// ``CoreGraphicsDisplayMonitor``, this includes sleeping displays because an
/// attached but inactive external display still makes another virtual display
/// unnecessary.
public final class CoreGraphicsDisplayTopologyMonitor: DisplayTopologyMonitoring {
    public init() {}

    public func current(excluding displayID: UInt32?) -> DisplayTopologySnapshot? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else {
            return DisplayTopologySnapshot(builtIn: nil, externalOnlineDisplayCount: 0)
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        ids = Array(ids.prefix(Int(count)))

        let builtIn = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }).map {
            DisplayTopologySnapshot.BuiltInDisplay(
                isOnline: CGDisplayIsOnline($0) != 0,
                isActive: CGDisplayIsActive($0) != 0,
                isAsleep: CGDisplayIsAsleep($0) != 0
            )
        }
        let externalCount = ids.filter {
            CGDisplayIsBuiltin($0) == 0 && $0 != displayID
        }.count
        return DisplayTopologySnapshot(
            builtIn: builtIn,
            externalOnlineDisplayCount: externalCount
        )
    }
}
