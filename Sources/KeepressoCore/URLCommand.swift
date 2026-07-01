import Foundation

/// A remote-control command carried in a `keepresso://` URL, so scripts and
/// launchers (Shortcuts, Raycast, Alfred) can drive a session without opening
/// the menu. The app registers the scheme and hands incoming URLs to
/// ``URLCommand/parse(_:)``; the pure parser lives in Core so it's unit-tested
/// without AppKit.
///
/// Recognised forms:
/// - `keepresso://start` — start an indefinite session
/// - `keepresso://start?duration=60` — start a timed session (minutes)
/// - `keepresso://stop`
/// - `keepresso://toggle`
public enum URLCommand: Equatable, Sendable {
    case start(mode: SessionMode)
    case stop
    case toggle

    /// Parses a `keepresso://` URL into a command, or `nil` if it's not one
    /// Keepresso recognises (wrong scheme, unknown host, or a malformed
    /// `duration`).
    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "keepresso" else { return nil }
        switch url.host?.lowercased() {
        case "start":
            guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "duration" })?.value
            else { return .start(mode: .indefinite) }
            guard let minutes = Double(raw), minutes > 0 else { return nil }
            return .start(mode: .timed(duration: minutes * 60))
        case "stop":
            return .stop
        case "toggle":
            return .toggle
        default:
            return nil
        }
    }
}
