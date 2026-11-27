import AppIntents
import KeepressoCore

@MainActor
enum IntentContext {
    static weak var model: AppModel?
}

private enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady

    var localizedStringResource: LocalizedStringResource {
        "Keepresso is still starting up. Try again in a moment."
    }
}

@MainActor
private func intentModel() throws -> AppModel {
    guard let model = IntentContext.model else { throw IntentError.appNotReady }
    return model
}

struct StartKeepingAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Keeping Awake"
    static let description = IntentDescription(
        "Keeps the Mac awake, indefinitely or for a set number of minutes."
    )

    @Parameter(title: "Minutes", description: "Leave empty to keep awake indefinitely.")
    var minutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult {
        let mode: SessionMode = if let minutes, minutes > 0 {
            .timed(duration: TimeInterval(minutes) * 60)
        } else {
            .indefinite
        }
        try intentModel().handle(.start(mode: mode))
        return .result()
    }
}

struct StopKeepingAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Keeping Awake"
    static let description = IntentDescription(
        "Ends the keep-awake session so the Mac can sleep normally."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        try intentModel().handle(.stop)
        return .result()
    }
}

struct ToggleKeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Keep Awake"
    static let description = IntentDescription(
        "Starts a keep-awake session with your default duration, or stops the running one."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        try intentModel().handle(.toggle)
        return .result()
    }
}

struct KeepressoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartKeepingAwakeIntent(),
            phrases: [
                "Start \(.applicationName)",
                "Keep my Mac awake with \(.applicationName)",
            ],
            shortTitle: "Start Keeping Awake",
            systemImageName: "cup.and.saucer.fill"
        )
        AppShortcut(
            intent: StopKeepingAwakeIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "Let my Mac sleep with \(.applicationName)",
            ],
            shortTitle: "Stop Keeping Awake",
            systemImageName: "cup.and.saucer"
        )
    }
}
