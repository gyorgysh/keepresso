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
final class StatusItemBridge: NSObject, NSMenuDelegate {
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
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
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick else {
            // A missed menuDidClose would leave the swapped-in menu hijacking
            // left clicks; clear it defensively on the way through.
            if event.type == .leftMouseDown, let item = statusItem, item.menu != nil,
               event.window === item.button?.window {
                item.menu = nil
            }
            return event
        }
        guard let item = resolveStatusItem(), let button = item.button,
              event.window === button.window
        else { return event }
        showContextMenu(from: item)
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

    /// Swap the menu in and click the button so AppKit runs its native status
    /// item tracking (highlight, screen-edge placement); ``menuDidClose(_:)``
    /// swaps it back out so the next left click opens the panel again.
    private func showContextMenu(from item: NSStatusItem) {
        if let panel = panelWindow, panel.isVisible { panel.close() }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Next runloop turn: clearing during the callback glitches tracking.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    /// Rebuilt on every open, so "Check for Updates…" reflects the updater's
    /// live state without any validation machinery. Mirrors the entries at the
    /// bottom of the panel; titles go through `L(...)` because AppKit menus
    /// don't localize themselves the way SwiftUI text does.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(entry(L("Preferences…"), #selector(openPreferences), key: ","))
        menu.addItem(entry(L("Headless Setup…"), #selector(openSetup)))
        menu.addItem(entry(L("Gaming & Streaming…"), #selector(openStreaming)))
        menu.addItem(entry(L("About Keepresso"), #selector(openAbout)))
        let check = entry(L("Check for Updates…"), #selector(checkForUpdates))
        check.isEnabled = updater.canCheckForUpdates
        menu.addItem(check)
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
    @objc private func openAbout() { open(KeepressoApp.aboutWindowID) }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Hands the panel's `NSWindow` to the bridge, following the `PanelKeyAssert`
/// precedent in Theme.swift. `MenuBarExtra` builds the panel content lazily on
/// each open, so this re-registers every time and the bridge's weak reference
/// stays current.
struct PanelWindowRegistrar: NSViewRepresentable {
    let register: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            register(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
