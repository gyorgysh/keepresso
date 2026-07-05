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
            Text(shortcut?.displayString ?? "None")
                .foregroundStyle(shortcut == nil ? .secondary : .primary)
                .frame(minWidth: 60, alignment: .leading)
            Spacer()
            Button(recording ? "Press keys…" : "Record") {
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

// `kVK_Escape` lives in Carbon.HIToolbox; alias it here so this view file
// doesn't need to import Carbon just for one constant.
private let kVK_Escape_ = 0x35
