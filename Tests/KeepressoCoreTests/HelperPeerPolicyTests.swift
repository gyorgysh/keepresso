import Testing
@testable import KeepressoCore

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
    let req = HelperService.peerRequirement(identifier: "sh.gyorgy.keepresso")
    #expect(req.contains("identifier \"sh.gyorgy.keepresso\""))
}
