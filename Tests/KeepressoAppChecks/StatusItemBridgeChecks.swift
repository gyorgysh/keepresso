// Run with scripts/check-status-item-bridge.sh on macOS 27 or later.
// Minimal collaborators let these checks compile the actual app-side bridge
// without starting Keepresso, Sparkle, or the privileged helper.
import AppKit
@MainActor protocol Updating { var canCheckForUpdates: Bool { get }; var updateAvailable: Bool { get }; func checkForUpdates() }
struct ProbeUpdater: Updating { let canCheckForUpdates = true; let updateAvailable = false; func checkForUpdates() {} }
func L(_ s: String) -> String { s }
enum AppInfo { static let donate = URL(string: "https://example.invalid")! }
enum KeepressoApp {
    static let preferencesWindowID = "preferences", setupWindowID = "setup", streamingWindowID = "streaming", keyboardCleanerWindowID = "keyboard", wifiAssistantWindowID = "wifi", welcomeWindowID = "welcome", aboutWindowID = "about"
}
@available(macOS 27.0, *)
final class SessionSpy: NSStatusItemExpandedInterfaceSession {
    var cancellations = 0
    override func cancel() { cancellations += 1 }
}
@available(macOS 27.0, *)
final class ItemSpy: NSStatusItem {
    var session: NSStatusItemExpandedInterfaceSession?
    override var expandedInterfaceSession: NSStatusItemExpandedInterfaceSession? { session }
}
final class PanelSpy: NSWindow {
    var reportsVisible = true
    var closes = 0
    override var isVisible: Bool { reportsVisible }
    override func close() { closes += 1; reportsVisible = false }
}
@main struct Checks {
    @MainActor static func main() {
        _ = NSApplication.shared
        if #available(macOS 27.0, *) {
            let bridge = StatusItemBridge(updater: ProbeUpdater())
            let item = ItemSpy()
            let session = SessionSpy()
            let panel = PanelSpy(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            bridge.panelWindow = panel
            item.session = session
            bridge.dismissPanel(from: item)
            precondition(session.cancellations == 1 && panel.closes == 0)
            bridge.panelWindow = nil
            bridge.dismissPanel(from: item)
            precondition(session.cancellations == 2) // A detached view still ends tracking.
            item.session = nil
            bridge.panelWindow = panel
            bridge.dismissPanel(from: item)
            precondition(panel.closes == 1)
            bridge.dismissPanel(from: item)
            precondition(panel.closes == 1) // Already hidden: no duplicate close.
            print("PASS: session cancellation, detached panel, legacy fallback, hidden-panel idempotence")
        } else {
            print("SKIP: expanded-interface checks require macOS 27")
        }
    }
}
