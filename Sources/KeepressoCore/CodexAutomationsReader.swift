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
    private let loadAutomations: @Sendable () -> [String]

    public init(loadAutomations: @escaping @Sendable () -> [String]) {
        self.loadAutomations = loadAutomations
    }

    public func automations() -> [ScheduledAutomation] {
        var byID: [String: ScheduledAutomation] = [:]
        for text in loadAutomations() {
            let fields = Self.parseTOML(text)
            guard (fields["execution_environment"] ?? "local") == "local" else { continue }
            guard let id = fields["id"], !id.isEmpty else { continue }
            guard let ruleText = fields["rrule"], let rule = RecurrenceRule(ruleText) else { continue }
            let automation = ScheduledAutomation(
                source: .codex,
                key: id,
                name: fields["name"] ?? id,
                recurrence: .rrule(rule),
                enabled: (fields["status"] ?? "ACTIVE").uppercased() == "ACTIVE"
            )
            byID[automation.id] = automation
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parseTOML(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.contains(" ") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
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
    static func real(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CodexAutomationsReader {
        let base: URL
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            base = URL(fileURLWithPath: raw).appendingPathComponent("automations", isDirectory: true)
        } else {
            base = home.appendingPathComponent(".codex/automations", isDirectory: true)
        }
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
