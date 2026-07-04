import AppIntents
import SwiftUI
import WidgetKit

/// The widget extension's entry point. Holds only the Control Center toggle
/// for now; menu-bar/desktop widgets would join this bundle.
@main
struct KeepressoWidgetBundle: WidgetBundle {
    var body: some Widget {
        KeepAwakeControl()
    }
}

/// A Control Center toggle for the keep-awake session.
///
/// Spike scaffolding: the toggle renders and the intent runs in the extension
/// process, but the shared session state (App Group) and the bridge that
/// drives the app aren't wired yet, so flipping it doesn't reach the app.
struct KeepAwakeControl: ControlWidget {
    static let kind = "sh.gyorgy.keepresso.keep-awake"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetToggle(
                "Keep Awake",
                isOn: false,
                action: SetKeepAwakeControlIntent()
            ) { isOn in
                Label(
                    isOn ? "Brewing" : "Off",
                    systemImage: isOn ? "cup.and.saucer.fill" : "cup.and.saucer"
                )
            }
        }
        .displayName("Keep Awake")
        .description("Start or stop keeping the Mac awake.")
    }
}

/// The toggle's intent, run inside the extension process. It cannot touch the
/// app's memory; the real implementation will write the desired state to the
/// App Group and nudge the app.
struct SetKeepAwakeControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Keep Awake"

    @Parameter(title: "Keep Awake")
    var value: Bool

    func perform() async throws -> some IntentResult {
        // Spike: no-op until the App Group bridge lands.
        .result()
    }
}
