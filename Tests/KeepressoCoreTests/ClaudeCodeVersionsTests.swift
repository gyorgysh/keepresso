import Testing
import Foundation
@testable import KeepressoCore

private let home = "/Users/me"
private let cliPath = "/Applications/Keepresso.app/Contents/Helpers/keepresso"

/// A Mac described as launchers (path -> resolved target), directory
/// listings, and file contents.
private func files(
    links: [String: String] = [:],
    dirs: [String: [String]] = [:],
    contents: [String: String] = [:]
) -> ClaudeCodeVersions.FileAccess {
    ClaudeCodeVersions.FileAccess(
        exists: { links[$0] != nil || dirs[$0] != nil || contents[$0] != nil },
        resolve: { links[$0] ?? $0 },
        list: { dirs[$0] },
        read: { contents[$0].map { Data($0.utf8) } })
}

private typealias V = ClaudeCodeVersions.Version

@Test func versionParsesAndCompares() {
    #expect(V("2.1.317") == V(2, 1, 317))
    #expect(V("2.1.78")! < V("2.1.317")!)
    #expect(V("2.1.9")! < V("2.1.78")!)
    #expect(V("2.2")! > V("2.1.999")!)
    #expect(V("latest") == nil)
    #expect(V("2.1.0-beta") == nil)
    #expect(V("91184d3d9ba3") == nil)
}

@Test func nativeInstallerVersionComesFromItsVersionsFolder() {
    let found = ClaudeCodeVersions.detect(home: home, files: files(
        links: ["\(home)/.local/bin/claude": "\(home)/.local/share/claude/versions/2.1.317"]))
    #expect(found.known == [V(2, 1, 317)])
    #expect(found.unknownCount == 0)
    #expect(found.supportsStopFailure)
}

@Test func desktopAppCountsOnlyItsNewestCopy() {
    let found = ClaudeCodeVersions.detect(home: home, files: files(
        dirs: ["\(home)/Library/Application Support/Claude/claude-code": ["2.1.50", "2.1.317", ".DS_Store"]]))
    #expect(found.known == [V(2, 1, 317)])
    #expect(found.supportsStopFailure)
}

