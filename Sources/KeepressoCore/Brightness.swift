import Foundation

/// Controls the built-in display's user brightness, so a held session can dim
/// the panel to a floor after the user goes idle instead of leaving it fully
/// lit all night ("dim, don't sleep").
///
/// A protocol seam mirroring ``PowerAsserting`` and ``VirtualDisplaying``: the
/// behaviour stays testable with a fake, and the private display API it needs
/// (DisplayServices / CoreDisplay) lives in the app target, never linked into
/// this pure-SwiftPM library. Core ships a no-op default (``NullBrightness``)
/// that reports unsupported, so the controller builds and tests without it.
public protocol BrightnessControlling: AnyObject {
    /// Whether brightness control is usable on this Mac right now: the private
    /// API resolved and a built-in display exists. When false the whole
    /// dim-don't-sleep feature is inert (and hidden in the UI).
    var isSupported: Bool { get }

    /// The built-in display's current user brightness in `0...1`, or `nil` if it
    /// can't be read (unsupported, or no built-in display).
    func currentBrightness() -> Double?

    /// Set the built-in display's user brightness, clamped to `0...1`. A no-op
    /// when unsupported. `0` is the dimmest backlight, not off: the display
    /// stays awake (the session still holds the display assertion), just dark.
    func setBrightness(_ level: Double)
}

/// The default no-op backend, so ``SessionController`` builds and unit-tests
/// without the private brightness API. The app injects the real backend.
public final class NullBrightness: BrightnessControlling {
    public init() {}
    public var isSupported: Bool { false }
    public func currentBrightness() -> Double? { nil }
    public func setBrightness(_ level: Double) {}
}
