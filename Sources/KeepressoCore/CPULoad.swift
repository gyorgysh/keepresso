import Foundation

/// Abstraction over the machine's overall CPU usage so a load trigger can be
/// tested with scripted readings. Mirrors the other monitor seams.
public protocol CPULoadReading: AnyObject {
    func currentLoad() -> Double?
}

/// Real backend over Mach's `host_statistics` CPU tick counters. Usage is the
/// busy-tick share of the delta between consecutive calls, so the first call
/// returns `nil` (a since-boot average would be meaningless here).
///
/// Readings are cached briefly: the trigger engine and the menu's live rule
/// list each evaluate within the same tick, and back-to-back delta reads
/// would give the second caller a meaninglessly tiny interval.
public final class HostCPULoadReader: CPULoadReading {
    struct Ticks: Equatable {
        var busy: UInt64
        var total: UInt64
    }

    private var previous: Ticks?
    private let ttl: TimeInterval
    private let now: () -> Date
    private let readTicks: () -> Ticks?
    private lazy var cache = TTLCache<Double?>(ttl: ttl, now: now) { [unowned self] in
        self.readLoadDelta()
    }

    public convenience init() {
        self.init(readTicks: Self.machTicks)
    }

    init(
        ttl: TimeInterval = 0.5,
        now: @escaping () -> Date = Date.init,
        readTicks: @escaping () -> Ticks?
    ) {
        self.ttl = ttl
        self.now = now
        self.readTicks = readTicks
    }

    public func currentLoad() -> Double? { cache.current }

    private func readLoadDelta() -> Double? {
        guard let ticks = readTicks() else { return nil }
        defer { previous = ticks }
        guard let previous, ticks.total > previous.total else { return nil }
        return Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)
    }

    private static func machTicks() -> Ticks? {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        return Ticks(busy: busy, total: busy + UInt64(info.cpu_ticks.2))
    }
}

/// Fires while overall CPU usage sits above a threshold: a build, render, or
/// training run is working, so the Mac should stay awake.
///
/// Raw per-second usage is spiky, so the decision runs on an exponential
/// moving average (a brief spike doesn't start a session) with hysteresis
/// (once on, it takes a dip clearly below the threshold to turn off, so usage
/// hovering at the threshold doesn't flap). The state transition is a pure
/// function (``step(_:sample:thresholdPercent:)``) for direct unit testing.
public final class CPULoadTrigger: Trigger {
    /// Percentage (1...100) the smoothed usage must reach.
    public var thresholdPercent: Int

    static let alpha = 0.25
    static let hysteresis = 0.05

    public struct SmoothingState: Equatable, Sendable {
        public var average: Double?
        public var isSatisfied = false
        public init() {}
    }

    private let reader: CPULoadReading
    private var state = SmoothingState()

    public init(thresholdPercent: Int, reader: CPULoadReading = HostCPULoadReader()) {
        self.thresholdPercent = thresholdPercent
        self.reader = reader
    }

    public var label: String { L("CPU above %d%%", thresholdPercent) }

    /// Advance the smoothing average by one reading. Done here (not in
    /// ``isSatisfied()``) so the EMA steps exactly once per reconcile: the menu's
    /// live rule list also reads this trigger, and stepping on every read would
    /// double the effective smoothing rate whenever the menu is open.
    public func tick() {
        state = Self.step(state, sample: reader.currentLoad(), thresholdPercent: thresholdPercent)
    }

    public func isSatisfied() -> Bool { state.isSatisfied }

    static func step(_ state: SmoothingState, sample: Double?, thresholdPercent: Int) -> SmoothingState {
        var next = state
        guard thresholdPercent > 0 else {
            next.average = nil
            next.isSatisfied = false
            return next
        }
        if let sample {
            let clamped = min(max(sample, 0), 1)
            next.average = state.average.map { $0 + alpha * (clamped - $0) } ?? clamped
        }
        guard let average = next.average else {
            next.isSatisfied = false
            return next
        }
        let on = Double(thresholdPercent) / 100
        let off = max(on - hysteresis, on * 0.5)
        next.isSatisfied = state.isSatisfied ? average >= off : average >= on
        return next
    }
}
