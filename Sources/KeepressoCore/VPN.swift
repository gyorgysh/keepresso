import Foundation

/// Abstraction over "is a VPN connected?" so the VPN trigger can be tested
/// without a real tunnel. Mirrors the other monitor seams.
public protocol VPNMonitoring: AnyObject {
    /// Whether any VPN connection is currently established.
    var isConnected: Bool { get }
}

/// Real backend over `scutil --nc list`, which reports every VPN configuration
/// registered with the system (IKEv2/L2TP profiles and Network Extension
/// tunnels: WireGuard, Tailscale, OpenVPN Connect, most corporate clients) and
/// whether each is connected. Purely CLI tunnels that bypass Network Extension
/// (e.g. `wg-quick`) don't appear here; a process rule covers those.
///
/// Spawning `scutil` is not free and ``isConnected`` is read from the menu's
/// `body` on the main thread, so this reuses ``PSProcessLister``'s
/// stale-while-revalidate shape: return the cached verdict immediately and
/// refresh on a detached task once it goes stale. Never block the main run
/// loop on `Process.waitUntilExit()` (see the crash class documented there).
public final class SCUtilVPNMonitor: VPNMonitoring {
    private let ttl: TimeInterval
    private let now: () -> Date
    /// Produces the raw `scutil --nc list` output (`nil` on failure).
    /// Injectable so the cache and parser can be unit-tested.
    private let fetch: @Sendable () -> String?
    private let lock = NSLock()
    private var cached = false
    private var lastFetch: Date?
    private var isRefreshing = false

    public init(
        ttl: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping @Sendable () -> String? = SCUtilVPNMonitor.runSCUtil
    ) {
        self.ttl = ttl
        self.now = now
        self.fetch = fetch
    }

    public var isConnected: Bool {
        let (snapshot, shouldRefresh) = withLock { () -> (Bool, Bool) in
            let isStale = lastFetch.map { now().timeIntervalSince($0) >= ttl } ?? true
            let shouldRefresh = isStale && !isRefreshing
            if shouldRefresh { isRefreshing = true }
            return (cached, shouldRefresh)
        }

        if shouldRefresh {
            Task.detached { [weak self] in
                guard let self else { return }
                let connected = self.fetch().map(Self.hasConnectedService) ?? false
                self.withLock {
                    self.cached = connected
                    self.lastFetch = self.now()
                    self.isRefreshing = false
                }
            }
        }
        return snapshot
    }

    /// Wraps ``lock`` in a synchronous call so the lock/unlock pair is never
    /// invoked directly from an async context (`NSLock` is `noasync`).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Pure parser: `scutil --nc list` prints one line per configuration with
    /// its state in parentheses, e.g.
    /// `* (Connected)   B49D… IPSec  "Work VPN"  [IPSec]`.
    static func hasConnectedService(in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.contains("(Connected)") }
    }

    /// The real fetch: spawn `scutil --nc list` and return its raw output.
    @Sendable public static func runSCUtil() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--nc", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(decoding: data, as: UTF8.self)
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}

/// Fires while any VPN is connected: a work session is in progress, so the
/// Mac should stay awake.
public final class VPNConnectedTrigger: Trigger {
    private let monitor: VPNMonitoring

    public init(monitor: VPNMonitoring = SCUtilVPNMonitor()) {
        self.monitor = monitor
    }

    public var label: String { "VPN connected" }

    public func isSatisfied() -> Bool { monitor.isConnected }
}
