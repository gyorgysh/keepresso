import Foundation

/// Abstraction over the machine's overall network throughput so a transfer
/// trigger can be tested with scripted readings. Mirrors ``CPULoadReading``.
public protocol NetworkThroughputReading: AnyObject {
    /// Combined in + out throughput across the physical interfaces since the
    /// previous call, in bytes per second, or `nil` when no reading is available
    /// yet (first call, a failed read, or a counter that went backwards).
    func currentBytesPerSecond() -> Double?
}

/// Friendly rendering of a KB/s threshold, shared by the rule label and the
/// picker so both read the same ("500 KB/s", "1 MB/s").
public enum NetworkThroughput {
    public static func rateLabel(kilobytesPerSecond kb: Int) -> String {
        guard kb >= 1024 else { return "\(kb) KB/s" }
        if kb % 1024 == 0 { return "\(kb / 1024) MB/s" }
        let mb = (Double(kb) / 1024 * 10).rounded() / 10
        return "\(mb) MB/s"
    }
}

/// Real backend over `getifaddrs` interface byte counters. Throughput is the
/// byte delta between consecutive calls divided by the elapsed time, so the
/// first call returns `nil` (a since-boot total would be meaningless here).
///
/// Cached briefly like ``HostCPULoadReader``: the trigger engine and the menu's
/// live rule list both evaluate within the same tick, and a back-to-back delta
/// would be over a meaninglessly tiny interval.
public final class GetifaddrsThroughputReader: NetworkThroughputReading {
    private var previous: (bytes: UInt64, at: Date)?
    private let ttl: TimeInterval
    private let now: () -> Date
    private let readBytes: () -> UInt64?
    /// Built lazily on first read (the probe reads `self`), holding `self`
    /// unowned: the cache and this reader share a lifetime.
    private lazy var cache = TTLCache<Double?>(ttl: ttl, now: now) { [unowned self] in
        self.readThroughputDelta()
    }

    public convenience init() {
        self.init(readBytes: Self.interfaceBytes)
    }

    /// The byte source and clock are injectable so the delta and TTL logic can
    /// be unit-tested without real interface counters.
    init(
        ttl: TimeInterval = 0.5,
        now: @escaping () -> Date = Date.init,
        readBytes: @escaping () -> UInt64?
    ) {
        self.ttl = ttl
        self.now = now
        self.readBytes = readBytes
    }

    public func currentBytesPerSecond() -> Double? { cache.current }

    private func readThroughputDelta() -> Double? {
        guard let bytes = readBytes() else { return nil }
        let at = now()
        defer { previous = (bytes, at) }
        // A backwards counter means an interface reset or a 32-bit wrap (the
        // per-interface counters are 32-bit): skip that one interval rather than
        // report a bogus negative rate. The EMA holds the prior verdict meanwhile.
        guard let previous, bytes >= previous.bytes else { return nil }
        let elapsed = at.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return nil }
        return Double(bytes - previous.bytes) / elapsed
    }

    /// Sum of in + out bytes across every non-loopback interface. Deliberately
    /// sums all of them (physical, VPN, bridge): the goal is a rough "is a large
    /// transfer running" gauge, and the threshold plus hysteresis absorb the
    /// double-counting a tunnel-over-physical setup introduces.
    private static func interfaceBytes() -> UInt64? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var total: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            // Only the link-layer (AF_LINK) row of each interface carries the
            // if_data byte counters.
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            guard let data = entry.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            total += UInt64(stats.ifi_ibytes) + UInt64(stats.ifi_obytes)
        }
        return total
    }
}

/// Fires while overall network throughput sits above a threshold: a large
/// download, upload, or sync is running, so the Mac should stay awake even when
/// no single app or process rule fits.
///
/// Raw per-second throughput is bursty, so the decision runs on an exponential
/// moving average (a brief burst doesn't start a session) with hysteresis (once
/// on, it takes a clear drop below the threshold to turn off, so a transfer
/// hovering at the threshold doesn't flap). The state transition is a pure
/// function (``step(_:sampleBytesPerSecond:thresholdKilobytesPerSecond:)``) for
/// direct unit testing. Mirrors ``CPULoadTrigger``.
public final class NetworkThroughputTrigger: Trigger {
    /// Throughput (in KB/s, 1 KB = 1024 bytes) the smoothed rate must reach.
    public var thresholdKilobytesPerSecond: Int

    /// Smoothing weight of each new sample; ~0.25 at one sample per second means
    /// a sustained transfer settles in a few seconds.
    static let alpha = 0.25
    /// Fraction of the threshold the average must fall below to turn off again.
    /// A relative band (unlike CPU's absolute one) since throughput is unbounded.
    static let releaseFraction = 0.7

    public struct SmoothingState: Equatable, Sendable {
        /// The smoothed rate in bytes per second.
        public var average: Double?
        public var isSatisfied = false
        public init() {}
    }

    private let reader: NetworkThroughputReading
    private var state = SmoothingState()

    public init(thresholdKilobytesPerSecond: Int, reader: NetworkThroughputReading = GetifaddrsThroughputReader()) {
        self.thresholdKilobytesPerSecond = thresholdKilobytesPerSecond
        self.reader = reader
    }

    public var label: String {
        L("Network above %@", NetworkThroughput.rateLabel(kilobytesPerSecond: thresholdKilobytesPerSecond))
    }

    /// Advance the smoothing average by one reading. Done here (not in
    /// ``isSatisfied()``) so the EMA steps exactly once per reconcile even while
    /// the menu's live rule list is reading the trigger (the E6 double-step).
    public func tick() {
        state = Self.step(
            state,
            sampleBytesPerSecond: reader.currentBytesPerSecond(),
            thresholdKilobytesPerSecond: thresholdKilobytesPerSecond
        )
    }

    public func isSatisfied() -> Bool { state.isSatisfied }

    /// Pure decision step, exposed for direct unit testing. A `nil` sample
    /// (failed read / counter wrap) keeps the previous average and verdict
    /// rather than dropping an active session on a transient hiccup.
    static func step(_ state: SmoothingState, sampleBytesPerSecond sample: Double?, thresholdKilobytesPerSecond: Int) -> SmoothingState {
        var next = state
        // A non-positive threshold is malformed (the picker never makes one).
        // Treat it as "never satisfied" instead of the always-true it would
        // otherwise compute (average >= 0), so a corrupt or imported rule can't
        // pin the Mac awake with nothing able to release it.
        guard thresholdKilobytesPerSecond > 0 else {
            next.average = nil
            next.isSatisfied = false
            return next
        }
        if let sample {
            let clamped = max(sample, 0)
            next.average = state.average.map { $0 + alpha * (clamped - $0) } ?? clamped
        }
        guard let average = next.average else {
            next.isSatisfied = false
            return next
        }
        let on = Double(thresholdKilobytesPerSecond) * 1024
        let off = on * releaseFraction
        next.isSatisfied = state.isSatisfied ? average >= off : average >= on
        return next
    }
}
