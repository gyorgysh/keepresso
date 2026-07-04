import Testing
import Foundation
@testable import KeepressoCore

/// A scratch suite per test, cleaned before use so runs don't leak into each
/// other (`UserDefaults` persists between test invocations).
private func scratchDefaults(_ name: String) -> UserDefaults {
    let suite = "keepresso-tests.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Test func sessionStateRoundTripsThroughDefaults() {
    let defaults = scratchDefaults("state")
    #expect(WidgetBridge.readState(from: defaults) == nil)

    WidgetBridge.writeState(SharedSessionState(isActive: true), to: defaults)
    #expect(WidgetBridge.readState(from: defaults) == SharedSessionState(isActive: true))

    WidgetBridge.writeState(SharedSessionState(isActive: false), to: defaults)
    #expect(WidgetBridge.readState(from: defaults)?.isActive == false)
}

@Test func commandFiresAtMostOnce() {
    let defaults = scratchDefaults("consume-once")
    let now = Date(timeIntervalSinceReferenceDate: 1000)
    WidgetBridge.writeCommand(desiredActive: true, at: now, to: defaults)

    #expect(WidgetBridge.consumeCommand(from: defaults, now: now) == true)
    // Consumed: a second read (say, Darwin delivery plus the launch path both
    // arriving) must not fire again.
    #expect(WidgetBridge.consumeCommand(from: defaults, now: now) == nil)
}

@Test func staleCommandIsDroppedAndCleared() {
    let defaults = scratchDefaults("stale")
    let written = Date(timeIntervalSinceReferenceDate: 0)
    WidgetBridge.writeCommand(desiredActive: true, at: written, to: defaults)

    let late = written.addingTimeInterval(WidgetBridge.commandFreshness + 1)
    #expect(WidgetBridge.consumeCommand(from: defaults, now: late) == nil)
    // The stale command is gone, not lingering for the next read.
    #expect(defaults.object(forKey: "widget.desiredActive") == nil)
}

@Test func freshCommandCarriesItsValue() {
    let defaults = scratchDefaults("value")
    let now = Date(timeIntervalSinceReferenceDate: 500)
    WidgetBridge.writeCommand(desiredActive: false, at: now, to: defaults)
    #expect(WidgetBridge.consumeCommand(from: defaults, now: now.addingTimeInterval(5)) == false)
}

@Test func emptyDefaultsHaveNoCommand() {
    let defaults = scratchDefaults("empty")
    #expect(WidgetBridge.consumeCommand(from: defaults) == nil)
}
