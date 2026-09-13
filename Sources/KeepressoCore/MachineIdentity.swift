import Darwin
import Foundation

/// Human device naming for user-facing copy ("your MacBook Pro") plus the
/// power qualifier ("on battery") the quit modal needs. All inputs are plain
/// values so both builders are unit-testable; the host injects the live
/// `hw.model` string and power snapshot.
public enum MachineIdentity {
    /// The `hw.model` identifier of this Mac ("MacBookPro18,3"), or nil when
    /// the sysctl cannot be read.
    public static func currentModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// "your MacBook Pro" for copy. Model families are proper nouns; only
    /// the fallback ("your Mac") exercises localization.
    public static func deviceName(modelIdentifier: String?) -> String {
        L("your %@", familyName(modelIdentifier: modelIdentifier))
    }

    /// "on battery", "on battery at 12%", or nil when plugged in or a
    /// desktop (where the consequence needs no qualifier).
    public static func powerQualifier(_ snapshot: PowerSourceSnapshot) -> String? {
        guard snapshot.hasBattery, !snapshot.isCharging else { return nil }
        if let percentage = snapshot.percentage, percentage < 20 {
            return L("on battery at %d%%", percentage)
        }
        return L("on battery")
    }

    /// Model family proper noun, or "Mac" for unknown identifiers.
    static func familyName(modelIdentifier: String?) -> String {
        guard let modelIdentifier else { return "Mac" }
        if modelIdentifier.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if modelIdentifier.hasPrefix("MacBookAir") { return "MacBook Air" }
        if modelIdentifier.hasPrefix("MacBook") { return "MacBook" }
        if modelIdentifier.hasPrefix("Macmini") { return "Mac mini" }
        if modelIdentifier.hasPrefix("MacStudio") { return "Mac Studio" }
        if modelIdentifier.hasPrefix("MacPro") { return "Mac Pro" }
        if modelIdentifier.hasPrefix("iMac") { return "iMac" }
        return "Mac"
    }
}
