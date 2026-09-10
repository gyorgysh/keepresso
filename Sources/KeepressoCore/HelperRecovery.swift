import Foundation

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
    @MainActor
    public static func version(
        ping: () async -> Int?,
        wait: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async -> Int? {
        for delay in [0.0, 1.0, 3.0] {
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
