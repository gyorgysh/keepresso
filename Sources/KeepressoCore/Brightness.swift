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
    var isSupported: Bool { get }

    func currentBrightness() -> Double?

    func setBrightness(_ level: Double)

    var isKeyboardSupported: Bool { get }

    func currentKeyboardBrightness() -> Double?

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
