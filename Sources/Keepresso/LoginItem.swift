import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "Launch at login" toggle.
///
/// No helper bundle or `launchd` plist needed — the modern `SMAppService` API
/// registers the main app itself (macOS 13+).
@MainActor
enum LoginItem {
    /// Whether Keepresso is currently registered to launch at login.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register or unregister the login item. Failures are logged, not fatal.
    static func setEnabled(_ enabled: Bool) {
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
