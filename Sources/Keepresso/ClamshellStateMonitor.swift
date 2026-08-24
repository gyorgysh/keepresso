import Foundation
import IOKit
import IOKit.pwr_mgt

// IOPM.h defines this through nested C macros that Swift cannot import:
// iokit_family_msg(sub_iokit_powermanagement, 0x100).
private let clamshellStateChangeMessage = UInt32((0x38 << 26) | (13 << 14) | 0x100)

/// Delivers lid transitions before IOPMrootDomain starts display sleep.
@MainActor
final class ClamshellStateMonitor {
    private let onChange: (Bool) -> Void
    private var notificationPort: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    private var rootDomain: io_service_t = 0
    private var notifier: io_object_t = 0

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard notificationPort == nil else { return }
        rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != 0,
              let port = IONotificationPortCreate(kIOMainPortDefault),
              let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue()
        else {
            stop()
            return
        }

        notificationPort = port
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let result = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { refcon, _, messageType, messageArgument in
                guard messageType == clamshellStateChangeMessage,
                      let refcon else { return }
                let bits = messageArgument.map { UInt(bitPattern: $0) } ?? 0
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<ClamshellStateMonitor>
                        .fromOpaque(refcon)
                        .takeUnretainedValue()
                    monitor.onChange(bits & UInt(kClamshellStateBit) != 0)
                }
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &notifier
        )
        if result != KERN_SUCCESS { stop() }
    }

    func stop() {
        if notifier != 0 {
            IOObjectRelease(notifier)
            notifier = 0
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if rootDomain != 0 {
            IOObjectRelease(rootDomain)
            rootDomain = 0
        }
    }
}
