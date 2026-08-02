import Foundation

/// Controls the built-in display's user brightness (and optionally the keyboard
/// backlight), so a held session can dim the panel after idle ("dim, don't
/// sleep") or force the laptop panel and keys dark in clamshell while an
/// external monitor stays awake.
///
/// A protocol seam mirroring ``PowerAsserting`` and ``VirtualDisplaying``: the
/// behaviour stays testable with a fake, and the private display / keyboard
/// APIs live in the app target, never linked into this pure-SwiftPM library.
/// Core ships a no-op default (``NullBrightness``) that reports unsupported, so
/// the controller builds and tests without them.
public protocol BrightnessControlling: AnyObject {
    /// Whether panel brightness control is usable on this Mac right now: the
    /// private API resolved and a built-in display exists. When false the whole
    /// dim-don't-sleep feature is inert (and hidden in the UI).
    var isSupported: Bool { get }

    /// The built-in display's current user brightness in `0...1`, or `nil` if it
    /// can't be read (unsupported, or no built-in display).
    func currentBrightness() -> Double?

    /// Set the built-in display's user brightness, clamped to `0...1`. A no-op
    /// when unsupported. `0` is the dimmest backlight, not off: the display
    /// stays awake (the session still holds the display assertion), just dark.
    func setBrightness(_ level: Double)

    /// Whether the built-in keyboard backlight can be read and set. Independent
    /// of ``isSupported``: some Macs have a panel but no keyboard backlight.
    var isKeyboardSupported: Bool { get }

    /// The built-in keyboard backlight in `0...1`, or `nil` when unsupported.
    func currentKeyboardBrightness() -> Double?

    /// Set the built-in keyboard backlight, clamped to `0...1`. A no-op when
    /// unsupported.
    func setKeyboardBrightness(_ level: Double)
}

/// The default no-op backend, so ``SessionController`` builds and unit-tests
/// without the private brightness API. The app injects the real backend.
public final class NullBrightness: BrightnessControlling {
    public init() {}
    public var isSupported: Bool { false }
    public func currentBrightness() -> Double? { nil }
    public func setBrightness(_ level: Double) {}
    public var isKeyboardSupported: Bool { false }
    public func currentKeyboardBrightness() -> Double? { nil }
    public func setKeyboardBrightness(_ level: Double) {}
}
