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
    var framer = BoundedJSONLineFramer(
        maximumMessageBytes: KeepressoMCPServer.maximumMessageBytes
    )

    @MainActor
    func emit(_ frame: BoundedJSONLineFrame) {
        let response: Data?
        switch frame {
        case .message(let data):
            response = data.isEmpty ? nil : server.handle(data)
        case .oversized:
            response = KeepressoMCPServer.messageTooLargeResponse()
        }
        guard let response else { return }
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(newline)
    }

    while true {
        let chunk = FileHandle.standardInput.readData(ofLength: 4_096)
        if chunk.isEmpty {
            if let finalFrame = framer.finish() { emit(finalFrame) }
            break
        }
        for frame in framer.append(chunk) { emit(frame) }
    }
}
