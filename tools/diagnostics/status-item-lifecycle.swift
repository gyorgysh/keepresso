// Reproduce macOS status-item scene diagnostics without Keepresso or SwiftUI.
// Build: xcrun swiftc -parse-as-library tools/diagnostics/status-item-lifecycle.swift -o /tmp/status-item-lifecycle
// Run /tmp/status-item-lifecycle create or /tmp/status-item-lifecycle highlight.
// Each run exits after 30 cycles. Inspect unified logs for the printed PID,
// filtering com.apple.FrontBoard and com.apple.BaseBoard. No settings, helpers,
// power assertions, or synthetic mouse/keyboard events are involved.
import AppKit
@MainActor final class Runner {
    var iteration = 0
    var item: NSStatusItem?
    let mode = CommandLine.arguments.dropFirst().first ?? "create"
    func tick() {
        iteration += 1
        if iteration > 30 {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            NSLog("STATUS PROBE completed mode=%@ pid=%d", mode, getpid())
            NSApp.terminate(nil)
            return
        }
        if mode == "create" || item == nil {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.image = NSImage(systemSymbolName: "testtube.2", accessibilityDescription: "Lifecycle probe")
        }
        if mode == "highlight" {
            item?.button?.highlight(true)
            item?.button?.highlight(false)
        }
    }
}
@main struct Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = Runner()
        guard ["create", "highlight"].contains(runner.mode) else {
            fputs("Usage: status-item-lifecycle [create|highlight]\n", stderr)
            exit(2)
        }
        NSLog("STATUS PROBE start mode=%@ pid=%d", runner.mode, getpid())
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { runner.tick() }
        }
        app.run()
        timer.invalidate()
    }
}
