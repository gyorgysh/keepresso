import Foundation

/// Abstraction over the machine's overall CPU usage so a load trigger can be
/// tested with scripted readings. Mirrors the other monitor seams.
public protocol CPULoadReading: AnyObject {
    /// Overall CPU usage since the previous call, as a fraction (0...1), or
    /// `nil` when no reading is available yet (first call, or a failed read).
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
    /// One cumulative sample of the host's CPU tick counters.
    struct Ticks: Equatable {
        var busy: UInt64
        var total: UInt64
    }

    private var previous: Ticks?
    private let ttl: TimeInterval
    private let now: () -> Date
    private let readTicks: () -> Ticks?
    private var cachedLoad: Double?
    private var cachedAt: Date?

    public convenience init() {
        self.init(readTicks: Self.machTicks)
    }

    /// The tick source and clock are injectable so the delta and TTL logic can
    /// be unit-tested without real hardware counters.
    init(
        ttl: TimeInterval = 0.5,
        now: @escaping () -> Date = Date.init,
        readTicks: @escaping () -> Ticks?
    ) {
        self.ttl = ttl
        self.now = now
        self.readTicks = readTicks
    }

    public func currentLoad() -> Double? {
        if let cachedAt, now().timeIntervalSince(cachedAt) < ttl {
            return cachedLoad
        }
        let load = readLoadDelta()
        cachedLoad = load
        cachedAt = now()
        return load
    }

    private func readLoadDelta() -> Double? {
        guard let ticks = readTicks() else { return nil }
        defer { previous = ticks }
        guard let previous, ticks.total > previous.total else { return nil }
        return Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)
    }

    /// The real sample: Mach's cumulative per-state CPU tick counters.
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
        // cpu_ticks lanes: 0 = user, 1 = system, 2 = idle, 3 = nice.
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

    /// Smoothing weight of each new sample; ~0.25 at one sample per second
    /// means a sustained change settles in a few seconds.
    static let alpha = 0.25
    /// How far (as a fraction) the average must fall below the threshold to
    /// turn off again.
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

    public var label: String { "CPU above \(thresholdPercent)%" }

    public func isSatisfied() -> Bool {
        state = Self.step(state, sample: reader.currentLoad(), thresholdPercent: thresholdPercent)
        return state.isSatisfied
    }

    /// Pure decision step, exposed for direct unit testing. A `nil` sample
    /// (failed read) keeps the previous average and verdict rather than
    /// dropping an active session on a transient hiccup.
    static func step(_ state: SmoothingState, sample: Double?, thresholdPercent: Int) -> SmoothingState {
        var next = state
        if let sample {
            let clamped = min(max(sample, 0), 1)
            next.average = state.average.map { $0 + alpha * (clamped - $0) } ?? clamped
        }
        guard let average = next.average else {
            next.isSatisfied = false
            return next
        }
        let on = Double(thresholdPercent) / 100
        next.isSatisfied = state.isSatisfied ? average >= on - hysteresis : average >= on
        return next
    }
}
