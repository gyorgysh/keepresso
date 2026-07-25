import Foundation

/// Exact session-state tracking for the Codex CLI, the third agent with a
/// lifecycle hook system.
///
/// Codex's hooks are modelled on Claude Code's closely enough that the event
/// names and the payload field names are the same, so this reuses
/// ``AgentHooks/reduce(event:toolName:message:)`` and
/// ``AgentHooks/HookPayload`` wholesale. Only the config file differs, and
/// that file has sharper edges than either of the others.
///
/// Three of those edges shaped everything below, all confirmed against the
/// real binary rather than the docs:
///
/// 1. **A stray top-level key destroys the file.** `hooks.json` is parsed with
///    unknown fields denied, and it accepts only `description` and `hooks`.
///    One unrecognised key at the top level makes Codex reject the whole file
///    and load *none* of its hooks, the user's included. So this writes those
///    two keys and nothing else, ever.
/// 2. **Event names are not validated.** The names under `hooks` are matched
///    field by field with no error on a miss, so `sessionStart` instead of
///    `SessionStart` parses cleanly, registers zero hooks, and warns nowhere.
///    A typo here is silent and total; ``installedEvents`` is the single place
///    they are spelled.
/// 3. **Installed is not the same as running.** Every hook starts untrusted,
///    and an untrusted hook never executes and says nothing about it. Codex
///    asks the user to review it. Keepresso deliberately does not write the
///    trust state itself even though it can: that table is the whole point of
///    the review gate, and granting ourselves permission to run would defeat
///    a security decision that belongs to the person at the keyboard. See
///    ``needsUserApprovalNote``.
public enum CodexHooks {

