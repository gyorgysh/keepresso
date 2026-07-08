import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "Launch at login" toggle.
///
/// No helper bundle or `launchd` plist needed, the modern `SMAppService` API
/// registers the main app itself (macOS 13+).
@MainActor
enum LoginItem {
    /// Whether Keepresso is currently registered to launch at login.
    /// Hands-off outside /Applications: even a status read makes Background
    /// Task Management repoint the app's record at this copy (see
    /// `HelperManager.managesDaemon`), which gets the helper daemon disabled.
    static var isEnabled: Bool {
        guard AppRelocator.runsFromApplications else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the login item. Failures are logged, not fatal.
    static func setEnabled(_ enabled: Bool) {
        guard AppRelocator.runsFromApplications else {
            NSLog("Keepresso: not in /Applications; leaving the login item alone")
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Keepresso: failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
    }
}
