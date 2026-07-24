import Foundation

/// Discovers Codex's *local* automations so Keepresso can wake for them, the
/// counterpart to ``ClaudeScheduledTasksReader``. Codex stores each automation
/// as a small TOML file:
///
///     ~/.codex/automations/<id>/automation.toml
///     id = "weekly-review"
///     name = "Weekly review"
///     status = "ACTIVE"
///     rrule = "RRULE:FREQ=WEEKLY;BYHOUR=16;BYMINUTE=0;BYDAY=FR"
///     execution_environment = "local"
///
/// Only automations whose `execution_environment` is `local` are returned; a
/// cloud automation runs on the vendor's servers with the lid shut, so there is
/// nothing to wake for. The task's `prompt` is present in the file but never
/// read or retained.
public struct CodexAutomationsReader: LocalAutomationReading {
    /// Yields the raw text of each discovered `automation.toml`. Injected so
    /// tests feed TOML directly and the real path globs `~/.codex/automations`.
    private let loadAutomations: @Sendable () -> [String]

    public init(loadAutomations: @escaping @Sendable () -> [String]) {
        self.loadAutomations = loadAutomations
    }

    public func automations() -> [ScheduledAutomation] {
        var byID: [String: ScheduledAutomation] = [:]
        for text in loadAutomations() {
            let fields = Self.parseTOML(text)
            // Local automations only: a cloud one needs no local wake.
            guard (fields["execution_environment"] ?? "local") == "local" else { continue }
            guard let id = fields["id"], !id.isEmpty else { continue }
            guard let ruleText = fields["rrule"], let rule = RecurrenceRule(ruleText) else { continue }
            let automation = ScheduledAutomation(
                source: .codex,
                key: id,
                name: fields["name"] ?? id,
                recurrence: .rrule(rule),
                // Codex marks a paused automation with a non-ACTIVE status.
                enabled: (fields["status"] ?? "ACTIVE").uppercased() == "ACTIVE"
            )
            byID[automation.id] = automation
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Extract the flat top-level `key = value` pairs from an `automation.toml`.
    /// Deliberately minimal: it reads the scalar string fields this reader needs
    /// and ignores everything else (inline tables like `target`, arrays like
    /// `cwds`, comments), rather than pulling in a full TOML dependency.
    static func parseTOML(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.contains(" ") else { continue }  // not a scalar assignment
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // Only take simple scalars: a quoted string or a bare token. Skip
            // inline tables and arrays.
            if value.hasPrefix("{") || value.hasPrefix("[") { continue }
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return fields
    }
}

public extension CodexAutomationsReader {
    /// The real reader over `~/.codex/automations/*/automation.toml`. Failures
    /// (no Codex, no automations) yield an empty list rather than an error.
    static func real(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CodexAutomationsReader {
        let base = home.appendingPathComponent(".codex/automations", isDirectory: true)
        return CodexAutomationsReader {
            let fm = FileManager.default
            guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
            var texts: [String] = []
            for dir in dirs {
                let toml = dir.appendingPathComponent("automation.toml")
                if let text = try? String(contentsOf: toml, encoding: .utf8) { texts.append(text) }
            }
            return texts
        }
    }
}
