import SwiftUI
import KeepressoCore

/// One presentation of hook state for both onboarding and Preferences.
struct AgentHookConnectionRow: View {
    @Bindable var model: AppModel
    let tool: AgentTool
    var compact = false
    @Environment(\.colorScheme) private var colorScheme
    private var state: AgentHooks.HookInstallState { model.hookState(of: tool) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(assetName)
                    .renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(tool == .claudeCode ? Color.keepressoBrew : Color.primary)
                    .frame(width: compact ? 20 : 16, height: compact ? 20 : 16)
                    .padding(compact ? 7 : 5)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: compact ? 8 : 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: tool.displayName).font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
                    if !compact {
                        // The after-install step replaces the scope line, so a
                        // connected tool still takes two lines, not three.
                        Group {
                            if let installedNote { Text(installedNote) } else { Text(subtitle) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                control
            }
            if compact, let installedNote, tool == .codex {
                Text(installedNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.hookError(for: tool) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, compact ? 2 : 0)
        .accessibilityElement(children: .contain)
    }
    /// What the user still has to do in the tool itself once connected.
    private var installedNote: LocalizedStringKey? {
        guard case .installed = state else { return nil }
        switch tool {
        case .codex: return "Approve new hooks in Codex before they can run."
        case .grok: return "Reload hooks in a running Grok session (/hooks, then r) or start a new one."
        case .hermes: return "Restart Hermes and its gateway to load the plugin."
        default: return nil
        }
    }
    @ViewBuilder private var control: some View {
        switch state {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(colorScheme == .dark ? Color.green : Color(red: 0.08, green: 0.42, blue: 0.18))
            Menu {
                Button("Remove") { model.removeAgentToolHooks(tool) }
            } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("Manage %@ hooks", tool.displayName))
        case .notInstalled:
            Button("Connect") { model.connectAgentTool(tool) }.controlSize(.small)
        case .needsRepair:
            Button { model.connectAgentTool(tool) } label: {
                Label("Repair", systemImage: "wrench.and.screwdriver")
            }.controlSize(.small)
        case .unreadable:
            Label("Couldn't be read", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
    private var subtitle: LocalizedStringKey {
        switch tool {
        // Claude Code also runs inside the Claude desktop app, which reads
        // the same settings file, like Codex inside ChatGPT.
        case .grok, .qwen, .devin, .kimi: return "CLI sessions"
        case .hermes: return "CLI and gateway sessions"
        default: return "App and CLI sessions"
        }
    }
    private var assetName: String {
        switch tool {
        case .claudeCode: return "brand_claude_code"
        case .cursor: return "brand_cursor"
        case .codex: return "brand_codex"
        case .antigravity: return "brand_antigravity"
        case .grok: return "brand_grok"
        case .hermes: return "brand_hermes"
        case .qwen: return "brand_qwen"
        case .devin: return "brand_devin"
        case .kimi: return "brand_kimi"
        }
    }
}

extension AppModel {
    func removeAgentToolHooks(_ tool: AgentTool) {
        switch tool {
        case .claudeCode: removeClaudeHooks()
        case .cursor: removeCursorHooks()
        case .codex: removeCodexHooks()
        case .antigravity: removeAntigravityHooks()
        case .grok: removeGrokHooks()
        case .hermes: removeHermesPlugin()
        case .qwen, .devin, .kimi: tool.compatTool.map(removeCompatHooks)
        }
    }
    func hookError(for tool: AgentTool) -> String? {
        switch tool {
        case .claudeCode: return claudeHooksError
        case .cursor: return cursorHooksError
        case .codex: return codexHooksError
        case .antigravity: return antigravityHooksError
        case .grok: return grokHooksError
        case .hermes: return hermesHooksError
        case .qwen, .devin, .kimi: return tool.compatTool.flatMap { compatHooksErrors[$0] }
        }
    }
}
