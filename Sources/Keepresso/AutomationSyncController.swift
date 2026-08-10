import Foundation
import KeepressoCore

/// Discovers local AI automations (Claude Desktop, Codex, tokenstat.ai) and keeps
/// the latest list for the Automations UI and the wake armer. A thin app
/// wrapper over the ``LocalAutomationReading`` seams: every schedule decision
/// lives in Core (``AutomationSync``), this just holds the readers and the
/// discovered list.
@MainActor
@Observable
final class AutomationSyncController {
    private let readers: [LocalAutomationReading]
    /// The most recent discovery across all sources, sorted for display.
    private(set) var automations: [ScheduledAutomation] = []
    /// When discovery last read the sources, for a "checked just now" hint in
    /// the UI. Observed, so the hint updates even when the discovered list is
    /// unchanged. Stamped on every read, including one ridden out by the
    /// empty-streak guard, since we did look at disk either way.
    private(set) var lastRefresh: Date?
    /// Consecutive empty reads while we had automations, so a brief empty patch
    /// (a schedule file mid-rewrite) doesn't immediately drop the list.
    @ObservationIgnored private var emptyStreak = 0
    /// How many consecutive empty reads to ride out before accepting the empty.
    private static let maxEmptyStreak = 2

    init(readers: [LocalAutomationReading] = [
        ClaudeScheduledTasksReader.real(),
        CodexAutomationsReader.real(),
        TokenstatAutomationsReader.real(),
    ]) {
        self.readers = readers
    }

    /// Re-read every source. The stores are a handful of tiny local files, so
    /// this is cheap enough to run on a slow tick and on window appear. Keeps
    /// the last-known list through a brief empty read (a scheduler rewriting a
    /// schedule file), so an armed wake isn't cancelled and a wake handler isn't
    /// made to miss its hold on a transient blip. A genuinely emptied source
    /// still clears after a couple of consecutive empty reads.
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
