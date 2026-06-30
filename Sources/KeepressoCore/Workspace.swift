import Foundation
import AppKit

/// A point-in-time reading of which apps are running.
public struct WorkspaceSnapshot: Equatable, Sendable {
    /// Bundle identifiers of every currently running application.
    public var runningBundleIDs: Set<String>
    /// Bundle identifier of the frontmost app, if any (for future v0.3 use).
    public var frontmostBundleID: String?

    public init(runningBundleIDs: Set<String>, frontmostBundleID: String? = nil) {
        self.runningBundleIDs = runningBundleIDs
        self.frontmostBundleID = frontmostBundleID
    }
}

/// Abstraction over the running-application list so app triggers can be tested
/// without launching anything. Mirrors the ``PowerSourceMonitoring`` seam.
public protocol WorkspaceMonitoring: AnyObject {
    var current: WorkspaceSnapshot { get }
}

/// Real backend over `NSWorkspace.runningApplications`.
///
/// AppKit (not SwiftUI) — `KeepressoCore` stays UI-free; this is just process
/// introspection.
public final class NSWorkspaceMonitor: WorkspaceMonitoring {
    public init() {}

    public var current: WorkspaceSnapshot {
        let workspace = NSWorkspace.shared
        let ids = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        return WorkspaceSnapshot(
            runningBundleIDs: ids,
            frontmostBundleID: workspace.frontmostApplication?.bundleIdentifier
        )
    }
}
