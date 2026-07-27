import SwiftUI
import AppKit

/// Reports whether the host window is actually on screen. `MenuBarExtra(.window)`
/// keeps its panel content view alive after the panel closes on current macOS
/// (ordered out, not destroyed). An off-screen tree that still observes
/// `@Observable` models and hosts `TimelineView` will:
/// - drive the display link / layout every frame (tens of percent CPU), and
/// - accumulate SwiftUI Observation nodes on every tick with no plateau.
///
/// Gating animations and, more importantly, unmounting the heavy panel body
/// while this reports false stops both. Real windows (Preferences, etc.) get
/// the same treatment when hidden or minimized.
///
/// Open and close are published asymmetrically: becoming visible is applied
/// immediately (so a reopen remounts content in the same turn AppKit ordered
/// the window on, with no blank shell), while becoming hidden is deferred off
/// the current SwiftUI update pass (a sync `@State` write mid-commit is
/// disallowed, and one extra mounted frame on close is harmless). A deferred
/// close re-checks ``last`` so a later sync open always wins.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {
        // Keep the binding current across SwiftUI identity churn, and re-probe
        // in case the window was ordered out without an occlusion note. When
        // AppKit has already ordered the window on (MenuBarExtra reopen), a
        // synchronous visible=true here remounts content in this layout pass.
        nsView.onChange = { isVisible = $0 }
        nsView.probe()
    }

    /// A zero-size probe that watches its window and reports only on an actual
    /// change, so an unchanged state never churns SwiftUI.
    final class ReporterView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var isVisibleObservation: NSKeyValueObservation?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clearTokens()
            guard let window else {
                report(false)
                return
            }
            probe()
            // MenuBarExtra panels are often ordered out without closing: key
            // alone misses that path, and occlusionState alone is "not
            // meaningful" when the window is not visible (Apple). Combine
            // isVisible with occlusion, and listen on every signal that can
            // flip either. KVO on isVisible catches order-on before the first
            // blank composite when the heavy body was torn down while closed.
            isVisibleObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                self?.probe()
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.willCloseNotification,
            ]
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.probe()
                })
            }
        }

        /// Recompute from the live window. Safe to call often: ``report``
        /// drops duplicates.
        func probe() {
            report(Self.effectivelyVisible(window))
        }

        /// Ordered-out panels can still carry `.visible` in occlusionState;
        /// require AppKit's `isVisible` first, then non-occluded.
        static func effectivelyVisible(_ window: NSWindow?) -> Bool {
            guard let window, window.isVisible else { return false }
            return window.occlusionState.contains(.visible)
        }

        private func report(_ visible: Bool) {
            guard visible != last else { return }
            last = visible
            if visible {
                onChange?(true)
            } else {
                // Defer the binding write: probe often runs during SwiftUI's
                // updateNSView / commit, where a sync false is disallowed. A
                // later sync open flips `last` back to true and this closes
                // as a no-op.
                //
                // Capture `onChange` strongly: during Window close the probe
                // view can be replaced before the async runs. Dropping the
                // false publish would leave a retained Window scene with its
                // heavy body still mounted.
                let notify = onChange
                DispatchQueue.main.async { [weak self] in
                    if let self {
                        guard self.last == false else { return }
                        self.onChange?(false)
                    } else {
                        notify?(false)
                    }
                }
            }
        }

        private func clearTokens() {
            isVisibleObservation?.invalidate()
            isVisibleObservation = nil
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
            tokens.removeAll()
        }

        deinit {
            clearTokens()
        }
    }
}
