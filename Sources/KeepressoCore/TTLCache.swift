import Foundation

/// A small time-boxed cache: holds one probed value for `ttl` seconds, then
/// recomputes on the first read after it lapses. The monitor seams
/// (``IOBluetoothDeviceMonitor``, ``CoreMediaActivityMonitor``,
/// ``WorkspaceGamingMonitor``, ``HostCPULoadReader``) all evaluate from both the
/// trigger engine and the menu's live rule list within the same tick, and a
/// heavier probe (a HAL sweep, a pairing-registry walk, an Info.plist load, a
/// back-to-back tick delta) shouldn't run twice for that. Each monitor used to
/// carry its own copy of this logic; they now share this one.
///
/// Not thread-safe: the monitors are driven from the main actor. The clock is
/// injectable so the TTL can be unit-tested without waiting on real time.
/// Public because app-side monitor backends (the thermal sensor reader) share
/// the same read-twice-per-tick shape.
public final class TTLCache<Value> {
    private let ttl: TimeInterval
    private let now: () -> Date
    private let probe: () -> Value
    private var cached: Value?
    private var cachedAt: Date?

    public init(ttl: TimeInterval, now: @escaping () -> Date = Date.init, probe: @escaping () -> Value) {
        self.ttl = ttl
        self.now = now
        self.probe = probe
    }

    /// The cached value while fresh, otherwise a fresh probe (which is then
    /// cached). A probed `nil` (for an optional `Value`) is a real cached value,
    /// not a cache miss, so it isn't re-probed until the TTL lapses.
    public var current: Value {
        if let cached, let cachedAt, now().timeIntervalSince(cachedAt) < ttl {
            return cached
        }
        let value = probe()
        cached = value
        cachedAt = now()
        return value
    }
}
