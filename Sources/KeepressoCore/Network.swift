import Foundation
import CoreWLAN

/// A point-in-time reading of the Wi-Fi association.
public struct NetworkSnapshot: Equatable, Sendable {
    /// The SSID currently joined, or `nil` when not associated to Wi-Fi.
    ///
    /// On recent macOS, reading the SSID requires Location Services permission;
    /// without it the system returns `nil` even while connected.
    public var ssid: String?

    public init(ssid: String?) {
        self.ssid = ssid
    }

    /// Whether currently associated to a Wi-Fi network with a readable SSID.
    public var isAssociated: Bool { ssid != nil }
}

/// Abstraction over the current Wi-Fi association so SSID triggers can be tested
/// without a radio. Mirrors the ``PowerSourceMonitoring`` seam.
public protocol NetworkMonitoring: AnyObject {
    var current: NetworkSnapshot { get }
}

/// Real backend over CoreWLAN's default interface.
public final class CoreWLANNetworkMonitor: NetworkMonitoring {
    public init() {}

    public var current: NetworkSnapshot {
        let interface = CWWiFiClient.shared().interface()
        return NetworkSnapshot(ssid: interface?.ssid())
    }
}
