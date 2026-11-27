import Foundation
import KeepressoCore

@MainActor
@Observable
final class AutomationSyncController {
    private let readers: [LocalAutomationReading]
    private(set) var automations: [ScheduledAutomation] = []
    private(set) var lastRefresh: Date?
    @ObservationIgnored private var emptyStreak = 0
    private static let maxEmptyStreak = 2

    init(readers: [LocalAutomationReading] = [
        ClaudeScheduledTasksReader.real(),
        CodexAutomationsReader.real(),
        TokenstatAutomationsReader.real(),
    ]) {
        self.readers = readers
    }

    func refresh() {
        var all: [ScheduledAutomation] = []
        for reader in readers { all.append(contentsOf: reader.automations()) }
        let sorted = all.sorted {
            ($0.source.label, $0.name.localizedLowercase) < ($1.source.label, $1.name.localizedLowercase)
        }
        lastRefresh = Date()
        if AutomationSync.shouldKeepLastKnown(
            newIsEmpty: sorted.isEmpty, hadAutomations: !automations.isEmpty,
            emptyStreak: emptyStreak, maxEmptyStreak: Self.maxEmptyStreak) {
            emptyStreak += 1
            return
        }
        emptyStreak = 0
        automations = sorted
    }
}
