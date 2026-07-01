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
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best-effort: nothing to surface this failure to.
        }
    }
}
