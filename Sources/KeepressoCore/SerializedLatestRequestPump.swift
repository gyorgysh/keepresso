/// Pure single-flight coordinator for blocking work where only the newest
/// pending value matters. The host starts the request returned by `submit`,
/// then calls `complete` exactly once. A completion may return the newest
/// queued request, but never exposes two current requests at the same time.
public struct SerializedLatestRequestPump<Value: Equatable & Sendable>: Sendable {
    public struct Request: Equatable, Sendable {
        public var revision: UInt64
        public var value: Value
        public var retryAttempt: Int

        fileprivate init(revision: UInt64, value: Value, retryAttempt: Int) {
            self.revision = revision
            self.value = value
            self.retryAttempt = retryAttempt
        }
    }

    public struct Completion: Equatable, Sendable {
        public var wasLatest: Bool
        public var next: Request?
    }

    public private(set) var latestRevision: UInt64 = 0
    public private(set) var current: Request?
    public private(set) var pending: Request?

    public init() {}

    public var isIdle: Bool { current == nil && pending == nil }

    /// Submit a desired value. When idle, returns the request the host should
    /// start. While busy, replaces the one pending slot and returns nil.
    /// Identical current or pending work is coalesced.
    @discardableResult
    public mutating func submit(_ value: Value, retryAttempt: Int = 0) -> Request? {
        if pending?.value == value { return nil }
        if pending == nil, current?.value == value { return nil }
        latestRevision &+= 1
        let request = Request(
            revision: latestRevision,
            value: value,
            retryAttempt: retryAttempt
        )
        guard current == nil else {
            pending = request
            return nil
        }
        current = request
        return request
    }

    /// Finish the exact current request. A stale or duplicate completion is
    /// ignored. When newer work exists, it atomically becomes current and is
    /// returned to the host for immediate start.
    public mutating func complete(_ request: Request) -> Completion? {
        guard current?.revision == request.revision else { return nil }
        current = nil
        if let next = pending {
            pending = nil
            current = next
            return Completion(wasLatest: false, next: next)
        }
        return Completion(
            wasLatest: request.revision == latestRevision,
            next: nil
        )
    }
}

/// Coalesces forced reruns while one asynchronous refresh is in flight. A
/// regular request may be skipped, but a forced request is remembered until
/// `finish` hands it back to the host.
public struct CoalescedForceRunGate: Equatable, Sendable {
    public private(set) var isRunning = false
    private var forcedRerunPending = false

    public init() {}

    public mutating func begin(force: Bool) -> Bool {
        guard !isRunning else {
            forcedRerunPending = forcedRerunPending || force
            return false
        }
        isRunning = true
        return true
    }

    /// Ends the current run and returns whether a forced request arrived
    /// during it. The host can immediately begin another forced run.
    public mutating func finish() -> Bool {
        guard isRunning else { return false }
        isRunning = false
        let rerun = forcedRerunPending
        forcedRerunPending = false
        return rerun
    }
}
