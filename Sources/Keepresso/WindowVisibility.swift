import SwiftUI
import AppKit

/// Reports whether the host window is actually on screen, tracking AppKit's
/// window occlusion. `MenuBarExtra(.window)` keeps its panel content view alive
/// (and any `TimelineView(.animation)` inside it driving the display link, plus
/// a full window relayout every frame) after the panel closes on current
/// macOS, despite the "content is rebuilt on each open" assumption elsewhere.
/// Gating periodic work (steam, spark frames, the 1 Hz menu tick) on real
/// visibility stops that churn the moment the menu shuts, and does the same
/// for any real window left hidden or minimized.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onChange = { visible in
            // Off the current update pass: occlusion can first resolve while
            // SwiftUI is committing this view, and a synchronous @State write
            // there is disallowed.
            DispatchQueue.main.async { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {}

    /// A zero-size probe that watches its window's occlusion and reports only
    /// on an actual change, so an unchanged state never churns SwiftUI.
    final class ReporterView: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { report(false); return }
            report(window.occlusionState.contains(.visible))
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self, weak window] _ in
                self?.report(window?.occlusionState.contains(.visible) ?? false)
            }
        }

        private func report(_ visible: Bool) {
            guard visible != last else { return }
            last = visible
            onChange?(visible)
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
