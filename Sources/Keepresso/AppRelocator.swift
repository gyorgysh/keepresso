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

        // If the installed copy is already running, hand over to it instead of
        // spawning a second instance (two cups, both holding assertions). If
        // it's an older version, Sparkle will offer the update from there.
        if let running = runningInstance(at: dest) {
            running.activate()
            NSApp.terminate(nil)
            return
        }

        if fm.fileExists(atPath: dest.path) {
            // Replace an older installed copy rather than launching it: someone
            // double-clicking a newer DMG expects to end up on the new version,
            // not silently back on the old one. Keep an equal-or-newer install.
            if (buildNumber(of: dest) ?? 0) < (buildNumber(of: bundleURL) ?? 0) {
                do {
                    try fm.removeItem(at: dest)
                    try fm.copyItem(at: bundleURL, to: dest)
                } catch {
                    // Best-effort: fall through and launch whatever is installed.
                }
            }
        } else {
            do {
                try fm.copyItem(at: bundleURL, to: dest)
            } catch {
                return // best-effort: keep running from the current location
            }
        }

        // Launch the /Applications copy, then terminate. No running instance
        // exists (checked above), so this starts it rather than duplicating it.
        NSWorkspace.shared.openApplication(at: dest, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Another live instance of this app running from `bundleURL`, if any.
    private static func runningInstance(at bundleURL: URL) -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            $0 != .current && $0.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL
        }
    }

    /// `CFBundleVersion` (the monotonically bumped build number) of the bundle
    /// at a URL, or `nil` when unreadable.
    private static func buildNumber(of bundleURL: URL) -> Int? {
        guard let raw = Bundle(url: bundleURL)?
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        return Int(raw)
    }
}
