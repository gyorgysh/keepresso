import SwiftUI
import AppKit
import KeepressoCore

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
        if event.keyCode == UInt16(kVK_Escape_) { stop(); return }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.isEmpty else { return }

        shortcut = HotKeyShortcut(
            keyCode: Int(event.keyCode),
            modifierFlags: Int(modifiers.rawValue)
        )
        stop()
    }
}

struct PresenceKey: Equatable {
    var keyCode: Int
    var modifiers: ActivityKeyModifiers

    var displayString: String {
        modifiers.symbols + (HotKeyShortcut.keyName(for: keyCode) ?? L("Key %d", keyCode))
    }
}

/// Records a virtual key for Keep me active's specified-key method. Control,
/// Option, Shift, or Command held at the time are recorded with F13 to F20
/// only. Any other key pressed with a modifier is ignored, since it could be
/// a shortcut (Command-Q) the poke would fire at the front app every minute.
/// A modifier tapped on its own is recorded on release, so holding it while
/// pressing another key records the combination instead. With several
/// modifiers tapped and no key, the last one pressed is recorded (a modifier
/// key is always sent alone). Escape cancels.
/// A local monitor, so no permission.
struct PresenceKeyRecorder: View {
    @Binding var key: PresenceKey?
    @State private var recording = false
    @State private var monitor: Any?
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
            let code = Int(event.keyCode)
            let modifiers = Self.modifiers(of: event.modifierFlags)
            if !modifiers.isEmpty, !ActivityKeyModifiers.acceptsModifiers(keyCode: code) {
                // Swallowed (the monitor returns nil), so a Command-Q here
                // never reaches the app either. Keep listening.
                return
            }
            key = PresenceKey(keyCode: code, modifiers: modifiers)
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
            if pendingModifier == nil || Self.isPress(event) {
                pendingModifier = Int(event.keyCode)
            }
            return
        }
        if let code = pendingModifier {
            key = PresenceKey(keyCode: code, modifiers: [])
            stop()
        }
    }

    private static func isPress(_ event: NSEvent) -> Bool {
        guard let own = ActivityKeyModifiers.modifier(forKeyCode: Int(event.keyCode)) else { return false }
        return modifiers(of: event.modifierFlags).contains(own)
    }

    /// AppKit's modifier flags use the same bits as Core Graphics'.
    private static func modifiers(of flags: NSEvent.ModifierFlags) -> ActivityKeyModifiers {
        ActivityKeyModifiers(eventFlags: CGEventFlags(rawValue: UInt64(flags.rawValue)))
    }
}

// `kVK_Escape` lives in Carbon.HIToolbox; alias it here so this view file
// doesn't need to import Carbon just for one constant.
private let kVK_Escape_ = 0x35
