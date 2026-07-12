import AppKit

/// The app-language choice: follow the system, or one of the shipped
/// localizations. Backed by the standard per-app `AppleLanguages` override,
/// which macOS resolves once at process start, so applying a change means
/// relaunching the app. That relaunch is the design (locked in with the
/// language feature): one mechanism, and every surface (menus, windows,
/// notifications, Core-built strings) switches together instead of some
/// lagging until the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case hungarian = "hu"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Menu label. "Follow System" localizes; each concrete language is named
    /// in its own tongue, so a user stranded in the wrong language can still
    /// find their own.
    var label: String {
        switch self {
        case .system: L("Follow System")
        case .english: "English"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .french: "Français"
        case .hungarian: "Magyar"
        case .simplifiedChinese: "简体中文"
        }
    }

    /// Our own record of the choice. `AppleLanguages` is derived from it: set
    /// alongside on change, re-synced at launch. Keeping a separate key makes
    /// "no override" unambiguous (`AppleLanguages` always reads back the
    /// system list, so its absence can't be probed directly).
    private static let overrideKey = "languageOverride"
    private static let appleLanguagesKey = "AppleLanguages"

    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: overrideKey),
              let language = AppLanguage(rawValue: raw) else { return .system }
        return language
    }

    /// Persist the choice and set (or clear) the `AppleLanguages` override.
    /// Takes effect on the next launch; callers follow with ``relaunch()``.
    func apply() {
        let defaults = UserDefaults.standard
        if self == .system {
            defaults.removeObject(forKey: Self.overrideKey)
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        } else {
            defaults.set(rawValue, forKey: Self.overrideKey)
            defaults.set([rawValue], forKey: Self.appleLanguagesKey)
        }
    }

    /// Launch-time repair: if an override is recorded, make sure the
    /// `AppleLanguages` key still matches it (a defaults wipe or an edit from
    /// outside the app can strand the two). No effect on the running process;
    /// the language was already resolved at start.
    static func syncAtLaunch() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: overrideKey),
              AppLanguage(rawValue: raw) != nil else { return }
        if defaults.array(forKey: appleLanguagesKey) as? [String] != [raw] {
            defaults.set([raw], forKey: appleLanguagesKey)
        }
    }

    /// Quit and start a fresh instance so everything re-resolves in the new
    /// language. A detached shell outlives this process, waits a beat for it
    /// to exit (macOS won't launch a second instance of a bundle that is
    /// still running), then reopens the bundle.
    static func relaunch() {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; /usr/bin/open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }
}
