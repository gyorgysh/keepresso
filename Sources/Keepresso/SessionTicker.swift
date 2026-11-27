import Foundation
import IOKit
import KeepressoCore

@MainActor
final class SessionTicker {
    private let session: SessionController
    private let disk: DiskKeepAliveController
    private let closedDisplay: ClosedDisplayController
    private let powerSource: PowerSourceMonitoring
    private let thermalGuard: ThermalGuardController?
    private let onThermalEffects: (([ThermalEffect]) -> Void)?
    private let lid: LidStateReading
    private let externalDisplay: DisplayMonitoring
    private let gameFrontmost: (() -> Bool)?
    private var thermalArming = ThermalArming()
    private let onTick: (() -> Void)?
    private var timer: Timer?

    init(
        session: SessionController,
        disk: DiskKeepAliveController,
        closedDisplay: ClosedDisplayController,
        powerSource: PowerSourceMonitoring = IOKitPowerSourceMonitor(),
        thermalGuard: ThermalGuardController? = nil,
        lid: LidStateReading = IORegistryLidState(),
        externalDisplay: DisplayMonitoring = CoreGraphicsDisplayMonitor(),
        gameFrontmost: (() -> Bool)? = nil,
        onThermalEffects: (([ThermalEffect]) -> Void)? = nil,
        onTick: (() -> Void)? = nil
    ) {
        self.session = session
        self.disk = disk
        self.closedDisplay = closedDisplay
        self.powerSource = powerSource
        self.thermalGuard = thermalGuard
        self.lid = lid
        self.externalDisplay = externalDisplay
        self.gameFrontmost = gameFrontmost
        self.onThermalEffects = onThermalEffects
        self.onTick = onTick
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak session, weak disk, weak closedDisplay, weak self] _ in
            MainActor.assumeIsolated {
                if let session {
                    var battery = SessionController.BatteryReading.unknown
                    if session.consumesBatteryReading, let power = self?.powerSource.current {
                        if power.provider == .battery, let percent = power.percentage {
                            battery = .discharging(percent)
                        } else if power.provider == .ac {
                            battery = .onAC
                        }
                    }
                    let needsLid = self?.thermalGuard != nil || session.consumesDisplayReading
                    let lidClosed = needsLid ? self?.lid.isClosed() : nil
                    var thermal = ThermalReading.unknown
                    if let guard_ = self?.thermalGuard, let self {
                        let armed = self.thermalArming.update(
                            lidClosed: lidClosed,
                            sleepOverrideActive: closedDisplay?.isEnabled
                        )
                        let effects = guard_.tick(armed: armed)
                        if !effects.isEmpty { self.onThermalEffects?(effects) }
                        if session.consumesThermalReading {
                            thermal = guard_.readingForSession
                        }
                    }
                    // Lid + external layout for the display assertion and the
                    // clamshell dark force. The display list is only swept once
                    // the lid actually reads shut. A nil lid read stays
                    // `.unknown` so the controller can keep its latched verdict
                    // (mirroring ClosedDisplay / ThermalArming) instead of
                    // thrashing the assertion on an AppleClamshellState flutter.
                    var display = SessionController.DisplayReading.unknown
                    if session.consumesDisplayReading, let lidClosed, let self {
                        if lidClosed {
                            display = self.externalDisplay.current.hasExternalDisplay
                                ? .lidShutWithExternal
                                : .lidShutNoExternal
                        } else {
                            display = .usable
                        }
                    }
                    session.reconcile(
                        systemIdleSeconds: session.consumesIdleReading ? Self.systemIdleSeconds() : nil,
                        battery: battery,
                        thermal: thermal,
                        display: display,
                        gameFrontmost: self?.gameFrontmost?() ?? false
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
    /// nested `HIDParameters` set), since this runs once a second. Returns
    /// `nil` when the reading fails so keep-active still pokes and
    /// dim/yield hold their state, matching a missing idle reading.
    static func systemIdleSeconds() -> TimeInterval? {
        var iterator: io_iterator_t = 0
        defer { if iterator != 0 { IOObjectRelease(iterator) } }

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem"),
            &iterator
        ) == KERN_SUCCESS else { return nil }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        guard let value = IORegistryEntryCreateCFProperty(
            entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(), let nanoseconds = value as? UInt64
        else { return nil }

        return TimeInterval(nanoseconds) / 1_000_000_000
    }
}
