import Foundation
import IOKit
import KeepressoCore

enum MacWakeState {
    static func read() -> SessionController.WakeState {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return .unknown }
        defer { IOObjectRelease(root) }
        let capabilities = IORegistryEntryCreateCFProperty(
            root, "System Capabilities" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber
        return .init(systemCapabilities: capabilities?.uint64Value)
    }
}
