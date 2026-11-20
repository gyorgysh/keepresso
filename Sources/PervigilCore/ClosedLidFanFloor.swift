import Foundation
import Observation

/// Independent from heat escalation. The daemon combines connection-scoped fan
/// requests by maximum, so a heat boost can raise this floor and releasing it
/// returns to the floor without changing any thermal settings.
public enum ClosedLidFanFloor {
    public static let defaultPercent = 50
    public static let percentRange = 10...100
    public static func clampedPercent(_ percent: Int) -> Int { min(100, max(10, percent)) }
    public static func requestedPercent(_ percent: Int?, armed: Bool, supported: Bool) -> Int? {
        guard armed, supported, let percent else { return nil }
        return clampedPercent(percent)
    }
}

@MainActor @Observable
public final class ClosedLidFanFloorController {
    public private(set) var holdingPercent: Int?
    public private(set) var requestedPercent: Int?
    public private(set) var busy = false
    public private(set) var failed = false
    public private(set) var suspended = false
    @ObservationIgnored private let helper: PrivilegedHelperCalling
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var previousBase: Int?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var lastDropCheck: Date?

    public init(helper: PrivilegedHelperCalling) { self.helper = helper }
    /// Explicit helper replacement starts a fresh firmware attempt. Ordinary
    /// health checks do not clear a floor suspended after rejected fan writes.
    public func resumeAfterHelperReplacement() {
        previousBase = nil
        holdingPercent = nil
    }
    public func tick(percent: Int?, armed: Bool, supported: Bool, now: Date = Date()) {
        guard !stopping else { return }
        let base = ClosedLidFanFloor.requestedPercent(percent, armed: armed, supported: supported)
        if base != previousBase {
            previousBase = base; suspended = false; failed = false
        }
        guard !busy else { return }
        let desired = suspended ? nil : base
        if requestedPercent != nil, desired == requestedPercent, !suspended,
           lastDropCheck.map({ now.timeIntervalSince($0) >= 3 }) ?? true {
            lastDropCheck = now; busy = true
            activeTask = Task { [helper] in
                defer { activeTask = nil }
                let dropped = await Task.detached { helper.fanHoldDropped() }.value
                if dropped == true && previousBase == base {
                    suspended = true; failed = true; holdingPercent = nil
                }
                busy = false
            }
            return
        }
        guard desired != requestedPercent || (desired != nil && holdingPercent == nil && !suspended)
                || (failed && !suspended && desired != nil) else { return }
        if desired != nil, failed, let lastAttempt, now.timeIntervalSince(lastAttempt) < 15 { return }
        lastAttempt = now; busy = true
        activeTask = Task { [helper] in
            defer { activeTask = nil }
            let ok = await Task.detached { helper.setFanHold(desired != nil, percent: desired ?? 0) }.value
            if ok {
                requestedPercent = desired; holdingPercent = desired
                failed = suspended
            } else {
                // A failed engage can still leave a daemon holder that its timer retries.
                // Keep the request accounted for so turning the option off releases it.
                if desired != nil { requestedPercent = desired }
                holdingPercent = nil; failed = true
            }
            busy = false
        }
    }
    public func stopAndWait() async {
        stopping = true; suspended = true
        defer { stopping = false }
        await activeTask?.value
        guard requestedPercent != nil else { return }
        let ok = await Task.detached { [helper] in helper.setFanHold(false, percent: 0) }.value
        if ok { requestedPercent = nil; holdingPercent = nil }
        failed = !ok
    }

}
