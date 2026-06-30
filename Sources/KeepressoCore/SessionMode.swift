import Foundation

/// How long a keep-awake session should run.
public enum SessionMode: Hashable, Codable, Sendable {
    /// Stay awake until the user explicitly stops (or a trigger turns off).
    case indefinite

    /// Stay awake for a fixed duration, then stop automatically.
    case timed(duration: TimeInterval)

    /// The wall-clock interval after which a timed session should end, or `nil`
    /// for indefinite sessions.
    public var duration: TimeInterval? {
        switch self {
        case .indefinite: return nil
        case .timed(let duration): return duration
        }
    }
}
