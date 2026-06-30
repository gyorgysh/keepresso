import Testing
import Foundation
@testable import KeepressoCore

/// Fake process lister returning a canned command-line list.
private final class FakeProcessLister: ProcessListing {
    var lines: [String]
    init(_ lines: [String]) { self.lines = lines }
    var current: [String] { lines }
}

private let sample = [
    "/usr/sbin/cfprefsd agent",
    "/Users/me/.nvm/versions/node/v24/bin/node server.js",
    "/opt/homebrew/bin/ffmpeg -i in.mov out.mp4",
    "claude --resume",
]

@Test func matchesProcessByCommandSubstring() {
    #expect(ProcessTrigger.matches("node", in: sample))
    #expect(ProcessTrigger.matches("ffmpeg", in: sample))
    #expect(ProcessTrigger.matches("claude", in: sample))
}

@Test func matchingIsCaseInsensitiveAndTrimmed() {
    #expect(ProcessTrigger.matches("NODE", in: sample))
    #expect(ProcessTrigger.matches("  Claude  ", in: sample))
}

@Test func nonMatchingQueryIsFalse() {
    #expect(!ProcessTrigger.matches("postgres", in: sample))
}

@Test func emptyQueryNeverMatches() {
    #expect(!ProcessTrigger.matches("", in: sample))
    #expect(!ProcessTrigger.matches("   ", in: sample))
}

@Test func triggerReadsTheMonitorLive() {
    let lister = FakeProcessLister([])
    let trigger = ProcessTrigger(query: "node", monitor: lister)
    #expect(!trigger.isSatisfied())
    lister.lines = ["/usr/local/bin/node app.js"]
    #expect(trigger.isSatisfied())
}

@Test func factoryBuildsProcessTrigger() {
    let lister = FakeProcessLister(["claude --resume"])
    let factory = TriggerFactory(processes: lister)
    let trigger = factory.makeTrigger(for: .process("claude"))
    #expect(trigger.isSatisfied())
    #expect(trigger.label == "Process \u{201C}claude\u{201D} running")
}

@Test func processRuleEncodesRoundTrip() throws {
    let rule = TriggerRule.process("node")
    let data = try JSONEncoder().encode(rule)
    #expect(try JSONDecoder().decode(TriggerRule.self, from: data) == rule)
}
