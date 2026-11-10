import SwiftUI
import AppKit
import KeepressoCore

/// A Preferences row that records a global keyboard shortcut. Clicking "Record"
/// captures the next key combination (via a *local* event monitor, which needs
/// no permission), requiring at least one modifier so the shortcut is safe to
/// register system-wide. Escape cancels; Delete/Backspace while recording clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: HotKeyShortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(shortcut?.displayString ?? L("None"))
                .foregroundStyle(shortcut == nil ? .secondary : .primary)
                .frame(minWidth: 60, alignment: .leading)
            Spacer()
            Button(recording ? L("Press keys…") : L("Record")) {
                recording ? stop() : start()
            }
            if shortcut != nil && !recording {
                Button("Clear") { shortcut = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // swallow the event while recording
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Escape cancels without changing anything.
        if event.keyCode == UInt16(kVK_Escape_) { stop(); return }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // A global hotkey needs at least one modifier; ignore a bare key so the
        // user can keep trying rather than recording something unusable.
        guard !modifiers.isEmpty else { return }

        shortcut = HotKeyShortcut(
            keyCode: Int(event.keyCode),
            modifierFlags: Int(modifiers.rawValue)
        )
        stop()
    }
}

/// The key Keep me active's specified-key method taps, plus any modifiers
/// sent with it on the same event.
struct PresenceKey: Equatable {
    var keyCode: Int
    var modifiers: ActivityKeyModifiers

    /// A menu-style label like "⌃F18".
    var displayString: String {
        HotKeyShortcut.label(
            keyName: HotKeyShortcut.keyName(for: keyCode) ?? L("Key %d", keyCode),
            control: modifiers.contains(.control), option: modifiers.contains(.option),
            shift: modifiers.contains(.shift), command: modifiers.contains(.command)
        )
    }
}

/// Records a virtual key for Keep me active's specified-key method, with any
/// Control, Option, Shift, or Command held at the time (none required).
/// A modifier tapped on its own is recorded on release, so holding it while
/// pressing another key records the combination instead. With several
/// modifiers tapped and no key, the last one pressed is recorded (a modifier
/// key is always sent alone). Escape cancels.
/// A local monitor, so no permission.
struct PresenceKeyRecorder: View {
    @Binding var key: PresenceKey?
    @State private var recording = false
    @State private var monitor: Any?
    /// The modifier key pressed most recently while recording, recorded on
    /// its own if every modifier is released before another key goes down.
    @State private var pendingModifier: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(key?.displayString ?? L("None"))
                .foregroundStyle(key == nil ? .secondary : .primary)
                .frame(minWidth: 60, alignment: .leading)
            Spacer()
            Button(recording ? L("Press keys…") : L("Record")) {
                recording ? stop() : start()
            }
            if key != nil && !recording {
                Button("Clear") { key = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        pendingModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        pendingModifier = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == UInt16(kVK_Escape_) { stop(); return }
            key = PresenceKey(keyCode: Int(event.keyCode), modifiers: Self.modifiers(of: event.modifierFlags))
            stop()
            return
        }
        // Caps Lock toggles rather than going down and up: take it at once,
        // on the press that turns it on.
        if Int(event.keyCode) == ActivityKeyModifiers.capsLockKeyCode {
            if event.modifierFlags.contains(.capsLock) {
                key = PresenceKey(keyCode: Int(event.keyCode), modifiers: [])
                stop()
            }
            return
        }
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if !held.isEmpty {
            // A modifier went down (or one of several came up): wait to see
            // whether a key follows.
            if pendingModifier == nil || Self.isPress(event) {
                pendingModifier = Int(event.keyCode)
            }
            return
        }
        // Every modifier is up with no key in between: record the tap alone.
        if let code = pendingModifier {
            key = PresenceKey(keyCode: code, modifiers: [])
            stop()
        }
    }

    /// Whether a flags-changed event is its own modifier going down.
    private static func isPress(_ event: NSEvent) -> Bool {
        guard let own = ActivityKeyModifiers.modifier(forKeyCode: Int(event.keyCode)) else { return false }
        return modifiers(of: event.modifierFlags).contains(own)
    }

    private static func modifiers(of flags: NSEvent.ModifierFlags) -> ActivityKeyModifiers {
        var modifiers: ActivityKeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

// `kVK_Escape` lives in Carbon.HIToolbox; alias it here so this view file
// doesn't need to import Carbon just for one constant.
private let kVK_Escape_ = 0x35
