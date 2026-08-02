import Foundation
import AppKit

/// A point-in-time reading of which apps are running.
public struct WorkspaceSnapshot: Equatable, Sendable {
    /// Bundle identifiers of every currently running application.
    public var runningBundleIDs: Set<String>
    /// Bundle path → bundle ID for each running app that has both.
    /// Path-locked app triggers match a single install here, not independent
    /// set membership of paths and IDs. Paths use `standardizedFileURL.path`,
    /// the same form as ``AppRule/bundlePath``.
    public var runningInstalls: [String: String]
    /// Bundle identifier of the frontmost app, if any (for future v0.3 use).
    public var frontmostBundleID: String?
    /// Bundle path of the frontmost app, if any.
    public var frontmostBundlePath: String?

    public init(
        runningBundleIDs: Set<String>,
        runningInstalls: [String: String] = [:],
        frontmostBundleID: String? = nil,
        frontmostBundlePath: String? = nil
    ) {
        self.runningBundleIDs = runningBundleIDs
        self.runningInstalls = runningInstalls
        self.frontmostBundleID = frontmostBundleID
        self.frontmostBundlePath = frontmostBundlePath
    }
}

/// Abstraction over the running-application list so app triggers can be tested
/// without launching anything. Mirrors the ``PowerSourceMonitoring`` seam.
public protocol WorkspaceMonitoring: AnyObject {
    var current: WorkspaceSnapshot { get }
}

/// Real backend over `NSWorkspace.runningApplications`.
///
/// AppKit (not SwiftUI), `KeepressoCore` stays UI-free; this is just process
/// introspection.
public final class NSWorkspaceMonitor: WorkspaceMonitoring {
    public init() {}

    public var current: WorkspaceSnapshot {
        let workspace = NSWorkspace.shared
        var ids = Set<String>()
        var installs: [String: String] = [:]
        for app in workspace.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            ids.insert(id)
            if let path = app.bundleURL?.standardizedFileURL.path {
                installs[path] = id
            }
        }
        return WorkspaceSnapshot(
            runningBundleIDs: ids,
            runningInstalls: installs,
            frontmostBundleID: workspace.frontmostApplication?.bundleIdentifier,
            frontmostBundlePath: workspace.frontmostApplication?.bundleURL?.standardizedFileURL.path
        )
    }
}
