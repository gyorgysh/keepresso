import EventKit
import Observation

/// Tracks (and requests) full calendar access.
///
/// The calendar trigger queries EventKit, which is TCC-gated. The rules editor
/// uses this to gate the "during calendar events" condition behind a one-tap
/// permission prompt, mirroring ``LocationAuthorizer``.
///
/// Intentionally **not** `@MainActor` for the same reason as the other
/// authorizers: it's created as a `@State` default in a SwiftUI view, and the
/// request completion hops to the main queue before touching `status`.
@Observable
final class CalendarAuthorizer {
    /// The store the prompt is issued through; EventKit ties the request to a
    /// live store instance.
    private let store = EKEventStore()

    /// The current authorization status, refreshed when the prompt resolves.
    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    /// Whether events can be read.
    var isAuthorized: Bool {
        status == .fullAccess
    }

    /// Whether we can still ask (vs. the user having denied or granted
    /// write-only access).
    var canRequest: Bool {
        status == .notDetermined
    }

    /// Show the system permission prompt (no-op if already decided).
    func request() {
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.status = EKEventStore.authorizationStatus(for: .event)
            }
        }
    }
}
