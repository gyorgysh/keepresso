import Foundation
import IOKit

/// Reads whether the built-in lid is currently closed.
public protocol LidStateReading: AnyObject, Sendable {
    /// `true`/`false` if readable, `nil` on a Mac with no lid (e.g. a Mac mini
    /// or Studio) or if the property can't be read.
    func isClosed() -> Bool?
}

/// Real ``LidStateReading`` backed by the `AppleClamshellState` property on the
/// `IOPMrootDomain` IOKit registry entry, the same de facto technique other
/// clamshell-aware tools use (there's no public API for this).
public final class IORegistryLidState: LidStateReading {
    public init() {}

    public func isClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool else { return nil }

        return value
    }
}

/// Shares one lid reading among everything that looks within a tick (the
/// session ticker and the closed-lid features), so the IORegistry is read
/// once a second rather than once per feature. Timed with a monotonic clock
/// that keeps counting through sleep, so a wall clock set back can't pin a
/// stale reading.
public final class CachedLidState: LidStateReading, @unchecked Sendable {
    private let source: LidStateReading
    private let ttlNanos: UInt64
    private let clock: @Sendable () -> UInt64
    private let lock = NSLock()
    private var cached: (at: UInt64, closed: Bool?)?

    public init(
        _ source: LidStateReading = IORegistryLidState(),
        ttl: TimeInterval = 0.5,
        clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
    ) {
        self.source = source
        self.ttlNanos = UInt64(max(ttl, 0) * 1_000_000_000)
        self.clock = clock
    }

    public func isClosed() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if let cached, now >= cached.at, now - cached.at < ttlNanos { return cached.closed }
        let closed = source.isClosed()
        cached = (now, closed)
        return closed
    }
}

/// Commands the display(s) to sleep immediately, independent of any idle timer.
public protocol DisplaySleepCommanding: Sendable {
    func sleepNow()
}

/// Real ``DisplaySleepCommanding`` backed by `pmset displaysleepnow`. Unlike
/// `pmset -a disablesleep`, this needs no administrator rights.
public final class PMSetDisplaySleeper: DisplaySleepCommanding {
    public init() {}

    public func sleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        // Fire-and-forget: there's no result worth waiting for (unlike
        // `disablesleep`, nothing here can meaningfully fail in a way the UI
        // would surface), so skip `waitUntilExit()` and its main-thread block.
        try? process.run()
    }
}
