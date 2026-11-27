import Foundation

/// Discovers Claude Desktop's *local* scheduled tasks so Keepresso can wake for
/// them. Claude Desktop offers two kinds of routine: **Cloud** ones run on
/// Anthropic's servers with the lid shut (nothing to wake for), and **Local**
/// ones run on this Mac and are skipped if it sleeps through the time. Only the
/// local ones are stored on disk, and only they are returned here.
///
/// The store is a JSON manifest Claude Desktop maintains:
///
///     ~/Library/Application Support/Claude/claude-code-sessions/<a>/<b>/scheduled-tasks.json
///     { "scheduledTasks": [
///         { "id": "daily-brief", "cronExpression": "0 9 * * *", "enabled": true, ... } ] }
///
/// The manifest lives under a session subdirectory whose id isn't stable, so the
/// real reader globs every `claude-code-sessions/*/*/scheduled-tasks.json` and
/// unions them. Only `id`, `cronExpression`, and `enabled` are read; the task's
/// prompt (a sibling `SKILL.md`) is never touched.
public struct ClaudeScheduledTasksReader: LocalAutomationReading {
    private let loadManifests: @Sendable () -> [Data]

    public init(loadManifests: @escaping @Sendable () -> [Data]) {
        self.loadManifests = loadManifests
    }

    public func automations() -> [ScheduledAutomation] {
        var byID: [String: ScheduledAutomation] = [:]
        let decoder = JSONDecoder()
        for data in loadManifests() {
            guard let manifest = try? decoder.decode(Manifest.self, from: data) else { continue }
            for task in manifest.scheduledTasks {
                guard let cronText = task.cronExpression, let cron = CronExpression(cronText) else { continue }
                let automation = ScheduledAutomation(
                    source: .claudeDesktop,
                    key: task.id,
                    name: Self.displayName(from: task.id),
                    recurrence: .cron(cron),
                    enabled: task.enabled ?? true
                )
                if let existing = byID[automation.id], existing.enabled, !automation.enabled { continue }
                byID[automation.id] = automation
            }
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func displayName(from id: String) -> String {
        let words = id.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard !words.isEmpty else { return id }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private struct Manifest: Decodable {
        let scheduledTasks: [Task]
        private enum CodingKeys: String, CodingKey { case scheduledTasks }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var tasks: [Task] = []
            if var array = try? c.nestedUnkeyedContainer(forKey: .scheduledTasks) {
                while !array.isAtEnd {
                    let before = array.currentIndex
                    if let task = try? array.decode(Task.self) {
                        tasks.append(task)
                    } else {
                        _ = try? array.decode(DiscardedTask.self)
                    }
                    if array.currentIndex == before { break }
                }
            }
            scheduledTasks = tasks
        }
    }

    private struct Task: Decodable {
        let id: String
        let cronExpression: String?
        let enabled: Bool?
    }

    private struct DiscardedTask: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

public extension ClaudeScheduledTasksReader {
    static func real(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeScheduledTasksReader {
        let base = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        return ClaudeScheduledTasksReader {
            let fm = FileManager.default
            guard let sessionDirs = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil) else { return [] }
            var manifests: [Data] = []
            for sessionDir in sessionDirs {
                guard let subDirs = try? fm.contentsOfDirectory(
                    at: sessionDir, includingPropertiesForKeys: nil) else { continue }
                for sub in subDirs {
                    let manifest = sub.appendingPathComponent("scheduled-tasks.json")
                    if let data = try? Data(contentsOf: manifest) { manifests.append(data) }
                }
            }
            return manifests
        }
    }
}
