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

/// Records a single virtual key (no modifiers required) for Keep me active's
/// specified-key method. Escape cancels. A local monitor, so no permission.
struct PresenceKeyRecorder: View {
    @Binding var keyCode: Int?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(keyLabel)
                .foregroundStyle(keyCode == nil ? .secondary : .primary)
                .frame(minWidth: 60, alignment: .leading)
            Spacer()
            Button(recording ? L("Press keys…") : L("Record")) {
                recording ? stop() : start()
            }
            if keyCode != nil && !recording {
                Button("Clear") { keyCode = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private var keyLabel: String {
        guard let keyCode else { return L("None") }
        return HotKeyShortcut.keyName(for: keyCode) ?? L("Key %d", keyCode)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == UInt16(kVK_Escape_) { stop(); return }
            keyCode = Int(event.keyCode)
            stop()
            return
        }
        // Modifier-only tap (Shift, Control, Option, Command, Caps Lock).
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .capsLock])
        guard !flags.isEmpty else { return }
        keyCode = Int(event.keyCode)
        stop()
    }
}

// `kVK_Escape` lives in Carbon.HIToolbox; alias it here so this view file
// doesn't need to import Carbon just for one constant.
private let kVK_Escape_ = 0x35