@Test func homebrewCaskAndNpmVersionsAreRead() {
    let npmRoot = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code"
    let found = ClaudeCodeVersions.detect(home: home, files: files(
        links: [
            "/opt/homebrew/bin/claude": "/opt/homebrew/Caskroom/claude-code/2.1.200/claude",
            "/usr/local/bin/claude": "\(npmRoot)/cli.js",
        ],
        contents: ["\(npmRoot)/package.json": #"{"name":"@anthropic-ai/claude-code","version":"2.0.10"}"#]))
    #expect(Set(found.known) == [V(2, 1, 200), V(2, 0, 10)])
    // The old npm CLI reads the same settings file, so it vetoes the event.
    #expect(!found.supportsStopFailure)
}

@Test func anOldInstallAnywhereVetoesStopFailure() {
    let found = ClaudeCodeVersions.detect(home: home, files: files(
        links: ["\(home)/.local/bin/claude": "\(home)/.local/share/claude/versions/2.1.77"],
        dirs: ["\(home)/Library/Application Support/Claude/claude-code": ["2.1.317"]]))
    #expect(!found.supportsStopFailure)
}

@Test func anUnreadableInstallVetoesStopFailure() {
    // A copied binary (no symlink to a versioned folder) is Claude Code of
    // unknown age: it might predate the event, so it is not written.
    let found = ClaudeCodeVersions.detect(home: home, files: files(
        links: ["/usr/local/bin/claude": "/usr/local/bin/claude"],
        dirs: ["\(home)/Library/Application Support/Claude/claude-code": ["2.1.317"]]))
    #expect(found.unknownCount == 1)
    #expect(!found.supportsStopFailure)
}

@Test func versionEqualityIgnoresTrailingZeros() {
    #expect(V("2.1") == V("2.1.0"))
    #expect(Set([V("2.1")!, V("2.1.0")!]).count == 1)
}

@Test func oldLocalInstallIsReadFromItsNodeModules() {
    // ~/.claude/local/claude is a wrapper script, not a symlink: the version
    // comes from the package installed beside it.
    let local = "\(home)/.claude/local"
    let found = ClaudeCodeVersions.detect(home: home, files: files(
        links: ["\(local)/claude": "\(local)/claude"],
        dirs: ["\(home)/Library/Application Support/Claude/claude-code": ["2.1.317"]],
        contents: ["\(local)/node_modules/@anthropic-ai/claude-code/package.json": #"{"version":"2.1.60"}"#]))
    #expect(found.known.contains(V(2, 1, 60)))
    #expect(!found.supportsStopFailure)
}

@Test func nvmAndBunGlobalsAreFound() {
    let nvmPkg = "\(home)/.nvm/versions/node/v22.1.0/lib/node_modules/@anthropic-ai/claude-code"
    let bunPkg = "\(home)/.bun/install/global/node_modules/@anthropic-ai/claude-code"
    let found = ClaudeCodeVersions.detect(home: home, files: files(
        links: [
            "\(home)/.nvm/versions/node/v22.1.0/bin/claude": "\(nvmPkg)/cli.js",
            "\(home)/.bun/bin/claude": "\(bunPkg)/cli.js",
        ],
        dirs: ["\(home)/.nvm/versions/node": ["v22.1.0"]],
        contents: [
            "\(nvmPkg)/package.json": #"{"version":"2.1.300"}"#,
            "\(bunPkg)/package.json": #"{"version":"2.1.250"}"#,
        ]))
    #expect(Set(found.known) == [V(2, 1, 300), V(2, 1, 250)])
    #expect(found.supportsStopFailure)
}

@Test func desktopAppFolderWithoutVersionsIsUnknown() {
    let found = ClaudeCodeVersions.detect(home: home, files: files(
        dirs: ["\(home)/Library/Application Support/Claude/claude-code": ["current", ".DS_Store"]]))
    #expect(found.unknownCount == 1)
    #expect(!found.supportsStopFailure)
}

@Test func nothingFoundMeansNoStopFailure() {
    #expect(!ClaudeCodeVersions.detect(home: home, files: files()).supportsStopFailure)
}

@Test func twoLaunchersForOneInstallCountOnce() {
    let target = "\(home)/.local/share/claude/versions/2.1.317"
    let found = ClaudeCodeVersions.detect(home: home, files: files(
        links: ["\(home)/.local/bin/claude": target, "/usr/local/bin/claude": target]))
    #expect(found.known == [V(2, 1, 317)])
}

// MARK: - Gated hook format

@Test func stopFailureIsInstalledOnlyWhenSupported() throws {
    let with = try AgentHooks.installHooks(
        into: nil, cliPath: cliPath, format: .claude(includingStopFailure: true))
    let without = try AgentHooks.installHooks(
        into: nil, cliPath: cliPath, format: .claude(includingStopFailure: false))
    let hooksWith = try #require((try JSONSerialization.jsonObject(with: with) as? [String: Any])?["hooks"] as? [String: Any])
    let hooksWithout = try #require((try JSONSerialization.jsonObject(with: without) as? [String: Any])?["hooks"] as? [String: Any])
    #expect(hooksWith["StopFailure"] != nil)
    #expect(hooksWithout["StopFailure"] == nil)
    #expect(Set(hooksWithout.keys) == Set(AgentHooks.installedEvents))
}

@Test func anUpgradeAddsStopFailureAndADowngradeRemovesIt() throws {
    let old = try AgentHooks.installHooks(into: nil, cliPath: cliPath, format: .claude)
    // Every install supports it now: the old file needs repair, and repair adds it.
    let supported = AgentHooks.SettingsFormat.claude(includingStopFailure: true)
    guard case .needsRepair(let report) = AgentHooks.hookInstallState(of: old, cliPath: cliPath, format: supported) else {
        Issue.record("expected needsRepair"); return
    }
    #expect(report.missing == ["StopFailure"])
    let upgraded = try AgentHooks.installHooks(into: old, cliPath: cliPath, format: supported)
    #expect(AgentHooks.hookInstallState(of: upgraded, cliPath: cliPath, format: supported) == .installed)

    // An old Claude Code appears: the entry is orphaned and repair strips it.
    guard case .needsRepair(let back) = AgentHooks.hookInstallState(of: upgraded, cliPath: cliPath, format: .claude) else {
        Issue.record("expected needsRepair"); return
    }
    #expect(back.orphaned == ["StopFailure"])
    let downgraded = try AgentHooks.installHooks(into: upgraded, cliPath: cliPath, format: .claude)
    #expect(AgentHooks.hookInstallState(of: downgraded, cliPath: cliPath, format: .claude) == .installed)
}

@Test func gatedRepairKeepsForeignHooks() throws {
    let foreign = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"say failed"}]}]}}"#
    let installed = try AgentHooks.installHooks(
        into: Data(foreign.utf8), cliPath: cliPath, format: .claude(includingStopFailure: true))
    let removed = try AgentHooks.installHooks(into: installed, cliPath: cliPath, format: .claude)
    let root = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
    #expect(root["model"] as? String == "opus")
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stopFailure = try #require(hooks["StopFailure"] as? [[String: Any]])
    // The user's own StopFailure hook survives our entry being stripped.
    #expect(stopFailure.count == 1)
    let command = (stopFailure[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String
    #expect(command == "say failed")
}
