import Foundation
import AppKit

/// A point-in-time reading of the frontmost app, for game detection.
public struct GamingSnapshot: Equatable, Sendable {
    /// Bundle identifier of the frontmost app, if any.
    public var frontmostBundleID: String?
    /// The frontmost app's declared `LSApplicationCategoryType`, if any.
    public var frontmostCategoryType: String?

    public init(frontmostBundleID: String? = nil, frontmostCategoryType: String? = nil) {
        self.frontmostBundleID = frontmostBundleID
        self.frontmostCategoryType = frontmostCategoryType
    }
}

/// Abstraction over "what's frontmost and is it a game?" so the gaming trigger
/// can be tested without launching one. Mirrors the other monitor seams.
public protocol GamingMonitoring: AnyObject {
    var current: GamingSnapshot { get }
}

/// Real backend over `NSWorkspace.frontmostApplication`.
///
/// There is no public "Game Mode is active" API, so this reads the frontmost
/// app's `LSApplicationCategoryType` from its bundle instead (the same
/// declaration Game Mode itself keys on). Loading the bundle's Info.plist per
/// read is heavier than a workspace poll, so readings are cached briefly
/// (mirroring ``IOBluetoothDeviceMonitor``). No permissions involved.
public final class WorkspaceGamingMonitor: GamingMonitoring {
    private let ttl: TimeInterval
    private let now: () -> Date
    private let probe: () -> GamingSnapshot
    private var cached: GamingSnapshot?
    private var cachedAt: Date?

    public convenience init() {
        self.init(probe: Self.probeSystem)
    }

    /// The probe and clock are injectable so the cache can be unit-tested.
    init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        probe: @escaping () -> GamingSnapshot
    ) {
        self.ttl = ttl
        self.now = now
        self.probe = probe
    }

    public var current: GamingSnapshot {
        if let cached, let cachedAt, now().timeIntervalSince(cachedAt) < ttl {
            return cached
        }
        let snapshot = probe()
        cached = snapshot
        cachedAt = now()
        return snapshot
    }

    /// The real probe: the frontmost app and its declared category.
    static func probeSystem() -> GamingSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return GamingSnapshot()
        }
        let category = app.bundleURL
            .flatMap(Bundle.init(url:))?
            .object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        return GamingSnapshot(
            frontmostBundleID: app.bundleIdentifier,
            frontmostCategoryType: category
        )
    }
}

/// Fires while a game is frontmost: the app declares a games
/// `LSApplicationCategoryType` (`public.app-category.games` or any of its
/// subcategories) or is a known cloud-gaming client, which streams games
/// without declaring the category itself.
public final class GamingTrigger: Trigger {
    /// Grace applied by the factory: alt-tabbing to Discord or a walkthrough
    /// for a few minutes must not drop the session mid-game, so this is far
    /// more generous than ``BluetoothDeviceTrigger/releaseGrace``.
    public static let releaseGrace: TimeInterval = 300

    /// Cloud-gaming clients that stream games without declaring a games
    /// category. Verified from the shipping apps: GeForce NOW and Boosteroid.
    public static let cloudGamingBundleIDs: Set<String> = [
        "com.nvidia.gfnpc.mall",
        "com.boosteroid.macclient",
    ]

    private let monitor: GamingMonitoring

    public init(monitor: GamingMonitoring = WorkspaceGamingMonitor()) {
        self.monitor = monitor
    }

    public var label: String { "Playing a game" }

    public func isSatisfied() -> Bool {
        Self.isGame(monitor.current)
    }

    /// Pure decision function — exposed for direct unit testing.
    ///
    /// Games declare `public.app-category.games` or a subcategory like
    /// `public.app-category.action-games`; every subcategory ends in `-games`,
    /// so both shapes are matched (and nothing outside the app-category
    /// namespace is).
    static func isGame(_ snapshot: GamingSnapshot) -> Bool {
        if let id = snapshot.frontmostBundleID, cloudGamingBundleIDs.contains(id) {
            return true
        }
        guard let category = snapshot.frontmostCategoryType,
              category.hasPrefix("public.app-category.")
        else { return false }
        return category == "public.app-category.games" || category.hasSuffix("-games")
    }
}
