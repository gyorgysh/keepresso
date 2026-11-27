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

    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    var isAuthorized: Bool {
        status == .fullAccess
    }

    var canRequest: Bool {
        status == .notDetermined
    }

    func request() {
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.status = EKEventStore.authorizationStatus(for: .event)
            }
        }
    }
}
