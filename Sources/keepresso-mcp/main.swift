import Foundation
import KeepressoCore

MainActor.assumeIsolated {
    let server: KeepressoMCPServer
    do {
        server = try KeepressoMCPServer()
    } catch {
        FileHandle.standardError.write(Data("keepresso-mcp: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    let newline = Data([0x0A])

    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty,
              let response = server.handle(Data(line.utf8))
        else { continue }
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(newline)
    }
}
