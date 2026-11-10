import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import ApplicationServices

/// How Keep me active reports activity. The default stays prompt-free. HID
/// methods (a key tap or a posted mouse move) are what a lot of software
/// actually watches, and they need Accessibility.
public enum ActivitySimulationMethod: String, Codable, CaseIterable, Sendable {
    /// `IOPMAssertionDeclareUserActivity` plus a 1px cursor warp. No TCC.
    case powerWarp
    /// F15 down/up, the Windows Caffeine classic. Most keyboards lack F15, so
    /// nothing is typed. Needs Accessibility.
    case f15
    /// Left Shift down/up, invisible and non-printing. Needs Accessibility.
    case shift
    /// A user-chosen virtual key. Needs Accessibility. A letter or number will
    /// type into the front app.
    case specifiedKey
    /// Posted HID mouse-moved 1px and back, not a warp. Needs Accessibility.
    case mouseMove

    /// Carbon virtual key code for F15.
    public static let f15KeyCode: UInt16 = 0x71
    /// Carbon virtual key code for left Shift.
    public static let shiftKeyCode: UInt16 = 0x38

    /// HID methods post a real key or mouse event, which TCC gates.
    public var needsAccessibility: Bool { self != .powerWarp }

    /// Warp stays on the original 30s cadence. HID methods fire every 60s,
    /// matching Caffeine and sitting under common app idle timeouts.
    public var pokeInterval: TimeInterval { needsAccessibility ? 60 : 30 }
}

/// Modifiers sent with a specified-key poke, set only on that one key event
/// (nothing is held down for other input). Chromium skips its focus-ring
/// heuristic for a key pressed with Control, Option, or Command, so a combo
/// like Control+F18 keeps browsers and Electron apps from drawing focus rings.
/// Raw values are this app's own, stable for persistence.
public struct ActivityKeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ActivityKeyModifiers(rawValue: 1 << 0)
    public static let control = ActivityKeyModifiers(rawValue: 1 << 1)
    public static let option = ActivityKeyModifiers(rawValue: 1 << 2)
    public static let command = ActivityKeyModifiers(rawValue: 1 << 3)

    /// Every bit this build knows. A stored value is masked to it.
    public static let all: ActivityKeyModifiers = [.shift, .control, .option, .command]

    /// The modifier a Carbon virtual key code is, for either side's Shift,
    /// Control, Option, or Command. `nil` for every other key.
    public static func modifier(forKeyCode code: Int) -> ActivityKeyModifiers? {
        switch code {
        case 0x38, 0x3C: return .shift
        case 0x3B, 0x3E: return .control
        case 0x3A, 0x3D: return .option
        case 0x37, 0x36: return .command
        default: return nil
        }
    }

    /// Carbon virtual key codes for Caps Lock and Fn.
    public static let capsLockKeyCode = 0x39
    public static let functionKeyCode = 0x3F

    /// Whether a key code is itself a modifier key (including Caps Lock and
    /// Fn). Such a key carries its own flag, so it is never sent with others.
    public static func isModifierKey(_ code: Int) -> Bool {
        modifier(forKeyCode: code) != nil || code == capsLockKeyCode || code == functionKeyCode
    }
}

/// The concrete poke the simulator performs for one tick.
public enum ActivityPokeKind: Equatable, Sendable {
    /// Prompt-free: declare user activity and warp the cursor 1px.
    case powerWarp
    /// Key down/up of this Carbon virtual key code, with these modifiers set
    /// on the key-down event. Needs Accessibility.
    case key(UInt16, modifiers: ActivityKeyModifiers = [])
    /// Posted HID mouse-moved 1px and back. Needs Accessibility.
    case mouseMove
}

