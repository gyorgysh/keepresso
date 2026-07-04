import AppIntents
import SwiftUI
import WidgetKit
import KeepressoCore

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
/// This process can't touch the app's memory, so everything rides the
/// ``WidgetBridge`` App Group channel: the value provider reads the state the
/// app mirrors on every change, and the toggle's intent writes a command back
/// and rings the Darwin doorbell.
struct KeepAwakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetBridge.controlKind, provider: Provider()) { isOn in
            ControlWidgetToggle(
                "Keep Awake",
                isOn: isOn,
                action: SetKeepAwakeControlIntent()
            ) { on in
                Label(
                    on ? "Brewing" : "Off",
                    systemImage: on ? "cup.and.saucer.fill" : "cup.and.saucer"
                )
            }
        }
        .displayName("Keep Awake")
        .description("Start or stop keeping the Mac awake.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }

        func currentValue() async throws -> Bool {
            guard let defaults = WidgetBridge.groupDefaults() else { return false }
            return WidgetBridge.readState(from: defaults)?.isActive ?? false
        }
    }
}

/// The toggle's intent, run inside the extension process: park the desired
/// state in the App Group, ring the doorbell for a running app, and open the
/// app so a stopped one launches and consumes the command instead.
struct SetKeepAwakeControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Keep Awake"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Keep Awake")
    var value: Bool

    func perform() async throws -> some IntentResult {
        if let defaults = WidgetBridge.groupDefaults() {
            WidgetBridge.writeCommand(desiredActive: value, to: defaults)
        }
        WidgetBridge.postCommandNotification()
        return .result()
    }
}
