import Foundation

/// User policy for mirroring local Codex automation schedules into Keepresso's
/// unattended wake pipeline. Discovery remains read-only and never exposes an
/// automation prompt.
public struct CodexAutomationSettings: Codable, Equatable, Sendable {
    public static let defaultBundleIdentifier = "com.openai.codex"

    /// Whether active local Codex automations contribute a one-shot system wake.
    public var enabled: Bool
    /// How early the Mac should wake before the nearest scheduled run.
    public var wakeLeadTime: TimeInterval
    /// Maximum time to wait for power, network, and application readiness.
    public var readinessTimeout: TimeInterval
    /// How long after the scheduled run to wait for its first explicit lease.
    public var leaseHandoffTimeout: TimeInterval
    /// Require a usable network route before opening Codex.
    public var requireNetwork: Bool
    /// Refuse to start unattended work unless the Mac is on external power.
    public var requireExternalPower: Bool
    /// When running on battery is allowed, require at least this percentage.
    public var minimumBatteryPercentage: Int?
    /// Application opened after readiness succeeds. Kept configurable for
    /// alternate Codex distributions while defaulting to the official app.
    public var applicationBundleIdentifier: String

    public init(
        enabled: Bool = false,
        wakeLeadTime: TimeInterval = 5 * 60,
        readinessTimeout: TimeInterval = 2 * 60,
        leaseHandoffTimeout: TimeInterval = 10 * 60,
        requireNetwork: Bool = true,
        requireExternalPower: Bool = false,
        minimumBatteryPercentage: Int? = 30,
        applicationBundleIdentifier: String = Self.defaultBundleIdentifier
    ) {
        self.enabled = enabled
        self.wakeLeadTime = Self.clamp(wakeLeadTime, to: 0...(60 * 60))
        self.readinessTimeout = Self.clamp(readinessTimeout, to: 15...(30 * 60))
        self.leaseHandoffTimeout = Self.clamp(leaseHandoffTimeout, to: 60...(2 * 60 * 60))
        self.requireNetwork = requireNetwork
        self.requireExternalPower = requireExternalPower
        self.minimumBatteryPercentage = minimumBatteryPercentage.map {
            min(max($0, 10), 100)
        }
        let trimmed = applicationBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.applicationBundleIdentifier = trimmed.isEmpty ? Self.defaultBundleIdentifier : trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minimumBattery: Int? = if container.contains(.minimumBatteryPercentage) {
            try container.decodeIfPresent(Int.self, forKey: .minimumBatteryPercentage)
        } else {
            30
        }
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            wakeLeadTime: try container.decodeIfPresent(TimeInterval.self, forKey: .wakeLeadTime)
                ?? 5 * 60,
            readinessTimeout: try container.decodeIfPresent(TimeInterval.self, forKey: .readinessTimeout)
                ?? 2 * 60,
            leaseHandoffTimeout: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .leaseHandoffTimeout
            ) ?? 10 * 60,
            requireNetwork: try container.decodeIfPresent(Bool.self, forKey: .requireNetwork) ?? true,
            requireExternalPower: try container.decodeIfPresent(
                Bool.self,
                forKey: .requireExternalPower
            ) ?? false,
            minimumBatteryPercentage: minimumBattery,
            applicationBundleIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .applicationBundleIdentifier
            ) ?? Self.defaultBundleIdentifier
        )
    }

    private static func clamp(
        _ value: TimeInterval,
        to range: ClosedRange<TimeInterval>
    ) -> TimeInterval {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    public static let `default` = CodexAutomationSettings()
}
