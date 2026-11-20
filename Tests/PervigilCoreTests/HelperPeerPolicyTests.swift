import Testing
import Foundation
import Security
@testable import PervigilCore

@Test func helperPeerPolicyRefusesRoot() {
    #expect(!HelperPeerPolicy.shouldAccept(peerUID: 0, consoleUID: 501))
    #expect(!HelperPeerPolicy.shouldAccept(peerUID: 0, consoleUID: nil))
}

@Test func helperPeerPolicyAcceptsTheConsoleUser() {
    #expect(HelperPeerPolicy.shouldAccept(peerUID: 501, consoleUID: 501))
}

@Test func helperPeerPolicyRefusesADifferentLocalUser() {
    #expect(!HelperPeerPolicy.shouldAccept(peerUID: 502, consoleUID: 501))
}

@Test func helperPeerPolicyAllowsNonRootWhenThereIsNoConsoleUser() {
    // SSH-only or loginwindow: no GUI session uid to match against. Still
    // refuse root; anyone else is the installing user talking over XPC.
    #expect(HelperPeerPolicy.shouldAccept(peerUID: 501, consoleUID: nil))
}

@Test func peerRequirementNamesTheIdentifier() {
    let req = HelperService.peerRequirement(identifier: "io.github.bubb4rd.pervigil")
    #expect(req.contains("identifier \"io.github.bubb4rd.pervigil\""))
}

@Test func bundledPathsResolveBothDirections() {
    let helper = "/Applications/Pervigil.app/Contents/MacOS/pervigil-helper"
    #expect(HelperPeerPolicy.bundledAppExecutablePath(for: helper)
        == "/Applications/Pervigil.app/Contents/MacOS/Pervigil")
    let app = "/Applications/Pervigil.app/Contents/MacOS/Pervigil"
    #expect(HelperPeerPolicy.bundledHelperExecutablePath(for: app)
        == "/Applications/Pervigil.app/Contents/MacOS/pervigil-helper")
    // Outside an app bundle (a raw Xcode build) there is nothing to pin.
    #expect(HelperPeerPolicy.bundledAppExecutablePath(
        for: "/tmp/DerivedData/pervigil-helper") == nil)
    #expect(HelperPeerPolicy.bundledHelperExecutablePath(
        for: "/tmp/DerivedData/Pervigil") == nil)
}

@Test func pinnedRequirementPinsIdentifierToOnDiskCode() throws {
    // /bin/ls is always signed with a designated requirement, so it
    // exercises the Security-framework machinery end to end. (A platform
    // binary designates by anchor; the cdhash shape is covered below with
    // an ad-hoc signature.)
    let req = HelperPeerPolicy.pinnedPeerRequirement(
        identifier: "io.github.bubb4rd.pervigil.helper", executablePath: "/bin/ls")
    let pinned = try #require(req)
    #expect(pinned.contains("identifier \"io.github.bubb4rd.pervigil.helper\""))

    // The produced text must compile as a requirement (guards the string
    // assembly against a fail-closed-always typo).
    var requirement: SecRequirement?
    #expect(SecRequirementCreateWithString(pinned as CFString, SecCSFlags(rawValue: 0), &requirement)
        == errSecSuccess)
    #expect(requirement != nil)
}

@Test func pinnedRequirementUsesCdhashForAdHocCode() throws {
    // Ad-hoc builds (the dev path this pinning exists for) designate by
    // cdhash: sign a scratch copy and check the pin carries it.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pervigil-adhoc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let copy = dir.appendingPathComponent("tool").path
    try FileManager.default.copyItem(atPath: "/bin/echo", toPath: copy)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["-f", "-s", "-", copy]
    try sign.run()
    sign.waitUntilExit()
    try #require(sign.terminationStatus == 0)

    let pinned = try #require(HelperPeerPolicy.pinnedPeerRequirement(
        identifier: "com.example.peer", executablePath: copy))
    #expect(pinned.contains("identifier \"com.example.peer\""))
    #expect(pinned.contains("cdhash"))
}

@Test func designatedRequirementIsNilForUnsignedOrMissingFiles() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("pervigil-unsigned-\(UUID().uuidString)").path
    FileManager.default.createFile(atPath: missing, contents: Data("x".utf8))
    defer { try? FileManager.default.removeItem(atPath: missing) }
    #expect(HelperPeerPolicy.designatedRequirementText(executablePath: missing) == nil)
    #expect(HelperPeerPolicy.designatedRequirementText(executablePath: missing + ".nope") == nil)
    #expect(HelperPeerPolicy.pinnedPeerRequirement(
        identifier: "io.github.bubb4rd.pervigil.helper", executablePath: missing) == nil)
}
