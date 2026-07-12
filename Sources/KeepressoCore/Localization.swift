import Foundation

/// Localized-string lookups against ``KeepressoCore``'s own resource bundle
/// (`Bundle.module`). The app and Core ship separate `Localizable.strings`
/// tables, so Core strings must resolve through `.module`, not the main bundle.
///
/// `L` takes the English source string as its key: it doubles as the fallback
/// when a translation is missing, matching the app-side convention where
/// SwiftUI's `Text("literal")` uses the literal as the key.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

/// Formatted variant: looks the key up, then substitutes the arguments through
/// the localized format string (so `%@`/`%d` order is per-language).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
