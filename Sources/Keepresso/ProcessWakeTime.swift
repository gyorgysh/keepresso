import Darwin

enum ProcessWakeTime {
    /// Unlike a workspace notification, this changes as soon as the kernel
    /// wakes. It also covers sleep that occurred entirely between two ticks.
    static func read() -> UInt64? {
        var time: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("kern.wake_abs_time", &time, &size, nil, 0) == 0,
              size == MemoryLayout<UInt64>.size else { return nil }
        return time
    }
}
