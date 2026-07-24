import Foundation
import KeepressoCore

/// Discovers local AI automations (Claude Desktop, Codex) and keeps the latest
/// list for the Automations UI and the wake armer. A thin app wrapper over the
/// ``LocalAutomationReading`` seams: every schedule decision lives in Core
/// (``AutomationSync``), this just holds the readers and the discovered list.
@MainActor
@Observable
final class AutomationSyncController {
    private let readers: [LocalAutomationReading]
    /// The most recent discovery across all sources, sorted for display.
    private(set) var automations: [ScheduledAutomation] = []
    /// When discovery last ran, for a "checked just now" hint in the UI.
    @ObservationIgnored private(set) var lastRefresh: Date?

    init(readers: [LocalAutomationReading] = [
        ClaudeScheduledTasksReader.real(),
        CodexAutomationsReader.real(),
    ]) {
        self.readers = readers
    }

    /// Re-read every source. The stores are a handful of tiny local files, so
    /// this is cheap enough to run on a slow tick and on window appear.
    func refresh() {
        var all: [ScheduledAutomation] = []
        for reader in readers { all.append(contentsOf: reader.automations()) }
        automations = all.sorted {
            ($0.source.label, $0.name.localizedLowercase) < ($1.source.label, $1.name.localizedLowercase)
        }
        lastRefresh = Date()
    }
}
