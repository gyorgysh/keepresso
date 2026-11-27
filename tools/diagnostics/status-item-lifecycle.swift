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
