import Testing
import Foundation
@testable import KeepressoCore

private let installed = URL(fileURLWithPath: "/Applications/Keepresso.app")
private let derived = URL(fileURLWithPath: "/Users/g/Library/Developer/Xcode/DerivedData/Keepresso/Build/Products/Debug/Keepresso.app")
private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func instance(
    pid: Int32,
    at url: URL? = installed,
    launchedAfter seconds: TimeInterval
) -> SingleInstanceGuard.Instance {
    .init(pid: pid, bundleURL: url, launchDate: epoch.addingTimeInterval(seconds))
}

@Test func yieldsToAnOlderSiblingAtTheSamePath() {
    let current = instance(pid: 200, launchedAfter: 60)
    let older = instance(pid: 100, launchedAfter: 0)
    #expect(SingleInstanceGuard.peerToYieldTo(current: current, peers: [older]) == older)
}

@Test func theOriginalKeepsRunningWhenNoOlderSiblingExists() {
    let current = instance(pid: 100, launchedAfter: 0)
    let newcomer = instance(pid: 200, launchedAfter: 60)
    #expect(SingleInstanceGuard.peerToYieldTo(current: current, peers: [newcomer]) == nil)
}

@Test func aloneMeansKeepRunning() {
    let current = instance(pid: 100, launchedAfter: 0)
    #expect(SingleInstanceGuard.peerToYieldTo(current: current, peers: []) == nil)
}

@Test func ignoresSiblingsRunningFromADifferentBundlePath() {
    // The relocation hand-off launches the /Applications copy from the DMG or
    // Downloads: a different path, so it must not be mistaken for a duplicate.
    let current = instance(pid: 200, at: installed, launchedAfter: 60)
    let elsewhere = instance(pid: 100, at: derived, launchedAfter: 0)
    #expect(SingleInstanceGuard.peerToYieldTo(current: current, peers: [elsewhere]) == nil)
}

@Test func picksTheOldestWhenSeveralSiblingsQualify() {
    let current = instance(pid: 300, launchedAfter: 90)
    let oldest = instance(pid: 100, launchedAfter: 0)
    let middle = instance(pid: 200, launchedAfter: 45)
    #expect(SingleInstanceGuard.peerToYieldTo(current: current, peers: [middle, oldest]) == oldest)
}

@Test func aSiblingListedAsItselfIsNotAPeer() {
    // Defensive: the running-applications list can include the current process.
    let current = instance(pid: 100, launchedAfter: 0)
    let selfEntry = instance(pid: 100, launchedAfter: 0)
    #expect(SingleInstanceGuard.peerToYieldTo(current: current, peers: [selfEntry]) == nil)
}

@Test func aTiedLaunchDateNeverYields() {
    // Equal timestamps mean neither can prove it is the newcomer: both stay up
    // rather than risk both quitting.
    let current = instance(pid: 200, launchedAfter: 10)
    let tied = instance(pid: 100, launchedAfter: 10)
    #expect(SingleInstanceGuard.peerToYieldTo(current: current, peers: [tied]) == nil)
}

@Test func aCopyThatCannotDateItselfKeepsRunning() {
    let current = SingleInstanceGuard.Instance(pid: 200, bundleURL: installed, launchDate: nil)
    let older = instance(pid: 100, launchedAfter: 0)
    #expect(SingleInstanceGuard.peerToYieldTo(current: current, peers: [older]) == nil)
}
