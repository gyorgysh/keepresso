import CoreLocation
import Observation
import AppKit

/// Tracks Location Services authorization without blocking a SwiftUI update.
/// Core Location can wait indefinitely for its daemon even on a status read,
/// so all manager access lives on a shared background run-loop thread.
@Observable
final class LocationAuthorizer {
    /// Nil until Core Location has returned its initial status.
    private(set) var status: CLAuthorizationStatus?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        let worker = LocationAuthorizationWorker.shared
        observer = NotificationCenter.default.addObserver(
            forName: LocationAuthorizationWorker.statusChanged,
            object: worker,
            queue: .main
        ) { [weak self] _ in
            self?.status = worker.currentStatus
        }
        // Subscribe first, then read, so an update cannot be missed between
        // creating a view and receiving the worker's first result.
        status = worker.currentStatus
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isLoading: Bool { status == nil }
    var isAuthorized: Bool { status == .authorizedAlways || status == .authorized }
    var canRequest: Bool { status == .notDetermined }

    func request() {
        NSApp.activate(ignoringOtherApps: true)
        LocationAuthorizationWorker.shared.requestAuthorization()
    }
}

/// One worker for the process prevents repeated view opens from creating
/// additional threads if the system Location service stops responding.
private final class LocationAuthorizationWorker: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = LocationAuthorizationWorker()
    static let statusChanged = Notification.Name("KeepressoLocationAuthorizationStatusChanged")

    private let statusLock = NSLock()
    private var storedStatus: CLAuthorizationStatus?
    private var workerThread: Thread!
    // Created and used only on workerThread, including delegate callbacks.
    private var manager: CLLocationManager?

    var currentStatus: CLAuthorizationStatus? {
        statusLock.lock()
        defer { statusLock.unlock() }
        return storedStatus
    }

    private override init() {
        super.init()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "Keepresso Location authorization"
        workerThread = thread
        thread.start()
    }

    private func run() {
        // CLLocationManager sends delegate messages on its creating thread;
        // keep a run loop alive there rather than ever involving the UI thread.
        let port = Port()
        RunLoop.current.add(port, forMode: .default)
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        publish(manager.authorizationStatus)
        RunLoop.current.run()
    }

    func requestAuthorization() {
        perform(#selector(requestOnWorker), on: workerThread, with: nil, waitUntilDone: false)
    }

    @objc private func requestOnWorker() {
        manager?.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        publish(manager.authorizationStatus)
    }

    private func publish(_ status: CLAuthorizationStatus) {
        statusLock.lock()
        storedStatus = status
        statusLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.statusChanged, object: self)
        }
    }
}
