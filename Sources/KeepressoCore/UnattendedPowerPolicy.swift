import Foundation

/// Privacy and shutdown behavior for work started by a scheduled wake or an
/// explicit unattended Agent job. It is separate from manual session settings
/// so background automation can be secure by default without surprising an
/// interactive user.
public struct UnattendedPowerPolicy: Codable, Equatable, Sendable {
    /// Lock the login session before launching background work.
    public var lockScreenOnStart: Bool
    /// Turn off the display while keeping system sleep prevented.
    public var sleepDisplayOnStart: Bool
    /// Action to run after the final unattended job or lease ends.
    public var endAction: SessionEndAction

    public init(
        lockScreenOnStart: Bool = true,
        sleepDisplayOnStart: Bool = true,
        endAction: SessionEndAction = .sleepMac
    ) {
        self.lockScreenOnStart = lockScreenOnStart
        self.sleepDisplayOnStart = sleepDisplayOnStart
        self.endAction = endAction
    }

    public static let `default` = UnattendedPowerPolicy()
}
