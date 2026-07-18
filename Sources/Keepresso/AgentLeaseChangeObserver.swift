import Foundation
import KeepressoCore

/// Listens for durable lease mutations from the CLI or MCP process so the app
/// can react immediately instead of waiting for the next one-second poll.
final class AgentLeaseChangeObserver {
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            Self.callback,
            SystemAgentLeaseAppSignaler.notificationName as CFString,
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

    private static let callback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let listener = Unmanaged<AgentLeaseChangeObserver>
            .fromOpaque(observer)
            .takeUnretainedValue()
        Task { @MainActor in listener.onChange() }
    }
}
