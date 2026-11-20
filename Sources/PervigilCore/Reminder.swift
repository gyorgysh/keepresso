import Foundation

/// Abstraction over delivering a "still brewing" reminder alert, so the session
/// logic can decide *when* to nudge without depending on `UserNotifications`.
///
/// Mirrors the other system seams (``PowerAsserting``, ``SettingsStore``): the
/// app wires the real `UNUserNotificationCenter`-backed implementation and tests
/// use an in-memory fake that just records calls.
public protocol ReminderNotifying: AnyObject {
    /// Post the reminder alert now. The controller composes the user-facing
    /// `title`/`body`; the implementation just delivers them. When `sound` is
    /// true the alert also plays the system notification sound.
    func notify(title: String, body: String, sound: Bool)

    /// Drop any reminder belonging to a session that has ended, so a Mac woken
    /// and put back to sleep doesn't surface a stale nudge.
    func cancelPending()
}
