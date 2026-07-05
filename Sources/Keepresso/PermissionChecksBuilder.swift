import AppKit
import CoreBluetooth
import CoreLocation
import EventKit
import UserNotifications
import KeepressoCore

/// Builds the app-permission rows for the headless-readiness Setup screen and
/// hands them to the ``SystemReadinessController``. Extracted from ``AppModel``:
/// the five checks shared one shape (a Bool, an ok/warn status, ok/warn detail
/// strings, a remediation), and which permissions to show was three near-identical
/// rule scans. Both now collapse to ``makeCheck(...)`` and
/// ``TriggerRule/requiredPermission``.
@MainActor
final class PermissionChecksBuilder {
    private let readiness: SystemReadinessController
    /// Monotonic token; only the newest rebuild's async notification result is
    /// applied, so a slower earlier rebuild can't clobber a newer list.
    private var generation = 0

    init(readiness: SystemReadinessController) {
        self.readiness = readiness
    }

    /// Rebuild the permission rows for the current rules. The login-item and the
    /// per-rule permission statuses read synchronously; the notification status
    /// is async, so it lands a moment later (guarded by ``generation``).
    func rebuild(for rules: [TriggerRule]) {
        var base = [loginItemCheck()]
        // One row per distinct permission the rule set actually needs, in the
        // permission enum's declared order (location, bluetooth, calendar).
        for permission in TriggerRule.Permission.allCases
        where rules.contains(where: { $0.requiredPermission == permission }) {
            base.append(check(for: permission))
        }
        readiness.permissionChecks = base

        generation &+= 1
        let generation = self.generation
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard generation == self.generation else { return }
            readiness.permissionChecks = base + [notificationCheck(settings.authorizationStatus)]
        }
    }

    private func check(for permission: TriggerRule.Permission) -> ReadinessCheck {
        switch permission {
        case .location:  return locationCheck()
        case .bluetooth: return bluetoothCheck()
        case .calendar:  return calendarCheck()
        }
    }

    // MARK: - Individual checks

    private func loginItemCheck() -> ReadinessCheck {
        makeCheck(
            id: "perm-login-item",
            title: "Launch at login",
            authorized: LoginItem.isEnabled,
            okDetail: "Keepresso launches at login, so it returns after a reboot.",
            warnDetail: "Keepresso isn't set to launch at login, so it won't run after an unattended reboot.",
            hint: "Turn on “Launch at login” in Keepresso's settings.",
            settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        )
    }

    private func locationCheck() -> ReadinessCheck {
        let status = CLLocationManager().authorizationStatus
        return makeCheck(
            id: "perm-location",
            title: "Location access (Wi-Fi rules)",
            authorized: status == .authorizedAlways || status == .authorized,
            okDetail: "Keepresso can read the current Wi-Fi network name for your Wi-Fi triggers.",
            warnDetail: "Without Location access Keepresso can't read the Wi-Fi network name, so Wi-Fi triggers won't match.",
            hint: "Allow Location access for Keepresso.",
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        )
    }

    private func bluetoothCheck() -> ReadinessCheck {
        makeCheck(
            id: "perm-bluetooth",
            title: "Bluetooth access (device rules)",
            authorized: CBManager.authorization == .allowedAlways,
            okDetail: "Keepresso can see which paired devices are connected for your Bluetooth triggers.",
            warnDetail: "Without Bluetooth access Keepresso can't see paired devices, so Bluetooth triggers won't match.",
            hint: "Allow Bluetooth access for Keepresso.",
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        )
    }

    private func calendarCheck() -> ReadinessCheck {
        makeCheck(
            id: "perm-calendar",
            title: "Calendar access (event rule)",
            authorized: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            okDetail: "Keepresso can see when a calendar event is in progress for your calendar trigger.",
            warnDetail: "Without full calendar access Keepresso can't see events, so the calendar trigger won't match.",
            hint: "Allow full calendar access for Keepresso.",
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        )
    }

    private func notificationCheck(_ status: UNAuthorizationStatus) -> ReadinessCheck {
        makeCheck(
            id: "perm-notifications",
            title: "Notifications",
            authorized: status == .authorized || status == .provisional,
            okDetail: "Keepresso can post the “still brewing” reminder.",
            warnDetail: "Notifications are off, so the “still brewing” reminder can't appear.",
            hint: "Allow notifications for Keepresso.",
            settingsURL: "x-apple.systempreferences:com.apple.preference.notifications"
        )
    }

    /// The shared shape: an ok/warn status plus, when not OK, a remediation that
    /// points at the relevant System Settings pane.
    private func makeCheck(
        id: String,
        title: String,
        authorized: Bool,
        okDetail: String,
        warnDetail: String,
        hint: String,
        settingsURL: String
    ) -> ReadinessCheck {
        ReadinessCheck(
            id: id,
            title: title,
            status: authorized ? .ok : .warning,
            detail: authorized ? okDetail : warnDetail,
            remediation: authorized ? nil : Remediation(
                hint: hint,
                settingsURL: URL(string: settingsURL)
            )
        )
    }
}
