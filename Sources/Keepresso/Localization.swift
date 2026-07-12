import Foundation

/// Localized-string lookups against the app's main-bundle `Localizable.strings`.
///
/// Most UI text localizes automatically: SwiftUI resolves `Text("literal")`,
/// `Button("literal")`, etc. as `LocalizedStringKey` against the main bundle.
/// `L` is for the cases that don't go through that path: interpolated strings
/// (built with `%@`/`%d` format keys), notification bodies, and any `String`
/// value used where SwiftUI would otherwise take the non-localizing overload.
///
/// The English source string is the key, doubling as the missing-translation
/// fallback, matching the convention used throughout the app and Core.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Formatted variant: look the key up, then substitute the arguments through the
/// localized format string.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
