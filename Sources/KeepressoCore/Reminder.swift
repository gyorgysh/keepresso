import Foundation

/// Abstraction over delivering a "still brewing" reminder alert, so the session
/// logic can decide *when* to nudge without depending on `UserNotifications`.
///
/// Mirrors the other system seams (``PowerAsserting``, ``SettingsStore``): the
/// app wires the real `UNUserNotificationCenter`-backed implementation and tests
/// use an in-memory fake that just records calls.
public protocol ReminderNotifying: AnyObject {
    func notify(title: String, body: String, sound: Bool)

    func cancelPending()
}
