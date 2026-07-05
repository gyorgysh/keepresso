import Foundation
import Observation

/// Where (and how often) to keep a disk spun up. Persisted in
/// ``KeepressoSettings``; `nil` there means the feature is off.
public struct DiskKeepAliveConfig: Codable, Equatable, Sendable {
    /// Directory whose volume to keep awake. A small marker file is rewritten
    /// inside it each interval, choosing a folder on the target disk (an
    /// external drive or NAS mount) is what keeps that volume from spinning down.
    public var directory: URL

    /// Seconds between touches. Should sit comfortably under the disk's idle
    /// spin-down timeout.
    public var interval: TimeInterval

    public init(directory: URL, interval: TimeInterval = DiskKeepAliveConfig.defaultInterval) {
        self.directory = directory
        self.interval = interval
    }

    /// A sensible first-enable cadence (most drives idle out at 10 min).
    public static let defaultInterval: TimeInterval = 5 * 60

    /// The hidden marker file rewritten on each touch.
    static let markerName = ".keepresso-keepalive"

    /// Full path of the marker file inside ``directory``.
    public var markerURL: URL {
        directory.appendingPathComponent(Self.markerName)
    }
}

/// Abstraction over the one filesystem write the keep-alive performs, so the
/// throttling logic is unit-testable without touching a real disk. Mirrors the
/// other system seams (``PowerAsserting``, ``ReminderNotifying``).
public protocol DiskTouching: AnyObject {
    /// Perform one no-op write at `url`. Returns whether it succeeded.
    @discardableResult
    func touch(at url: URL) -> Bool
}

/// Drives the periodic disk touch. Like ``SessionController`` it runs no timer
/// of its own, the host calls ``tick(now:)`` once a second and this throttles
/// down to ``DiskKeepAliveConfig/interval``.
@MainActor
@Observable
public final class DiskKeepAliveController {
    /// Active configuration, or `nil` when the feature is off. Assigning a new
    /// value resets the throttle so the next ``tick(now:)`` touches immediately.
    public var config: DiskKeepAliveConfig? {
        didSet { if config != oldValue { lastTouch = nil } }
    }

    /// When the last successful-or-attempted touch happened, for diagnostics
    /// and the menu's status line.
    public private(set) var lastTouch: Date?

    /// Whether the most recent touch failed (e.g. the disk was unmounted).
    public private(set) var lastTouchFailed = false

    private let toucher: DiskTouching

    public init(toucher: DiskTouching = FileSystemToucher()) {
        self.toucher = toucher
    }

    /// Touch the disk if the configured interval has elapsed. Cheap and safe to
    /// call every second; a no-op while disabled or still inside the interval.
    public func tick(now: Date) {
        guard let config else { return }
        if let last = lastTouch, now.timeIntervalSince(last) < config.interval { return }
        lastTouchFailed = !toucher.touch(at: config.markerURL)
        lastTouch = now
    }
}

/// Real ``DiskTouching`` that atomically rewrites the marker file. The atomic
/// write (temp file + rename) forces genuine I/O to the target volume, which is
/// what actually keeps it spun up.
public final class FileSystemToucher: DiskTouching {
    public init() {}

    @discardableResult
    public func touch(at url: URL) -> Bool {
        let payload = Data("Keepresso keep-alive\n".utf8)
        do {
            try payload.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
