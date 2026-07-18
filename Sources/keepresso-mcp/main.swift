import Foundation
import KeepressoCore

let server = KeepressoMCPServer()
let newline = Data([0x0A])

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let response = server.handle(Data(line.utf8))
    else { continue }
    FileHandle.standardOutput.write(response)
    FileHandle.standardOutput.write(newline)
}
