import Testing
import Foundation
@testable import KeepressoCore

@Test func parsesStartWithoutDuration() {
    let url = URL(string: "keepresso://start")!
    #expect(URLCommand.parse(url) == .start(mode: .indefinite))
}

@Test func parsesStartWithDurationInMinutes() {
    let url = URL(string: "keepresso://start?duration=60")!
    #expect(URLCommand.parse(url) == .start(mode: .timed(duration: 3600)))
}

@Test func parsesStop() {
    let url = URL(string: "keepresso://stop")!
    #expect(URLCommand.parse(url) == .stop)
}

@Test func parsesToggle() {
    let url = URL(string: "keepresso://toggle")!
    #expect(URLCommand.parse(url) == .toggle)
}

@Test func rejectsWrongScheme() {
    let url = URL(string: "https://start")!
    #expect(URLCommand.parse(url) == nil)
}

@Test func rejectsUnknownHost() {
    let url = URL(string: "keepresso://pause")!
    #expect(URLCommand.parse(url) == nil)
}

@Test func rejectsNonPositiveDuration() {
    let url = URL(string: "keepresso://start?duration=0")!
    #expect(URLCommand.parse(url) == nil)
}

@Test func rejectsUnparseableDuration() {
    let url = URL(string: "keepresso://start?duration=abc")!
    #expect(URLCommand.parse(url) == nil)
}
