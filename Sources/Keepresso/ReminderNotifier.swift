import AppKit
import UserNotifications
import KeepressoCore

/// Real ``ReminderNotifying`` backed by `UNUserNotificationCenter`.
///
/// Intentionally **not** `@MainActor`: `UNUserNotificationCenter` is thread-safe
/// and its API is callable from any context, so leaving this non-isolated lets
/// it satisfy the non-isolated protocol without an actor-hop, mirroring
/// ``LocationAuthorizer``'s reasoning about main-thread confinement.
final class UserNotificationReminder: NSObject, ReminderNotifying, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let identifier = "sh.gyorgy.keepresso.reminder"

    override init() {
        super.init()
        // Without a delegate, macOS silently drops banners posted while the
        // app is frontmost. That's exactly when the "needs your password"
        // notices fire: Keepresso activates itself so the password dialog is
        // focused, and posts the explanation in the same breath. (The center
        // holds the delegate weakly; this instance lives as long as the app.)
        center.delegate = self
    }

    /// Present notifications even while Keepresso is the active app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// A click on the stale-Trash notice opens the Trash in Finder, so the
    /// user lands right where the copy they need to delete is. Opening a
    /// folder just asks Finder to show a window; unlike deleting in there, it
    /// needs no Trash permission.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == StaleBundleCleaner.notificationIdentifier,
           let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            DispatchQueue.main.async { NSWorkspace.shared.open(trash) }
        }
        completionHandler()
    }

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
