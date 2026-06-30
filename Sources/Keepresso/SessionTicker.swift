import Foundation
import IOKit
import KeepressoCore

/// Drives ``SessionController/reconcile(now:systemIdleSeconds:)`` once a second
/// while the app is running, feeding it the real HID idle time so the
/// screen-saver-yield and timed-session expiry can fire. Also pumps the
/// ``DiskKeepAliveController`` on the same tick (it throttles itself).
@MainActor
final class SessionTicker {
    private let session: SessionController
    private let disk: DiskKeepAliveController
    private var timer: Timer?

    init(session: SessionController, disk: DiskKeepAliveController) {
        self.session = session
        self.disk = disk
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak session, weak disk] _ in
            MainActor.assumeIsolated {
                session?.reconcile(systemIdleSeconds: Self.systemIdleSeconds())
                disk?.tick(now: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Seconds since the last HID (keyboard/mouse/trackpad) event, via IOKit's
    /// `IOHIDSystem` idle-time property.
    static func systemIdleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        defer { if iterator != 0 { IOObjectRelease(iterator) } }

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem"),
            &iterator
        ) == KERN_SUCCESS else { return 0 }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any],
              let nanoseconds = dict["HIDIdleTime"] as? UInt64
        else { return 0 }

        return TimeInterval(nanoseconds) / 1_000_000_000
    }
}