/// TCC Accessibility trust. HID keep-active methods need this. Never prompt
/// from the 1 Hz poke path: only Preferences asks, when the user picks a HID
/// method.
public enum AccessibilityTrust {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    /// Prompt if the process is not already trusted. Returns the post-prompt
    /// state (still false if the user declined or the dialog is showing).
    @discardableResult
    public static func requestIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// Abstraction over "report user activity so other software keeps you
/// present", mirroring ``PowerAsserting``.
///
/// ``PowerAsserting`` keeps the Mac awake, but an `IOPMAssertion` does **not**
/// reset app-level idle timeouts: meetings and chat, remote desktop and VDI,
/// cloud gaming, and many other tools still treat a quiet keyboard as idle.
/// This seam is the input those apps watch. Injected like every other system
/// seam. Tests use a recording fake.
public protocol ActivitySimulating: AnyObject {
    /// Report user activity now. Called on a slow cadence while a keep-active
    /// session runs (and between sessions with the brewing scope off), never
    /// every tick.
    func poke(_ kind: ActivityPokeKind)
}

/// Real backend.
///
/// `.powerWarp` is the documented, prompt-free path: `IOPMAssertionDeclareUserActivity`
/// plus a 1px `CGWarpMouseCursorPosition` nudge. Warp does not generate HID
/// events, so a lot of software ignores it.
///
/// HID kinds post a real key or mouse event through `CGEventPost`. That is
/// what those apps watch, and it needs Accessibility. If the process is not
/// trusted the post is a no-op and the warp still runs so the OS idle timer
/// resets. The poke path never prompts.
public final class IOKitActivitySimulator: ActivitySimulating {
    private var assertionID = IOPMAssertionID(0)

    public init() {}

    public func poke(_ kind: ActivityPokeKind) {
        declareUserActivity()
        switch kind {
        case .powerWarp:
            warpCursor()
        case .key(let code, let modifiers):
            tapKey(code, modifiers: modifiers)
            if !AccessibilityTrust.isTrusted { warpCursor() }
        case .mouseMove:
            postMouseMove()
            if !AccessibilityTrust.isTrusted { warpCursor() }
        }
    }

    private func declareUserActivity() {
        IOPMAssertionDeclareUserActivity(
            "Keepresso keep-active" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
    }

    /// Nudge the pointer 1px and back. A warp, not a synthesized event, so it
    /// stays prompt-free. Skip when the location cannot be read, rather than
    /// jumping to the origin.
    private func warpCursor() {
        guard let location = CGEvent(source: nil)?.location else { return }
        CGWarpMouseCursorPosition(CGPoint(x: location.x + 1, y: location.y))
        CGWarpMouseCursorPosition(location)
    }

    /// The modifiers ride on the key-down only. No modifier key events are
    /// posted and the key-up carries no flags, so nothing stays held for
    /// real or automated input.
    private func tapKey(_ code: CGKeyCode, modifiers: ActivityKeyModifiers) {
        let source = CGEventSource(stateID: .hidSystemState)
            ?? CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = Self.flags(for: code).union(Self.flags(for: modifiers))
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func postMouseMove() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let source = CGEventSource(stateID: .hidSystemState)
            ?? CGEventSource(stateID: .combinedSessionState)
        let nudged = CGPoint(x: location.x + 1, y: location.y)
        if let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: nudged,
            mouseButton: .left
        ) {
            move.setIntegerValueField(.mouseEventDeltaX, value: 1)
            move.post(tap: .cghidEventTap)
        }
        if let back = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: location,
            mouseButton: .left
        ) {
            back.setIntegerValueField(.mouseEventDeltaX, value: -1)
            back.post(tap: .cghidEventTap)
        }
    }

    /// Modifier virtual keys need their flag bit set on key-down so the event
    /// looks like a real tap rather than a bare code.
    private static func flags(for code: CGKeyCode) -> CGEventFlags {
        if Int(code) == ActivityKeyModifiers.capsLockKeyCode { return .maskAlphaShift }
        return ActivityKeyModifiers.modifier(forKeyCode: Int(code)).map(flags(for:)) ?? []
    }

    private static func flags(for modifiers: ActivityKeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}
