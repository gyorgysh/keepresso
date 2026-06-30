import UserNotifications
import KeepressoCore

/// Real ``ReminderNotifying`` backed by `UNUserNotificationCenter`.
///
/// Intentionally **not** `@MainActor`: `UNUserNotificationCenter` is thread-safe
/// and its API is callable from any context, so leaving this non-isolated lets
/// it satisfy the non-isolated protocol without an actor-hop, mirroring
/// ``LocationAuthorizer``'s reasoning about main-thread confinement.
final class UserNotificationReminder: ReminderNotifying {
    private let center = UNUserNotificationCenter.current()
    private let identifier = "sh.gyorgy.keepresso.reminder"

    /// Ask for permission to post alerts. No-op after the first decision; safe
    /// to call whenever the user enables reminders.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        // A stable identifier means a fresh nudge replaces any prior one rather
        // than stacking up in Notification Center.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request)
    }

    func cancelPending() {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
