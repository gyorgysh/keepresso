import Foundation
import GameController

// MARK: - Monitor seam

/// Abstraction over "is a game controller connected?" so the trigger and the
/// activity poke can be tested without hardware. Mirrors the other monitor
/// seams (``GamingMonitoring``, ``BluetoothMonitoring``).
public protocol ControllerMonitoring: AnyObject {
    /// Number of currently connected game controllers.
    var connectedCount: Int { get }
}

/// Real backend over the GameController framework. `GCController.controllers()`
/// tracks connects and disconnects on its own once the process has a run
/// loop (the app always does), and reading it involves no TCC prompt.
public final class GCControllerMonitor: ControllerMonitoring {
    public init() {}
    public var connectedCount: Int { GCController.controllers().count }
}

// MARK: - Trigger

/// Fires while at least one game controller is connected. Deliberately
/// parameterless: unlike Bluetooth audio devices, people rarely need to
/// distinguish which controller means "keep awake".
public final class ControllerTrigger: Trigger {
    /// Short grace, matching ``BluetoothDeviceTrigger/releaseGrace``: a
    /// controller briefly rebonding (battery dip, host switch) must not drop
    /// the session.
    public static let releaseGrace: TimeInterval = 30

    private let monitor: ControllerMonitoring

    public init(monitor: ControllerMonitoring = GCControllerMonitor()) {
        self.monitor = monitor
    }

    public var label: String { L("Game controller connected") }

    public func isSatisfied() -> Bool {
        monitor.connectedCount > 0
    }
}

// MARK: - Controller activity poke

/// Declares user activity while someone plays with a controller, because
/// gamepad input does not reliably reset the HID idle timer: a controller-only
/// session can dim or sleep the display mid-game even while Keepresso holds
/// the system awake. Pure policy over injected effects, driven by the app's
/// 1 Hz tick like everything else.
@MainActor
public final class ControllerActivityPoker {
    /// The Setup screen's toggle. Off by default: poking resets the idle
    /// timer, which also defeats the screen-saver yield, so it stays opt-in.
    public var enabled = false

    /// Matches ``SessionController/activityPokeInterval``: often enough that
    /// no dim threshold can pass, rare enough to cost nothing.
    public static let pokeInterval: TimeInterval = 30

    private let activity: ActivitySimulating
    private let now: () -> Date
    private var lastPokeAt: Date?

    public init(
        activity: ActivitySimulating = IOKitActivitySimulator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.activity = activity
        self.now = now
    }

    /// One pulse: pokes when the feature is on, a game is being played, a
    /// controller is connected, and a keep-awake session is actually active
    /// (an idle Keepresso must not keep the display lit on its own).
    public func tick(gamingActive: Bool, controllerConnected: Bool, sessionActive: Bool) {
        guard enabled, gamingActive, controllerConnected, sessionActive else {
            lastPokeAt = nil
            return
        }
        let instant = now()
        if let last = lastPokeAt, instant.timeIntervalSince(last) < Self.pokeInterval {
            return
        }
        lastPokeAt = instant
        activity.poke()
    }
}
