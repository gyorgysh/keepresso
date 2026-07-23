import Foundation

/// A remote-control command carried in a `keepresso://` URL, so scripts and
/// launchers (Shortcuts, Raycast, Alfred) can drive a session without opening
/// the menu. The app registers the scheme and hands incoming URLs to
/// ``URLCommand/parse(_:)``; the pure parser lives in Core so it's unit-tested
/// without AppKit.
///
/// Recognised forms:
/// - `keepresso://start`: start an indefinite session
/// - `keepresso://start?duration=60`: start a timed session (minutes)
/// - `keepresso://start?until=18:00`: start a session ending at a wall-clock
///   time (later today, or tomorrow if it already passed; 24-hour HH:MM)
/// - `keepresso://stop`
/// - `keepresso://toggle`
/// - `keepresso://sync-leases`: rescan automation inputs now (and launch the
///   app if needed). Carries no parameters on purpose: lease data travels in
///   validated files, the URL is only the doorbell.
public enum URLCommand: Equatable, Sendable {
    case start(mode: SessionMode)
    case stop
    case toggle
    case syncLeases

    /// Parses a `keepresso://` URL into a command, or `nil` if it's not one
    /// Keepresso recognises (wrong scheme, unknown host, or a malformed
    /// `duration`/`until`). `until` resolves against `now`, so parse when
    /// handling the URL, not ahead of time; `duration` wins if both appear.
    public static func parse(
        _ url: URL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> URLCommand? {
        guard url.scheme?.lowercased() == "keepresso" else { return nil }
        switch url.host?.lowercased() {
        case "start":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            if let raw = query?.first(where: { $0.name == "duration" })?.value {
                guard let minutes = Double(raw), minutes > 0 else { return nil }
                return .start(mode: .timed(duration: minutes * 60))
            }
            if let raw = query?.first(where: { $0.name == "until" })?.value {
                guard let mode = untilMode(raw, now: now, calendar: calendar) else { return nil }
                return .start(mode: mode)
            }
            return .start(mode: .indefinite)
        case "stop":
            return .stop
        case "toggle":
            return .toggle
        case "sync-leases":
            return .syncLeases
        default:
            return nil
        }
    }

    /// "18:00" (24-hour HH:MM) → the mode ending at its next occurrence.
    private static func untilMode(_ raw: String, now: Date, calendar: Calendar) -> SessionMode? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return SessionMode.until(hour: hour, minute: minute, now: now, calendar: calendar)
    }
}
