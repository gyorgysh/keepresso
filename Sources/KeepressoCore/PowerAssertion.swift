import Foundation
import IOKit.pwr_mgt

/// Abstraction over the IOKit power-assertion API so the session logic can be
/// unit-tested without touching real kernel assertions.
///
/// An implementation owns at most one assertion *per* ``PowerAssertionKind``.
/// Calling ``apply(_:reason:)`` is idempotent: it reconciles the live
/// assertions to exactly the requested set, creating and releasing as needed.
public protocol PowerAsserting: AnyObject {
    /// Reconcile held assertions to exactly `kinds`. Assertions not in the set
    /// are released; new ones are created with `reason` as their human-readable
    /// name (shown in `pmset -g assertions`).
    func apply(_ kinds: Set<PowerAssertionKind>, reason: String)

    /// Release every held assertion. Equivalent to `apply([], reason:)`.
    func releaseAll()

    /// The kinds currently held. Primarily for diagnostics and tests.
    var held: Set<PowerAssertionKind> { get }
}

public extension PowerAsserting {
    func releaseAll() { apply([], reason: "") }
}

/// The distinct power assertions Keepresso can hold.
public enum PowerAssertionKind: String, CaseIterable, Sendable {
    /// `kIOPMAssertPreventUserIdleSystemSleep`, system stays awake.
    case system
    /// `kIOPMAssertPreventUserIdleDisplaySleep`, display stays awake.
    case display

    var ioKitAssertionType: String {
        switch self {
        case .system: return kIOPMAssertPreventUserIdleSystemSleep
        case .display: return kIOPMAssertPreventUserIdleDisplaySleep
        }
    }
}

/// Real implementation backed by `IOPMAssertionCreateWithName`.
///
/// Not thread-safe by design, drive it from the main actor alongside the
/// owning ``SessionController``.
public final class IOKitPowerAssertionManager: PowerAsserting {
    private var ids: [PowerAssertionKind: IOPMAssertionID] = [:]
    /// Kinds that the last ``apply(_:reason:)`` wanted but could not create.
    public private(set) var lastCreateFailures: Set<PowerAssertionKind> = []

    public init() {}

    deinit { releaseAll() }

    public var held: Set<PowerAssertionKind> { Set(ids.keys) }

    public func apply(_ kinds: Set<PowerAssertionKind>, reason: String) {
        // Release assertions no longer wanted.
        for kind in ids.keys where !kinds.contains(kind) {
            release(kind)
        }
        var failures: Set<PowerAssertionKind> = []
        // Create assertions newly wanted.
        for kind in kinds where ids[kind] == nil {
            if !create(kind, reason: reason.isEmpty ? "Keepresso is brewing" : reason) {
                failures.insert(kind)
            }
        }
        lastCreateFailures = failures
    }

    @discardableResult
    private func create(_ kind: PowerAssertionKind, reason: String) -> Bool {
        var id: IOPMAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kind.ioKitAssertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            ids[kind] = id
            return true
        }
        return false
    }

    private func release(_ kind: PowerAssertionKind) {
        guard let id = ids.removeValue(forKey: kind) else { return }
        IOPMAssertionRelease(id)
    }
}
