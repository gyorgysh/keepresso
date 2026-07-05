import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// Abstraction over "make the OS and idle detectors see the user as active",
/// mirroring ``PowerAsserting``.
///
/// ``PowerAsserting`` keeps the Mac awake, but an `IOPMAssertion` does **not**
/// reset app-level or enterprise idle detection: remote-desktop / VDI clients,
/// Teams / Slack presence, Citrix, and MDM idle-logout still mark you away or
/// lock you out. This seam resets that idle signal on the supported, prompt-free
/// path, so a keep-active session also defeats those detectors. Injected like
/// every other system seam; tests use a recording fake.
public protocol ActivitySimulating: AnyObject {
    /// Report user activity now: reset the OS idle timer (the same signal real
    /// keyboard/mouse input sends). Called on a slow cadence while a keep-active
    /// session runs, never every tick.
    func poke()
}

/// Real backend. `IOPMAssertionDeclareUserActivity` is the documented,
/// prompt-free call that resets the system idle timer; a 1px
/// `CGWarpMouseCursorPosition` nudge (moved and immediately restored, so it's
/// imperceptible) covers detectors that sample the raw HID cursor directly.
/// Neither call needs Accessibility or triggers any TCC prompt, unlike
/// synthesizing keyboard events.
public final class IOKitActivitySimulator: ActivitySimulating {
    private var assertionID = IOPMAssertionID(0)

    public init() {}

    public func poke() {
        IOPMAssertionDeclareUserActivity(
            "Keepresso keep-active" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        // Nudge the pointer 1px and back for raw-HID idle watchers. A warp, not
        // a synthesized event, so it stays prompt-free.
        let location = CGEvent(source: nil)?.location ?? .zero
        CGWarpMouseCursorPosition(CGPoint(x: location.x + 1, y: location.y))
        CGWarpMouseCursorPosition(location)
    }
}
