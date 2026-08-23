import SwiftUI
import AppKit
import KeepressoCore

/// Locks the keyboard so the Mac can be wiped. Mouse and trackpad stay live
/// so Unlock is a click. No Accessibility prompt: hidutil remaps special
/// function keys, and the overlay swallows ordinary keyDown as a second
/// line. The overlay is shown only after any administrator prompt has been
/// answered.
struct KeyboardCleanerView: View {
    @Bindable var model: AppModel
    @State private var windowVisible = false
    @State private var duration: TimeInterval = 60
    @State private var overlay: KeyboardLockOverlay?
    @State private var starting = false

    private var lock: KeyboardLockController { model.keyboardLock }

    var body: some View {
        Group {
            if windowVisible {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    content
                        .padding(16)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 460, height: 300)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        .centersAndFrontsWindow()
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            guard windowVisible else { return }
            lock.tick()
            if !lock.isLocked { overlay?.close() }
        }
        .onChange(of: lock.isLocked) { _, locked in
            if !locked {
                overlay?.close()
                overlay = nil
                model.resumeHotKeyAfterKeyboardLock()
            }
        }
        .onDisappear { overlay?.close() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keyboard Cleaner")
                .font(.title2.bold())
            Text("Locks the keys so you can wipe the keyboard without typing into whatever is in front. The pointer still works: click Unlock when you are done.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Lock for", selection: $duration) {
                Text("30 seconds").tag(TimeInterval(30))
                Text("1 minute").tag(TimeInterval(60))
                Text("2 minutes").tag(TimeInterval(120))
                Text("Until I click").tag(TimeInterval(0))
            }
            .pickerStyle(.radioGroup)
            .disabled(lock.isLocked || lock.isBusy || starting)

            if lock.isLocked {
                Text(lock.isGlobal
                     ? L("Keyboard is locked. Wipe away.")
                     : L("Could not lock keys globally (another tool may own the keyboard). Keys are only ignored while this overlay is in front."))
                    .font(.callout)
                    .foregroundStyle(lock.isGlobal ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if lock.isBusy {
                AdminAuthNote(purpose: L("lock the keyboard"))
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if lock.isLocked {
                    Button("Unlock") { unlock() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                } else {
                    Button("Lock Keyboard") { startLock() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(lock.isBusy || starting)
                }
            }
        }
    }

    private func startLock() {
        starting = true
        let duration = duration > 0 ? duration : nil
        Task {
            let result = await model.lockKeyboard(duration: duration)
            starting = false
            guard result != .cancelled else { return }
            let overlay = KeyboardLockOverlay(controller: lock) { unlock() }
            overlay.show()
            self.overlay = overlay
        }
    }

    private func unlock() {
        overlay?.close()
        overlay = nil
        lock.unlock()
        model.resumeHotKeyAfterKeyboardLock()
    }
}

/// Borderless dim overlay covering every Space. Mouse clicks reach Unlock;
/// keyDown is swallowed as a backup if hidutil did not remap.
@MainActor
final class KeyboardLockOverlay: NSObject {
    private var window: NSWindow?
    private let controller: KeyboardLockController
    private let onUnlock: () -> Void
    private var keyMonitor: Any?
    private var timer: Timer?

    init(controller: KeyboardLockController, onUnlock: @escaping () -> Void) {
        self.controller = controller
        self.onUnlock = onUnlock
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let view = KeyboardLockOverlayView(
            remaining: remainingText(),
            isGlobal: controller.isGlobal,
            onUnlock: onUnlock
        )
        let hosting = NSHostingView(rootView: view)
        let window = LockOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.setFrame(screen.frame, display: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        self.window = window

        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]
        ) { _ in
            nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }

    private func refresh() {
        controller.tick()
        guard controller.isLocked, let window else {
            onUnlock()
            return
        }
        if let hosting = window.contentView as? NSHostingView<KeyboardLockOverlayView> {
            hosting.rootView = KeyboardLockOverlayView(
                remaining: remainingText(),
                isGlobal: controller.isGlobal,
                onUnlock: onUnlock
            )
        }
    }

    private func remainingText() -> String? {
        guard let unlockAt = controller.unlockAt else { return nil }
        let left = max(0, unlockAt.timeIntervalSinceNow)
        let seconds = Int(left.rounded(.up))
        if seconds >= 60 {
            return L("%d min %d sec", seconds / 60, seconds % 60)
        }
        return L("%d sec", seconds)
    }
}

private final class LockOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct KeyboardLockOverlayView: View {
    var remaining: String?
    var isGlobal: Bool
    var onUnlock: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 20) {
                Text("Keyboard is locked")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Wipe away. The pointer still works. Click Unlock when you are done.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                if let remaining {
                    Text(remaining)
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(.white)
                }
                if !isGlobal {
                    Text("Keys are only ignored while this overlay is in front.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Button(action: onUnlock) {
                    Text("Unlock")
                        .font(.title2.bold())
                        .frame(minWidth: 220, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
