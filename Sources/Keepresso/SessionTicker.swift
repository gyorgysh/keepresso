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
    private let closedDisplay: ClosedDisplayController
    private let powerSource: PowerSourceMonitoring
    private let thermalGuard: ThermalGuardController?
    /// Receives the thermal guard's escalation effects (fan boost, pause,
    /// releases) each tick they occur; AppModel turns them into helper calls
    /// and notifications.
    private let onThermalEffects: (([ThermalEffect]) -> Void)?
    /// Runs after each reconcile, e.g. to mirror session state to the widget.
    private let onTick: (() -> Void)?
    private var timer: Timer?

    init(
        session: SessionController,
        disk: DiskKeepAliveController,
        closedDisplay: ClosedDisplayController,
        powerSource: PowerSourceMonitoring = IOKitPowerSourceMonitor(),
        thermalGuard: ThermalGuardController? = nil,
        onThermalEffects: (([ThermalEffect]) -> Void)? = nil,
        onTick: (() -> Void)? = nil
    ) {
        self.session = session
        self.disk = disk
        self.closedDisplay = closedDisplay
        self.powerSource = powerSource
        self.thermalGuard = thermalGuard
        self.onThermalEffects = onThermalEffects
        self.onTick = onTick
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak session, weak disk, weak closedDisplay, weak self] _ in
            MainActor.assumeIsolated {
                if let session {
                    // Only run the per-second IOKit sweeps reconcile can actually
                    // use: the idle read feeds the screen-saver yield (off by
                    // default), the battery read feeds auto-pause (off by default).
                    // Report a discharging level only while actually on battery:
                    // on AC (even at a low charge, even while charging up from
                    // empty) the Mac isn't going to run flat, so auto-pause must
                    // not fire and any latched pause may lift.
                    var battery = SessionController.BatteryReading.unknown
                    if session.consumesBatteryReading, let power = self?.powerSource.current {
                        if power.provider == .battery, let percent = power.percentage {
                            battery = .discharging(percent)
                        } else if power.provider == .ac {
                            battery = .onAC
                        }
                    }
                    // The thermal guard ticks whenever it's configured (its
                    // fan stage runs even with stop-brewing off, so this
                    // can't hide behind consumesThermalReading); the session
                    // only reads its verdict when the pause stage is on.
                    var thermal = ThermalReading.unknown
                    if let guard_ = self?.thermalGuard {
                        let effects = guard_.tick()
                        if !effects.isEmpty { self?.onThermalEffects?(effects) }
                        if session.consumesThermalReading {
                            thermal = guard_.readingForSession
                        }
                    }
                    session.reconcile(
                        systemIdleSeconds: session.consumesIdleReading ? Self.systemIdleSeconds() : nil,
                        battery: battery,
                        thermal: thermal
                    )
                }
                disk?.tick(now: Date())
                closedDisplay?.tick()
                self?.onTick?()
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
    /// `IOHIDSystem` idle-time property. Reads the single `HIDIdleTime` key
    /// rather than copying the whole property dictionary (which carries a large
    /// nested `HIDParameters` set), since this runs once a second.
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

        guard let value = IORegistryEntryCreateCFProperty(
            entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(), let nanoseconds = value as? UInt64
        else { return 0 }

        return TimeInterval(nanoseconds) / 1_000_000_000
    }
}
