import AppKit

/// On first launch from outside an Applications folder (the mounted DMG, the
/// Downloads folder, a Gatekeeper-translocated path), move Keepresso into
/// `/Applications` and relaunch from there, so it lives in a stable,
/// trusted location where auto-update and login-item registration behave.
///
/// Silent and best-effort by design: any failure just leaves the app running
/// from where it is. Development builds are never touched.
enum AppRelocator {
    static func relocateIfNeeded() {
        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path
        let env = ProcessInfo.processInfo.environment

        // Never relocate a build running from Xcode / DerivedData.
        if path.contains("/DerivedData/")
            || path.contains("/Build/Products/")
            || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
            || env["XCODE_VERSION_ACTUAL"] != nil {
            return
        }

        // Already in an Applications folder (system or user): nothing to do.
        if bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" {
            return
        }

        let dest = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(bundleURL.lastPathComponent)

        // If a copy is already installed, just launch it and quit this one
        // (don't clobber a possibly-running install). Otherwise copy ourselves in.
        if !fm.fileExists(atPath: dest.path) {
            do {
                try fm.copyItem(at: bundleURL, to: dest)
            } catch {
                return // best-effort: keep running from the current location
            }
        }

        // Launch the /Applications copy as a fresh instance, then terminate.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
