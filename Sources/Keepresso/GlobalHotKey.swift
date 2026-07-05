import AppKit
import Carbon.HIToolbox
import KeepressoCore

/// Registers a single system-wide hotkey and calls a handler when it's pressed.
///
/// Uses Carbon's `RegisterEventHotKey`, which needs **no** Accessibility or
/// Input Monitoring permission (unlike `NSEvent.addGlobalMonitorForEvents`), so
/// the global toggle stays within Keepresso's no-TCC posture.
@MainActor
final class GlobalHotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onPress: (() -> Void)?

    /// A four-char-code signature identifying our hotkey registration ('KPRS').
    private static let signature: OSType = 0x4B505253

    /// Register `shortcut` (replacing any previous one), invoking `onPress` when
    /// it fires. A `nil` shortcut, or one with no modifiers, just clears it: a
    /// modifier-less system hotkey would swallow a bare key everywhere.
    func update(to shortcut: HotKeyShortcut?, onPress: @escaping () -> Void) {
        self.onPress = onPress
        unregister()
        guard let shortcut else { return }
        let carbonModifiers = shortcut.carbonModifiers
        guard carbonModifiers != 0 else { return }

        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), carbonModifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr { hotKeyRef = ref }
    }

    fileprivate func fire() { onPress?() }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

/// Carbon hotkey events are delivered on the main thread, so hop straight back
/// onto the main actor and invoke the manager's handler.
private func hotKeyEventHandler(
    _ call: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { manager.fire() }
    return noErr
}

extension HotKeyShortcut {
    /// The stored `NSEvent` modifier flags translated to Carbon modifier masks
    /// (`cmdKey`, `optionKey`, ...) for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// A menu-style label like "⌃⌥⌘K" for the Preferences recorder row.
    var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option)  { parts += "⌥" }
        if flags.contains(.shift)   { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts + (Self.keyName(for: keyCode) ?? "?")
    }

    /// A readable name for the common virtual key codes. Letters and digits use
    /// their character; a handful of named keys are spelled out.
    static func keyName(for keyCode: Int) -> String? {
        if let named = namedKeys[keyCode] { return named }
        return characters[keyCode]
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let characters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]
}
