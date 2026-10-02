// Run from the repository root on macOS:
// swiftc -parse-as-library Sources/Keepresso/WindowVisibility.swift tools/check_window_visibility.swift -o /tmp/keepresso-visibility-check
// /tmp/keepresso-visibility-check
// Uses isolated windows; does not load app settings or operate power controls.

import AppKit
import SwiftUI

// Make occlusion deterministic when this check runs without a frontmost app.
// Ordering and attachment still use real AppKit windows and views.
final class VisibilityWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { isVisible ? [.visible] : [] }
}
@main struct VisibilityCheck {
    @MainActor static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    @MainActor static func main() {
        let _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        for ignoreOcclusion in [false, true] {
            let window = VisibilityWindow(contentRect: NSRect(x: 100,y: 100,width: 200,height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Keepresso visibility regression check"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            drain()
            var values: [Bool] = []
            var probe: WindowVisibilityReader.ReporterView? = WindowVisibilityReader.ReporterView()
            probe!.ignoreOcclusion = ignoreOcclusion
            probe!.onChange = { values.append($0) }
            probe!.probe()
            drain()
            precondition(values.isEmpty, "Unattached probes must not publish a hidden state")
            window.contentView!.addSubview(probe!)
            drain()
            precondition(values.last == true, "Opening must mount content")
            values.removeAll()
            probe!.removeFromSuperview()
            drain()
            precondition(!values.contains(false), "Temporary detachment must not hide a visible window")
            window.contentView!.addSubview(probe!)
            values.removeAll()
            probe!.removeFromSuperview()
            probe = nil
            let replacement = WindowVisibilityReader.ReporterView()
            replacement.ignoreOcclusion = ignoreOcclusion
            replacement.onChange = { values.append($0) }
            window.contentView!.addSubview(replacement)
            drain()
            precondition(!values.contains(false), "Replacing a probe must not hide the replacement tree")
            values.removeAll()
            window.orderOut(nil)
            drain()
            precondition(values.last == false, "Ordered-out windows must unmount content")
            values.removeAll()
            window.makeKeyAndOrderFront(nil)
            drain()
            precondition(values.last == true, "Reopening must mount content")
            values.removeAll()
            window.orderOut(nil)
            window.makeKeyAndOrderFront(nil)
            drain()
            precondition(!values.contains(false), "A deferred hide must not override a rapid reopen")
            values.removeAll()
            window.close()
            drain()
            precondition(values.last == false, "Closing must unmount content")
            print("PASS: transient detach, probe replacement, hide, reopen and close (ignoreOcclusion=\(ignoreOcclusion))")
        }
    }
}
