import AppKit
import SwiftUI

/// Keep both segments the same size so the highlight does not resize as it
/// moves. The native control preserves keyboard and VoiceOver selection.
struct KeepAwakeModePicker: NSViewRepresentable {
    @Binding var manual: Bool
    let title: String
    let automaticTitle: String
    let manualTitle: String
    let accent: NSColor?

    func makeCoordinator() -> Coordinator {
        Coordinator(manual: $manual)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let view = NSSegmentedControl()
        view.segmentCount = 2
        view.segmentDistribution = .fillEqually
        view.trackingMode = .selectOne
        view.target = context.coordinator
        view.action = #selector(Coordinator.selectMode)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let ideal = nsView.fittingSize
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }

    func updateNSView(_ view: NSSegmentedControl, context: Context) {
        context.coordinator.manual = $manual
        if view.label(forSegment: 0) != automaticTitle || view.label(forSegment: 1) != manualTitle {
            view.setLabel(automaticTitle, forSegment: 0)
            view.setLabel(manualTitle, forSegment: 1)
            let font = view.font ?? .systemFont(ofSize: NSFont.systemFontSize(for: view.controlSize))
            let widestLabel = max(
                (automaticTitle as NSString).size(withAttributes: [.font: font]).width,
                (manualTitle as NSString).size(withAttributes: [.font: font]).width
            )
            let width = ceil(widestLabel) + 24
            view.setWidth(width, forSegment: 0)
            view.setWidth(width, forSegment: 1)
        }
        let selection = manual ? 1 : 0
        if view.selectedSegment != selection { view.selectedSegment = selection }
        if view.isEnabled != context.environment.isEnabled { view.isEnabled = context.environment.isEnabled }
        if view.selectedSegmentBezelColor != accent { view.selectedSegmentBezelColor = accent }
        if view.accessibilityLabel() != title { view.setAccessibilityLabel(title) }
    }

    final class Coordinator: NSObject {
        var manual: Binding<Bool>

        init(manual: Binding<Bool>) { self.manual = manual }

        @objc func selectMode(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment == 0 || sender.selectedSegment == 1 else { return }
            let selection = sender.selectedSegment == 1
            if manual.wrappedValue != selection { manual.wrappedValue = selection }
        }
    }
}
