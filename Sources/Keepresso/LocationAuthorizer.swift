import CoreLocation
import Observation
import AppKit

/// Tracks (and requests) Location Services authorization.
///
/// Reading the joined Wi-Fi SSID via CoreWLAN requires Location permission on
/// recent macOS, without it `CWInterface.ssid()` returns `nil` even while
/// connected. The rules editor uses this to gate the "add current Wi-Fi"
/// shortcut behind a one-tap permission prompt.
///
/// Never touches Core Location itself: creating a `CLLocationManager` or
/// reading its status can block for as long as `locationd` is unresponsive,
/// which used to hang Preferences on open. ``LocationAuthorization`` does that
/// work on its own thread, and this class only mirrors its cached status.
///
/// Intentionally **not** `@MainActor`: this is created as a `@State` default in
/// a SwiftUI view (a non-isolated context), so an isolated `init` won't compile
/// under strict concurrency. Status updates arrive on the main queue, so the
/// unsynchronized `status` mutation stays main-thread-confined in practice.
@Observable
final class LocationAuthorizer {
    /// `nil` until Core Location has answered for the first time.
    private(set) var status: CLAuthorizationStatus?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        let source = LocationAuthorization.shared
        // Subscribe before reading, so an answer landing in between is not lost.
        observer = NotificationCenter.default.addObserver(
            forName: LocationAuthorization.didChange, object: source, queue: .main
        ) { [weak self] _ in
            self?.status = source.status
        }
        status = source.status
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Core Location has not answered yet (it may be stuck).
    var isPending: Bool { status == nil }

    /// Whether the SSID will be readable.
    var isAuthorized: Bool {
        status == .authorizedAlways || status == .authorized
    }

    /// Whether we can still ask (vs. the user having denied). False while the
    /// first answer is pending, so no button offers a prompt that may not apply.
    var canRequest: Bool {
        status == .notDetermined
    }

    /// Show the system permission prompt (no-op if already decided).
    func request() {
        NSApp.activate(ignoringOtherApps: true)
        LocationAuthorization.shared.request()
    }
}

/// The process's single `CLLocationManager`, owned by a dedicated run-loop
/// thread. Core Location delivers delegate callbacks on the thread that made
/// the manager, so keeping that thread alive keeps every call, including the
/// initial status read, off the main thread. One shared instance means
/// reopening a window while `locationd` is stuck cannot pile up more threads.
final class LocationAuthorization: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = LocationAuthorization()

    /// Posted on the main queue whenever ``status`` changes.
    static let didChange = Notification.Name("sh.gyorgy.keepresso.location-authorization")

    private let lock = NSLock()
    private var cached: CLAuthorizationStatus?
    private var thread: Thread?
    /// Created and used only on ``thread``.
    private var manager: CLLocationManager?

    /// The last status Core Location reported, `nil` before its first answer.
    /// Never blocks.
    var status: CLAuthorizationStatus? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    private override init() {
        super.init()
        let thread = Thread { [unowned self] in run() }
        thread.name = "Keepresso location authorization"
        self.thread = thread
        thread.start()
    }

    private func run() {
        // A run loop with no sources returns at once; the port keeps it alive
        // so delegate callbacks have somewhere to land.
        RunLoop.current.add(Port(), forMode: .default)
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        publish(manager.authorizationStatus)
        RunLoop.current.run()
    }

    func request() {
        guard let thread else { return }
        perform(#selector(requestOnThread), on: thread, with: nil, waitUntilDone: false)
    }

    @objc private func requestOnThread() {
        manager?.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        publish(manager.authorizationStatus)
    }

    private func publish(_ status: CLAuthorizationStatus) {
        lock.lock()
        let changed = cached != status
        cached = status
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
