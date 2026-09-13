import AppKit
import SwiftUI

/// Right-click (or control-click) on the menu-bar icon shows a native context
/// menu with the app entries, while left click keeps opening the SwiftUI panel
/// (issue #1). SwiftUI's `MenuBarExtra` owns its `NSStatusItem` internally and
/// exposes no right-click hook, so this bridge watches the app's own mouse
/// events and reaches the status item by introspection. Every reach-in is
/// guarded: if AppKit ever renames what the introspection relies on, the
/// handler returns the event untouched and a right-click simply opens the
/// panel, exactly as before this feature.
@MainActor
final class StatusItemBridge: NSObject {
    /// Opens one of the app's window scenes by id. Injected from the always
    /// alive menu-bar label view, because `openWindow` only exists in SwiftUI.
    var openWindow: ((String) -> Void)?

    /// The `.window`-style panel, registered by ``PanelWindowRegistrar`` each
    /// time it opens, so a right-click can dismiss it before the menu shows
    /// (the two must never stack).
    weak var panelWindow: NSWindow?

    private let updater: any Updating
    private var monitor: Any?
    private weak var statusItem: NSStatusItem?
    private var contextMouseUp: NSEvent.EventType?

    init(updater: any Updating) {
        self.updater = updater
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Install the event watch, once, at launch. Detection is a local monitor
    /// rather than a swap of the status button's target/action, so SwiftUI's
    /// own wiring is never touched and left clicks pass through by
    /// construction. The status item itself is resolved lazily on the first
    /// context click, when its window provably exists.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .rightMouseUp, .leftMouseUp]) { [weak self] event in
            // Local monitors always fire on the main thread; assumeIsolated
            // only tells the compiler so, it doesn't hop. The result rides a
            // captured local because NSEvent isn't Sendable and assumeIsolated
            // insists its return value is.
            var result: NSEvent? = event
            MainActor.assumeIsolated {
                guard let self else { return }
                result = self.handle(event)
            }
            return result
        }
    }

    /// Returns the event for AppKit to deliver as usual, or `nil` to consume
    /// it (a context click on our icon: the panel must not also toggle).
    private func handle(_ event: NSEvent) -> NSEvent? {
        // Consume the complete gesture. A mouse-up delivered without its
        // mouse-down can still toggle MenuBarExtra on macOS 27. Show the menu
        // on release so its nested tracking loop cannot swallow that release.
        if event.type == contextMouseUp {
            contextMouseUp = nil
            guard let item = resolveStatusItem(), event.window === item.button?.window else {
                // Press on the icon, release elsewhere (or a stray mouse-up
                // while armed): let the other window have its release.
                return event
            }
            showContextMenu(from: item)
            return nil
        }
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick,
              let item = resolveStatusItem(), let button = item.button,
              event.window === button.window
        else { return event }
        contextMouseUp = event.type == .rightMouseDown ? .rightMouseUp : .leftMouseUp
        if let panel = panelWindow, panel.isVisible { panel.close() }
        return nil
    }

    /// Find our status item behind `MenuBarExtra`: the app's only
    /// `NSStatusBarWindow`, whose `statusItem` property AppKit has kept stable
    /// across releases. Both names are private, hence the guards; a miss means
    /// the feature is silently absent, never a crash.
    private func resolveStatusItem() -> NSStatusItem? {
        if let statusItem { return statusItem }
        for window in NSApp.windows where window.className == "NSStatusBarWindow" {
            guard window.responds(to: NSSelectorFromString("statusItem")),
                  let item = window.value(forKey: "statusItem") as? NSStatusItem
            else { continue }
            statusItem = item
            return item
        }
        return nil
    }

    /// Present the menu directly. Sending performClick to SwiftUI's button
    /// can invoke its panel action as well as menu tracking on macOS 27.
    private func showContextMenu(from item: NSStatusItem) {
        guard let button = item.button else { return }
        if let panel = panelWindow, panel.isVisible { panel.close() }
        let menu = buildMenu()
        button.highlight(true)
        defer { button.highlight(false) }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: button.bounds.minX, y: button.bounds.minY),
                   in: button)
    }

    /// Rebuilt on every open, so "Check for Updates…" reflects the updater's
    /// live state without any validation machinery. Mirrors the entries at the
    /// bottom of the panel; titles go through `L(...)` because AppKit menus
    /// don't localize themselves the way SwiftUI text does.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(entry(L("Preferences…"), #selector(openPreferences), key: ","))
        let tools = NSMenuItem(title: L("Tools"), action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu()
        toolsMenu.addItem(entry(L("Headless Setup…"), #selector(openSetup)))
        toolsMenu.addItem(entry(L("Gaming & Streaming…"), #selector(openStreaming)))
        toolsMenu.addItem(entry(L("Keyboard Cleaner…"), #selector(openKeyboardCleaner)))
        toolsMenu.addItem(entry(L("Public Wi-Fi…"), #selector(openWifiAssistant)))
        tools.submenu = toolsMenu
        menu.addItem(tools)
        let help = NSMenuItem(title: L("Help"), action: nil, keyEquivalent: "")
        let helpMenu = NSMenu()
        helpMenu.addItem(entry(L("Welcome to Keepresso…"), #selector(openWelcome)))
        helpMenu.addItem(entry(L("About Keepresso"), #selector(openAbout)))
        let check = entry(L("Check for Updates…"), #selector(checkForUpdates))
        check.isEnabled = updater.canCheckForUpdates
        helpMenu.addItem(check)
        helpMenu.addItem(entry(L("Support Keepresso…"), #selector(openDonate)))
        help.submenu = helpMenu
        menu.addItem(help)
        menu.addItem(.separator())
        menu.addItem(entry(L("Quit Keepresso"), #selector(quit), key: "q"))
        return menu
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Mirrors `MenuBarContent.open(_:)` minus the panel close (done before
    /// the menu showed): activate first, or the LSUIElement agent's new window
    /// comes up behind and drawn inactive.
    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id)
    }

    @objc private func openPreferences() { open(KeepressoApp.preferencesWindowID) }
    @objc private func openSetup() { open(KeepressoApp.setupWindowID) }
    @objc private func openStreaming() { open(KeepressoApp.streamingWindowID) }
    @objc private func openKeyboardCleaner() { open(KeepressoApp.keyboardCleanerWindowID) }
    @objc private func openWifiAssistant() { open(KeepressoApp.wifiAssistantWindowID) }
    @objc private func openWelcome() { open(KeepressoApp.welcomeWindowID) }
    @objc private func openAbout() { open(KeepressoApp.aboutWindowID) }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    @objc private func openDonate() { NSWorkspace.shared.open(AppInfo.donate) }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Tracks the panel's actual window attachment, including delayed attachment
/// and replacement when SwiftUI rebuilds its MenuBarExtra content.
struct PanelWindowRegistrar: NSViewRepresentable {
    let register: (NSWindow?) -> Void

    final class RegistrationView: NSView {
        var register: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register?(window)
        }
    }

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.register = register
        return view
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.register = register
        // viewDidMoveToWindow owns attach/detach; only re-affirm a live
        // attachment here so a state-driven update while detached can't nil
        // out a valid panelWindow.
        if let window = nsView.window { register(window) }
    }
}
