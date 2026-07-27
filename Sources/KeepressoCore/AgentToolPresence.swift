import Foundation

/// Whether a hook-capable agent tool is on this Mac at all.
///
/// The connect rows are only worth offering for tools the user actually has.
/// Offering an absent one is noise, and going through with it is worse than
/// noise: installing hooks writes that tool's config file from nothing, so a
/// Mac that has never had Cursor would end up with a `~/.cursor/hooks.json`
/// containing nothing but Keepresso's entries, for a tool its owner never
/// installed.
public enum AgentTool: CaseIterable, Sendable {
    case claudeCode
    case cursor
    case codex
    case antigravity

    /// Paths that each, on their own, prove the tool is here. Any one is
    /// enough, because these tools arrive in several shapes: a config folder
    /// once the tool has run, a CLI on disk, or an app bundle. Checked rather
    /// than executed, so nothing is launched to find out.
    ///
    /// Deliberately not exhaustive. A tool installed somewhere unusual reads
    /// as absent, which costs the user a hidden row and nothing else; the
    /// alternative, guessing generously, costs a stray config file.
    func evidencePaths(home: String) -> [String] {
        switch self {
        case .claudeCode:
            return [
                "\(home)/.claude",
                "\(home)/.claude.json",
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                // The desktop app runs Claude Code inside itself and reads the
                // same settings file, so it counts.
                "/Applications/Claude.app",
            ]
        case .cursor:
            return [
                "\(home)/.cursor",
                // The CLI installs under both this name and a bare `agent`;
                // only the specific one is evidence, since a file called
                // `agent` proves nothing about Cursor.
                "\(home)/.local/bin/cursor-agent",
                "/opt/homebrew/bin/cursor-agent",
                "/usr/local/bin/cursor-agent",
                "/Applications/Cursor.app",
            ]
        case .antigravity:
            return [
                // The app's own store and the CLI's, never a bare `.gemini`:
                // the Gemini CLI keeps its own config in there and proves
                // nothing about Antigravity.
                "\(home)/.gemini/antigravity",
                "\(home)/.gemini/antigravity-cli",
                "\(home)/.local/bin/agy",
                "/Applications/Antigravity.app",
            ]
        case .codex:
            return [
                "\(home)/.codex",
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]
        }
    }

    /// The tool's own name, as its makers write it. Product names, so they are
    /// never translated.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    /// Which tools the agentic setup step should list, in a stable order.
    ///
    /// A tool that isn't on this Mac is never offered, for the same reason the
    /// Preferences rows hide it: connecting writes that tool's config file, and
    /// nobody should be invited to create configuration for something they
    /// don't use. A tool that is already connected is listed even when its
    /// files have since moved or the tool was uninstalled, so the step can
    /// show it as done and still offer to undo it.
    public static func setupTools(
        present: (AgentTool) -> Bool,
        connected: (AgentTool) -> Bool
    ) -> [AgentTool] {
        allCases.filter { present($0) || connected($0) }
    }

    /// True when any one piece of evidence is on disk. Pure over the injected
    /// probe, so tests script a Mac with or without each tool.
    public func isPresent(
        home: String = NSHomeDirectory(),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        evidencePaths(home: home).contains(where: exists)
    }
}
