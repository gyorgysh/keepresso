import CoreGraphics
import KeepressoCore

/// Real ``BrightnessControlling`` over private DisplayServices (panel) and
/// CoreBrightness (keyboard backlight), targeting the built-in hardware only.
/// Reports each side unsupported when its symbols don't resolve or no built-in
/// device exists, so dim-don't-sleep and the clamshell dark force stay hidden
/// and inert where they can't work. Kept in the app target because
/// `KeepressoCore` is a pure SwiftPM library that must not link private
/// frameworks (mirrors ``CGVirtualDisplayBackend``).
final class DisplayServicesBrightnessBackend: BrightnessControlling {
    var isSupported: Bool { KPBrightnessAvailable() && builtInDisplay != nil }

    var isKeyboardSupported: Bool { KPKeyboardBrightnessAvailable() }

    /// The built-in panel's display id, re-resolved each call because displays
    /// come and go: dimming targets the laptop screen, never an attached
    /// external one. Prefer the online list so a lid-closed built-in still
    /// resolves in clamshell (it often drops out of the active list).
    private var builtInDisplay: CGDirectDisplayID? {
        firstBuiltin(using: CGGetOnlineDisplayList) ?? firstBuiltin(using: CGGetActiveDisplayList)
    }

    private func firstBuiltin(
        using list: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError
    ) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard list(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard list(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    func currentBrightness() -> Double? {
        guard let display = builtInDisplay else { return nil }
        var level: Float = 0
        return KPBrightnessGet(display, &level) ? Double(level) : nil
    }

    func setBrightness(_ level: Double) {
        guard let display = builtInDisplay else { return }
        _ = KPBrightnessSet(display, Float(max(0, min(1, level))))
    }

    func currentKeyboardBrightness() -> Double? {
        var level: Float = 0
        return KPKeyboardBrightnessGet(&level) ? Double(level) : nil
    }

    func setKeyboardBrightness(_ level: Double) {
        _ = KPKeyboardBrightnessSet(Float(max(0, min(1, level))))
    }
}
