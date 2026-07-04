import CoreBluetooth
import Observation

/// Tracks (and requests) Bluetooth privacy authorization.
///
/// Enumerating paired devices via IOBluetooth is TCC-gated on modern macOS.
/// The rules editor uses this to gate the "add Bluetooth device" section
/// behind a one-tap permission prompt, mirroring ``LocationAuthorizer``.
///
/// Intentionally **not** `@MainActor` for the same reason as
/// ``LocationAuthorizer``: it's created as a `@State` default in a SwiftUI
/// view, and the CoreBluetooth delegate is bound to the main queue, so the
/// unsynchronized `status` mutation is main-thread-confined in practice.
@Observable
final class BluetoothAuthorizer: NSObject, CBCentralManagerDelegate {
    /// Kept alive after ``request()``: deallocating the manager before the
    /// user answers would dismiss the system prompt.
    private var manager: CBCentralManager?

    /// The current authorization status, refreshed via the delegate callback.
    private(set) var status: CBManagerAuthorization = CBManager.authorization

    /// Whether paired devices can be listed.
    var isAuthorized: Bool {
        status == .allowedAlways
    }

    /// Whether we can still ask (vs. the user having denied).
    var canRequest: Bool {
        status == .notDetermined
    }

    /// Show the system permission prompt: instantiating a central manager is
    /// what triggers it (no-op if already decided or already requested).
    func request() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        status = CBManager.authorization
    }
}
