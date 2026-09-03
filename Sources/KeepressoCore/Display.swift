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

/// Reads whether the built-in panel is currently dark.
///
/// Separate from ``DisplayMonitoring``, which only counts what is attached: a
/// panel can be attached, awake and lit inside a closed lid, which is exactly
/// the state ``ClosedDisplayController`` exists to end.
public protocol DisplayPowerReading: AnyObject, Sendable {
    /// `true` when the built-in panel is asleep, `false` when it is lit, `nil`
    /// when it can't be told (no built-in panel, or the list couldn't be read).
    /// Callers treat `nil` as "don't act".
    func builtInIsAsleep() -> Bool?
}

/// Real ``DisplayPowerReading`` over `CGDisplayIsAsleep`. Uses the *online*
/// display list rather than the active one: a sleeping built-in panel drops out
/// of the active list, and reading that as "gone" would lose the distinction
/// this type exists to make.
public final class CoreGraphicsDisplayPower: DisplayPowerReading {
    public init() {}

    public func builtInIsAsleep() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        let builtIn = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
        // No built-in panel at all (a desktop Mac): nothing here to put to
        // sleep, which reads the same as already asleep.
        guard !builtIn.isEmpty else { return true }
        return builtIn.allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }
}
