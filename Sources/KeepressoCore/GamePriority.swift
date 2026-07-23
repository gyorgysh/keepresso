import Foundation
import Observation

/// Raises the frontmost game's CPU priority through the administrator helper
/// while a gaming bout runs, and restores it afterward. The point is smoother
/// frames when background work (builds, backups, agent sessions) competes for
/// cores, and it applies equally to streaming clients like Parsec, which are
/// detected as games.
///
/// Mirrors ``AWDLWatchdogController``'s auto shape: the boost engages on the
/// raw, ungraced "a game is frontmost right now" signal, so the boosted pid
/// really is the game and never Discord during an alt-tab. It holds through
/// the bout's grace window and releases when the bout ends, the toggle turns
/// off, or the app quits (connection-scoped in the daemon). One pid per bout:
/// switching games mid-bout keeps the first until the bout ends.
@MainActor
@Observable
public final class GamePriorityController {
    /// The Setup screen's toggle. Turning it off mid-bout releases the boost
    /// immediately (the tick won't, it early-returns once the feature is off).
    public var autoWithGaming = false {
        didSet {
            if !autoWithGaming { releaseNow() }
        }
    }

    /// The pid currently boosted, or nil. Drives the Setup screen's caption.
    public private(set) var boostedPID: Int?

    /// Applies or releases the hold. The app wires the helper's XPC client
    /// behind a detached task; tests inject a recorder.
    private let hold: (_ holding: Bool, _ pid: Int) -> Void

    public init(hold: @escaping (_ holding: Bool, _ pid: Int) -> Void) {
        self.hold = hold
    }

    /// One 1 Hz pulse from the app's gaming watcher.
    /// - Parameters:
    ///   - gameFrontmost: the raw, ungraced "a game is frontmost" reading.
    ///   - gamingActive: the graced bout signal (true while alt-tabbed too).
    ///   - frontmostPID: the frontmost app's pid, meaningful with `gameFrontmost`.
    public func autoTick(gameFrontmost: Bool, gamingActive: Bool, frontmostPID: Int32?) {
        guard autoWithGaming else { return }
        if boostedPID == nil, gameFrontmost, let pid = frontmostPID, pid > 0 {
            boostedPID = Int(pid)
            hold(true, Int(pid))
        } else if let pid = boostedPID, !gamingActive {
            boostedPID = nil
            hold(false, pid)
        }
    }

    private func releaseNow() {
        guard let pid = boostedPID else { return }
        boostedPID = nil
        hold(false, pid)
    }
}
