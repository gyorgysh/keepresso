import Foundation
import AppKit

/// A point-in-time reading of which apps are running.
public struct WorkspaceSnapshot: Equatable, Sendable {
    /// Bundle identifiers of every currently running application.
    public var runningBundleIDs: Set<String>
    /// Bundle paths of every currently running application. Unlike bundle IDs,
    /// these distinguish side-by-side installs such as Xcode and Xcode Beta.
    public var runningBundlePaths: Set<String>
    /// Bundle identifier of the frontmost app, if any (for future v0.3 use).
    public var frontmostBundleID: String?
    /// Bundle path of the frontmost app, if any.
    public var frontmostBundlePath: String?

    public init(
        runningBundleIDs: Set<String>,
        runningBundlePaths: Set<String> = [],
        frontmostBundleID: String? = nil,
        frontmostBundlePath: String? = nil
    ) {
        self.runningBundleIDs = runningBundleIDs
        self.runningBundlePaths = runningBundlePaths
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
        let ids = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        let paths = Set(workspace.runningApplications.compactMap { $0.bundleURL?.path })
        return WorkspaceSnapshot(
            runningBundleIDs: ids,
            runningBundlePaths: paths,
            frontmostBundleID: workspace.frontmostApplication?.bundleIdentifier,
            frontmostBundlePath: workspace.frontmostApplication?.bundleURL?.path
        )
    }
}
