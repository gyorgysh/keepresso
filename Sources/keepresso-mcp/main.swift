import Foundation
import KeepressoCore

// The `keepresso-mcp` MCP server. Ships inside the app bundle
// (Contents/Helpers/keepresso-mcp); agents reference it by absolute path in
// their MCP configuration:
//
//   command = "/Applications/Keepresso.app/Contents/Helpers/keepresso-mcp"
//
// Newline-delimited JSON-RPC on stdio, one response line per request line.
// All protocol handling lives in KeepressoCore's MCPServer (unit-tested);
// this file is just the read-eval-print loop. AppKit-free like the CLI so
// `swift build` works with Command Line Tools only.

/// The app's marketing version, read the same way the CLI does: relative to
/// the real executable path, since Bundle.main is not the app bundle here.
func appVersion() -> String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let plistURL = executable
        .deletingLastPathComponent()               // Helpers
        .deletingLastPathComponent()               // Contents
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let info = plist as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String
    else { return "dev" }
    return version
}

let server = MCPServer(
    leaseClient: .real(ownerPid: getppid()),
    wakeClient: .real(),
    serverVersion: appVersion()
)

// stdout is block-buffered on a pipe; every response must flush immediately
// or the client stalls waiting for its reply.
let out = FileHandle.standardOutput
while let line = readLine(strippingNewline: true) {
    guard let response = server.handle(line: line) else { continue }
    out.write(Data((response + "\n").utf8))
}
