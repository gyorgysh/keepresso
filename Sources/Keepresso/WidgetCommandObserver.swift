import Foundation
import KeepressoCore

/// Listens for the widget extension's Darwin "command waiting" notification
/// and runs a handler on the main actor.
///
/// Darwin notifications are the only doorbell that crosses from the sandboxed
/// appex to the unsandboxed app without either side holding a connection; the
/// payload itself travels through the App Group defaults (``WidgetBridge``).
final class WidgetCommandObserver {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        // The C callback can't capture context, so the observer pointer rides
        // along and is unwrapped back to `self` inside.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let instance = Unmanaged<WidgetCommandObserver>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in instance.handler() }
            },
            WidgetBridge.commandNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
