import SwiftUI
import AppKit
import KeepressoCore

/// The headless-readiness Setup screen (v0.6): probes the system for the
/// settings an always-on, headless Mac needs and shows each as ✅ / ⚠️ / 💡 / ❔
/// with a deep link to the right System Settings pane and/or a copyable command.
///
/// Read-only by design: Keepresso never mutates system state (most of these are
/// admin-only and we ship unsandboxed but unprivileged), so this validates and
/// guides rather than changing anything.
struct SetupView: View {
    @Bindable var model: AppModel
    /// Closed Setup windows stay alive on current macOS; unmount the checklist
    /// while off screen so it stops observing AppModel. Starts false so a
    /// retained ordered-out scene does not mount until a visibility probe.
    @State private var windowVisible = false

    private var checks: [ReadinessCheck] { model.readiness.checks }

    var body: some View {
        Group {
            if windowVisible {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(checks) { check in
                                CheckRow(check: check)
                            }
                        }
                        .padding(16)
                    }
                    .scrollContentBackground(.hidden)
                }
                .onAppear { model.refreshReadiness() }
            } else {
                Color.clear
            }
        }
        .frame(width: 460, height: 520)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        .centersAndFrontsWindow()
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .onChange(of: windowVisible) { _, visible in
            if visible { model.refreshReadiness() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Headless Setup")
                    .font(.title2.bold())
                Text("Checks an always-on Mac (e.g. a headless Mac mini) needs. Keepresso can read these but can't change the system ones, so use the links and commands below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                model.refreshReadiness()
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
        }
        .padding(16)
    }
}
