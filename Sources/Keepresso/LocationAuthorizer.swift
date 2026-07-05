import CoreLocation
import Observation

/// Tracks (and requests) Location Services authorization.
///
/// Reading the joined Wi-Fi SSID via CoreWLAN requires Location permission on
/// recent macOS, without it `CWInterface.ssid()` returns `nil` even while
/// connected. The rules editor uses this to gate the "add current Wi-Fi"
/// shortcut behind a one-tap permission prompt.
///
/// Intentionally **not** `@MainActor`: this is created as a `@State` default in
/// a SwiftUI view (a non-isolated context), so an isolated `init` won't compile
/// under strict concurrency. `CLLocationManager` delivers its delegate callbacks
/// on the thread that created it, the main thread here, so the unsynchronized
/// `status` mutation is already main-thread-confined in practice.
@Observable
final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    /// The current authorization status, kept live via the delegate callback.
    private(set) var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Whether the SSID will be readable.
    var isAuthorized: Bool {
        status == .authorizedAlways || status == .authorized
    }

    /// Whether we can still ask (vs. the user having denied).
    var canRequest: Bool {
        status == .notDetermined
    }

    /// Show the system permission prompt (no-op if already decided).
    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
    }
}
