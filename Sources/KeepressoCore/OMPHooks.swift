import Foundation

/// Optional exact lifecycle events for Oh My Pi. Native process discovery
/// remains the zero-setup fallback. This extension adds precise working and
/// waiting edges using OMP's own session lifecycle.
public enum OMPHooks {
    public static let marker = "KEEPRESSO OMP ACTIVITY EXTENSION"

    public enum Event: String, Sendable {
        case sessionStart = "session-start"
        case agentStart = "agent-start"
        case agentEnd = "agent-end"
        case sessionEnd = "session-end"
    }

    public enum InstallError: Error, Equatable, Sendable {
        case extensionAlreadyOwnedByAnotherFile
    }

    public static func agentDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".omp/agent", isDirectory: true)
    }

    public static func extensionURL(agentDirectory: URL = agentDirectory()) -> URL {
        agentDirectory.appendingPathComponent("extensions/keepresso-agent-activity.ts")
    }

    /// OMP persists session IDs after a timestamp prefix in its session file
    /// names (`<timestamp>_<session-id>.jsonl`).
    public static func sessionId(fromSessionFile file: String) -> String? {
        let name = URL(fileURLWithPath: file).lastPathComponent
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
        let timestampPrefix = #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_"#
        let id: String
        if let range = stem.range(of: timestampPrefix, options: .regularExpression) {
            id = String(stem[range.upperBound...])
        } else {
            id = stem
        }
        return id.isEmpty ? nil : id
    }

    /// Maps OMP's session and agent-loop events onto the shared per-session
    /// hook record used by all other agents.
    public static func record(
        event: Event,
        sessionId: String,
        cwd: String?,
        agentPid: Int32?,
        willContinue: Bool = false,
        awaitingAsyncWork: Bool = false,
        at date: Date = Date(),
        in directory: URL = AgentHooks.directoryURL()
    ) {
        guard !sessionId.isEmpty else { return }
        switch effect(for: event, willContinue: willContinue, awaitingAsyncWork: awaitingAsyncWork) {
        case .end:
            AgentHooks.delete(sessionId: sessionId, in: directory)
        case .set(let state, let detail):
            AgentHooks.write(
                AgentHooks.HookRecord(
                    sessionId: sessionId,
                    state: state,
                    detail: detail,
                    cwd: cwd,
                    agentPid: agentPid,
                    agent: "omp",
                    updatedAt: date
                ),
                in: directory
            )
        }
    }

    public static func effect(
        for event: Event,
        willContinue: Bool = false,
        awaitingAsyncWork: Bool = false
    ) -> AgentHooks.HookEventEffect {
        switch event {
        case .sessionStart:
            return .set(.waiting, detail: "waiting")
        case .agentStart:
            return .set(.working, detail: nil)
        case .agentEnd where willContinue || awaitingAsyncWork:
            // OMP has yielded from a turn but still has an automatic or
            // background continuation, so Keepresso keeps holding awake. OMP
            // has no job-finished event, but a background result wakes the
            // session, which starts a new agent loop.
            return .set(.working, detail: nil)
        case .agentEnd:
            return .set(.waiting, detail: "waiting")
        case .sessionEnd:
            return .end
        }
    }

    /// Resolves the OMP process above the short-lived helper CLI and records
    /// the event. A missing ancestor is a silent no-op, and native detection
    /// still sees any process it can identify.
    public static func handle(
        event rawEvent: String,
        sessionId: String,
        cwd: String,
        willContinue: Bool,
        awaitingAsyncWork: Bool,
        parentPid: Int32,
        now: Date = Date(),
        in directory: URL = AgentHooks.directoryURL(),
        parentOf: (Int32) -> Int32? = AgentHooks.defaultParentOf,
        commandOf: (Int32) -> String? = AgentHooks.defaultCommandOf,
        pathOf: (Int32) -> String? = AgentHooks.defaultPathOf,
        argumentsOf: (Int32) -> String? = AgentHooks.defaultArgumentsOf
    ) {
        guard let event = Event(rawValue: rawEvent) else { return }
        // The extension sends "" when OMP has no working directory.
        let cwd: String? = cwd.isEmpty ? nil : cwd
        if event == .sessionEnd {
            let id = Self.sessionId(fromSessionFile: sessionId) ?? sessionId
            record(event: event, sessionId: id, cwd: cwd, agentPid: nil, at: now, in: directory)
            return
        }
        guard let match = findAgent(
            startingAt: parentPid,
            parentOf: parentOf,
            commandOf: commandOf,
            pathOf: pathOf,
            argumentsOf: argumentsOf
        ) else { return }
        record(
            event: event,
            sessionId: sessionId,
            cwd: cwd,
            agentPid: match.agentPid,
            willContinue: willContinue,
            awaitingAsyncWork: awaitingAsyncWork,
            at: now,
            in: directory
        )
    }

    /// The OMP process above the hook. The prebuilt binary (install script,
    /// Homebrew, Nix, mise) runs as `omp`, but a Bun or npm install runs as
    /// `bun …/omp` or `node …/omp`, where only argv names it. That is
    /// recognized the way the `ps` scan does it.
    static func findAgent(
        startingAt pid: Int32,
        parentOf: (Int32) -> Int32?,
        commandOf: (Int32) -> String?,
        pathOf: (Int32) -> String?,
        argumentsOf: (Int32) -> String?
    ) -> AgentHooks.AncestorMatch? {
        AgentHooks.findAgentAncestor(
            startingAt: pid,
            agents: ["omp"],
            parentOf: parentOf,
            commandOf: commandOf,
            pathOf: pathOf,
            alsoMatches: { pid in
                argumentsOf(pid).flatMap { PSAgentActivityMonitor.agentName(for: $0, agents: ["omp"]) } != nil
            }
        )
    }

    public static func ownsRecord(_ record: AgentHooks.HookRecord) -> Bool {
        record.agent == "omp"
    }

    /// Current install status for the one Keepresso-owned OMP extension.
    public static func installState(
        cliPath: String,
        agentDirectory: URL = agentDirectory()
    ) -> AgentHooks.HookInstallState {
        let url = extensionURL(agentDirectory: agentDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return .notInstalled }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return .unreadable }
        guard source.contains(marker) else { return .unreadable }
        if source == extensionSource(cliPath: cliPath) { return .installed }
        var report = AgentHooks.HookInstallReport()
        report.stale.insert("extension")
        return .needsRepair(report)
    }

    /// Installs or repairs only the file carrying our marker. Other OMP
    /// extensions remain untouched.
    public static func install(
        cliPath: String,
        agentDirectory: URL = agentDirectory(),
        fileManager: FileManager = .default
    ) throws {
        let url = extensionURL(agentDirectory: agentDirectory)
        if fileManager.fileExists(atPath: url.path) {
            guard let existing = try? String(contentsOf: url, encoding: .utf8), existing.contains(marker) else {
                throw InstallError.extensionAlreadyOwnedByAnotherFile
            }
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(extensionSource(cliPath: cliPath).utf8).write(to: url, options: .atomic)
    }

    /// Removes Keepresso's extension only. Unrelated or replaced files are
    /// never deleted, and the extensions folder goes only if that leaves it
    /// empty.
    public static func remove(
        agentDirectory: URL = agentDirectory(),
        fileManager: FileManager = .default
    ) throws {
        let url = extensionURL(agentDirectory: agentDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard let existing = try? String(contentsOf: url, encoding: .utf8), existing.contains(marker) else {
            throw InstallError.extensionAlreadyOwnedByAnotherFile
        }
        try fileManager.removeItem(at: url)
        let folder = url.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fileManager.removeItem(at: folder)
        }
    }

    /// The extension does no polling. It emits one small CLI event at each
    /// OMP lifecycle edge, and deliberately ignores helper failures so it
    /// cannot disrupt an agent session.
    public static func extensionSource(cliPath: String) -> String {
        let encodedPath = (try? JSONSerialization.data(
            withJSONObject: cliPath,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"/usr/bin/false\""
        return #"""
        // KEEPRESSO OMP ACTIVITY EXTENSION
        // Generated by Keepresso. This extension reports lifecycle edges only.
        export default function (pi: any) {
          const keepresso = \#(encodedPath);

          // Events go out one at a time, in order. OMP can fire agent_end and
          // session_shutdown together on exit, and a late agent-end would
          // otherwise rewrite the record session-end just removed. Only
          // shutdown is awaited (so it lands before OMP exits). The rest never
          // hold up OMP.
          let queue: Promise<void> = Promise.resolve();
          let reported: string | undefined;
          function report(event: string, ctx: any, sessionId: string | undefined, willContinue = false, awaitingAsyncWork = false) {
            if (!sessionId) return queue;
            reported = event === "session-end" ? undefined : sessionId;
            const args = [
              "omp-hook", event, sessionId, ctx.cwd ?? "", willContinue ? "1" : "0", awaitingAsyncWork ? "1" : "0"
            ];
            queue = queue.then(async () => {
              try {
                await pi.exec(keepresso, args, { cwd: ctx.cwd, timeout: 5000 });
              } catch {
                // Keepresso is an optional observer: never interrupt OMP.
              }
            });
            return queue;
          }

          // Subagents (task tool, eval agent(), /tan clones) run in the same
          // process under their own session. The main session already reads
          // as working while they run, and their records would overwrite it.
          const isMain = (ctx: any) => ctx.agent?.kind !== "sub";
          const currentSession = (ctx: any): string | undefined => ctx.sessionManager?.getSessionId?.();
          pi.on("session_start", (_event: any, ctx: any) => {
            if (isMain(ctx)) report("session-start", ctx, currentSession(ctx));
          });
          pi.on("agent_start", (_event: any, ctx: any) => {
            if (isMain(ctx)) report("agent-start", ctx, currentSession(ctx));
          });
          pi.on("agent_end", (event: any, ctx: any) => {
            if (isMain(ctx)) {
              report("agent-end", ctx, currentSession(ctx), !!event.willContinue, !!event.awaitingAsyncWork);
            }
          });
          pi.on("session_shutdown", (_event: any, ctx: any) => {
            if (isMain(ctx)) return report("session-end", ctx, reported ?? currentSession(ctx));
          });
          pi.on("session_switch", (_event: any, ctx: any) => {
            if (!isMain(ctx)) return;
            // End the session last reported, which also covers an in-memory
            // session that has no previous file.
            const next = currentSession(ctx);
            if (reported && reported !== next) report("session-end", ctx, reported);
            report("session-start", ctx, next);
          });
        }
        """#
    }
}
