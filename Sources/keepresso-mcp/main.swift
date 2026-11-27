import Foundation
import KeepressoCore

/// The app's marketing version, read the same way the CLI does: relative to
/// the real executable path, since Bundle.main is not the app bundle here.
func appVersion() -> String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let plistURL = executable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
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