    /// The events Keepresso installs, spelled exactly as Codex matches them.
    /// Codex silently ignores a name it does not recognise, so these strings
    /// are load-bearing: a lowercase letter here disables the integration with
    /// no error anywhere.
    ///
    /// The set is deliberately the same one ``AgentHooks`` maps, so the shared
    /// reducer covers it with nothing Codex-specific to remember.
    public static let installedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "SessionEnd",
    ]

    /// Ownership marker inside every installed hook command. Distinct from the
    /// other tools' markers so removing one integration can never strip
    /// another's entries.
    public static let hookMarker = "__keepresso_codex_hook"

    /// `~/.codex/hooks.json`. Codex also reads a `[hooks]` table in
    /// `config.toml`, but writing there would mean sharing a file with the
    /// user's own settings (including the `notify` key, which is a single
    /// value that some people already point at their own program), and Codex
    /// warns when one layer is declared in both places. The dedicated file is
    /// the quieter neighbour.
    ///
    /// `CODEX_HOME` moves the whole directory, so it is honoured here.
    public static func hooksURL(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".codex", isDirectory: true)
        return base.appendingPathComponent("hooks.json")
    }

    /// The shell command an installed hook runs.
    ///
    /// Codex fails open: a hook that writes nothing, or exits non-zero, lets
    /// the action proceed. That is the opposite of Cursor, where an empty
    /// answer on a permission step blocks the tool call, so this can be the
    /// same inert no-op ``AgentHooks`` uses without the defensive `printf`.
    static func hookCommand(event: String, cliPath: String) -> String {
        "c=\(AgentHooks.shellSingleQuoted(cliPath)); [ -x \"$c\" ] || "
            + "c=/Applications/Keepresso.app/Contents/Helpers/keepresso; "
            + "\"$c\" codex-hook \(event); : # \(hookMarker)"
    }

    /// Whether a record in the shared hooks folder came from Codex.
    public static func ownsRecord(_ record: AgentHooks.HookRecord) -> Bool {
        record.agent == "codex"
    }

    // MARK: - Handling one invocation

    /// Applies one hook invocation. The payload and the events are Claude
    /// Code's shape, so this decodes and reduces with the shared code and only
    /// stamps the agent name differently.
    public static func handle(
        event: String,
        payloadData: Data,
        parentPid: Int32,
        now: Date = Date(),
        in directory: URL = AgentHooks.directoryURL(),
        parentOf: (Int32) -> Int32? = AgentHooks.defaultParentOf,
        commandOf: (Int32) -> String? = AgentHooks.defaultCommandOf,
        pathOf: (Int32) -> String? = AgentHooks.defaultPathOf
    ) {
        AgentHooks.handle(
            event: event, payloadData: payloadData, parentPid: parentPid, now: now,
            in: directory, parentOf: parentOf, commandOf: commandOf, pathOf: pathOf,
            defaultAgent: "codex")
    }

    // MARK: - hooks.json editing

    /// Merges one entry per mapped event into `hooks`, preserving the user's
    /// own entries and anything here we cannot read. Both levels are arrays,
    /// so appending alongside another tool is exactly what the format expects.
    ///
    /// Only `description` and `hooks` survive at the top level, because any
    /// other key would make Codex throw the whole file away. If the user's
    /// file carries a `description`, it is kept; anything else at the top
    /// level is something Codex itself would already be rejecting.
    public static func installHooks(into data: Data?, cliPath: String) throws -> Data {
        var root = try parseRoot(data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Sweep our entries out of every event first, not only the ones about
        // to be rewritten. An entry left under an event an older version
        // installed is still ours and still fires, and Repair is just a
        // re-install, so a re-install has to be able to clear it.
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            // Only events that actually hold one of ours are touched. Counting
            // our commands is the exact test: an array's length can stay the
            // same while our entry is stripped out of a group beside a sibling
            // we left alone.
            guard groups.contains(where: { !keepressoCommands(in: $0).isEmpty }) else { continue }
            let kept = stripKeepressoEntries(groups)
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        for event in installedEvents {
            var groups = (hooks[event] as? [Any]) ?? []
            groups.append([
                "hooks": [
                    [
                        "type": "command",
                        "command": hookCommand(event: event, cliPath: cliPath),
                        "timeout": 5,
                    ] as [String: Any],
                ],
            ] as [String: Any])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func removeHooks(from data: Data?) throws -> Data {
        var root = try parseRoot(data)
        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [Any] else { continue }
                let kept = stripKeepressoEntries(groups)
                if kept.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = kept
                }
            }
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
        }
        return try serialize(root)
    }

    /// Event-by-event health, the same report the other two produce.
    public static func inspect(_ data: Data?, cliPath: String) -> AgentHooks.HookInstallReport {
        var report = AgentHooks.HookInstallReport()
        guard let data, !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            report.missing = Set(installedEvents)
            return report
        }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let ours = groups.flatMap { keepressoCommands(in: $0) }
            guard !ours.isEmpty else { continue }
            guard installedEvents.contains(event) else {
                report.orphaned.insert(event)
                continue
            }
            if ours.count > 1 {
                report.duplicated.insert(event)
            } else if ours[0] != hookCommand(event: event, cliPath: cliPath) {
                report.stale.insert(event)
            } else {
                report.healthy.insert(event)
            }
        }
        report.missing = Set(installedEvents)
            .subtracting(report.healthy)
            .subtracting(report.duplicated)
            .subtracting(report.stale)
        return report
    }

    public static func hookInstallState(of data: Data?, cliPath: String) -> AgentHooks.HookInstallState {
        guard let data, !data.isEmpty else { return .notInstalled }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else { return .unreadable }
        let report = inspect(data, cliPath: cliPath)
        if report.isAbsent { return .notInstalled }
        return report.isHealthy ? .installed : .needsRepair(report)
    }

    /// Codex will not run a newly installed hook until the user reviews it,
    /// and says nothing when it skips one. Nothing Keepresso can write makes
    /// that happen, so the UI has to say it out loud instead.
    public static let needsUserApprovalNote = true

    // MARK: - Shapes

    /// Same element-by-element walk as the other two: an entry we cannot read
    /// is carried through untouched rather than costing the user their hooks.
    static func stripKeepressoEntries(_ groups: [Any]) -> [Any] {
        groups.compactMap { element -> Any? in
            guard let group = element as? [String: Any] else { return element }
            guard let inner = group["hooks"] as? [Any] else { return group }
            let foreign = inner.filter { entry in
                guard let entry = entry as? [String: Any] else { return true }
                return !((entry["command"] as? String)?.contains(hookMarker) ?? false)
            }
            guard !foreign.isEmpty else { return nil }
            var kept = group
            kept["hooks"] = foreign
            return kept
        }
    }

    static func keepressoCommands(in element: Any) -> [String] {
        guard let group = element as? [String: Any],
              let inner = group["hooks"] as? [Any] else { return [] }
        return inner.compactMap { entry in
            guard let entry = entry as? [String: Any] else { return nil }
            return (entry["command"] as? String).flatMap { $0.contains(hookMarker) ? $0 : nil }
        }
    }

    /// Reads the file down to the two keys Codex tolerates. A top-level key we
    /// don't recognise is dropped rather than written back, because carrying
    /// it forward would keep the file in the state where Codex loads none of
    /// its hooks at all.
    private static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw AgentHooks.SettingsUnreadableError()
        }
        var kept: [String: Any] = [:]
        if let description = root["description"] { kept["description"] = description }
        if let hooks = root["hooks"] { kept["hooks"] = hooks }
        return kept
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
