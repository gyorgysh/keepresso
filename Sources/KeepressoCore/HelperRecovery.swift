import Foundation

/// Presentation follows the existing recovery lifecycle, so a feature call
/// during launchd startup does not look like an exhausted recovery.
public enum HelperRecoveryPhase: Equatable, Sendable {
    case inactive, ready, initializing, updating, needsApproval, unavailable

    public static func resolve(installed: Bool, awaitingApproval: Bool, checking: Bool,
                               outdated: Bool, hasReply: Bool, recoveryPending: Bool,
                               recoveryExhausted: Bool, healthCheckCompleted: Bool = false) -> Self {
        if awaitingApproval { return .needsApproval }
        guard installed else { return .inactive }
        if recoveryExhausted { return .unavailable }
        if outdated { return .updating }
        if checking || recoveryPending { return .initializing }
        if !hasReply { return healthCheckCompleted ? .unavailable : .initializing }
        return .ready
    }

    /// These errors originate in Core, so match its localized messages.
    /// Unrelated feature failures retain their warning presentation.
    public static func isHelperConnectionError(_ message: String) -> Bool {
        message == L("The Keepresso helper isn't responding.")
            || message == L("The Keepresso helper couldn't change the setting.")
    }
}

/// Installation ownership must be shared by registration and update bookkeeping.
/// A development copy must not consume the installed copy's update marker or
/// replace its bookmark, even when it never calls SMAppService itself.
public enum HelperInstallation {
    public static func ownsRegistration(bundleURL: URL, homeURL: URL) -> Bool {
        let parent = bundleURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
        let roots = [URL(fileURLWithPath: "/Applications"), homeURL.appendingPathComponent("Applications")]
        return roots.contains { $0.resolvingSymlinksInPath().standardizedFileURL.path == parent.path }
    }
}

/// Give launchd time to finish an update/restart before changing registration.
/// Any protocol reply proves liveness, including an older daemon waiting to
/// retire. Protocol compatibility is evaluated separately by the caller.
public enum HelperRecoveryProbe {
    /// Quiet waits between post-update settlement pings (30 to 60 seconds,
    /// a few minutes total). After an in-place update the old daemon image
    /// can keep serving with a stale signature until it idles out, while
    /// launchd starts the new binary. Pings during that window prove nothing
    /// about the registration, so the caller waits these out instead of
    /// calling the helper broken.
    public static let postUpdateSettlingDelays: [TimeInterval] = [30, 30, 60, 60]
    @MainActor
    public static func version(
        ping: () async -> Int?,
        wait: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        delays: [TimeInterval] = [0.0, 1.0, 3.0]
    ) async -> Int? {
        for delay in delays {
            guard !Task.isCancelled else { return nil }
            if delay > 0 {
                do { try await wait(delay) } catch is CancellationError { return nil } catch { /* transient sleep failure: still ping */ }
            }
            guard !Task.isCancelled else { return nil }
            if let version = await ping() { return version }
            guard !Task.isCancelled else { return nil }
        }
        return nil
    }
}
