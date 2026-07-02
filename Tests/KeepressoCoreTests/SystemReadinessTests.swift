import Testing
import Foundation
@testable import KeepressoCore

/// Probe that returns a canned snapshot, so the readiness logic is exercised
/// without shelling out.
private final class FakeProbe: SystemProbing, @unchecked Sendable {
    var snapshotToReturn: SystemSnapshot
    init(_ snapshot: SystemSnapshot) { snapshotToReturn = snapshot }
    func snapshot() -> SystemSnapshot { snapshotToReturn }
}

/// A representative `pmset -g` block. Indentation and column spacing mimic the
/// real command so the parser is tested against realistic input.
private let pmsetHeadlessReady = """
System-wide power settings:
Currently in use:
 standbydelaylow      10800
 womp                 1
 autorestart          1
 sleep                0
 displaysleep         10
 disksleep            10
"""

private func check(_ checks: [ReadinessCheck], _ id: String) -> ReadinessCheck {
    checks.first { $0.id == id }!
}

// MARK: - pmset parser

@Test func pmsetParsesKeyedIntegers() {
    #expect(PMSet.value(forKey: "womp", in: pmsetHeadlessReady) == 1)
    #expect(PMSet.value(forKey: "sleep", in: pmsetHeadlessReady) == 0)
    #expect(PMSet.value(forKey: "displaysleep", in: pmsetHeadlessReady) == 10)
}

@Test func pmsetMissingKeyIsNil() {
    #expect(PMSet.value(forKey: "ttyskeepawake", in: pmsetHeadlessReady) == nil)
}

@Test func pmsetNilOutputIsNil() {
    #expect(PMSet.value(forKey: "womp", in: nil) == nil)
}

@Test func pmsetDoesNotMatchKeyAsSubstring() {
    // "sleep" must not be satisfied by the "displaysleep"/"disksleep" lines.
    let onlyDisplaySleep = " displaysleep         10\n disksleep            10"
    #expect(PMSet.value(forKey: "sleep", in: onlyDisplaySleep) == nil)
}

// MARK: - Power checks

/// A snapshot where every probed setting is configured the headless-friendly way.
private let headlessReadySnapshot = SystemSnapshot(
    pmset: pmsetHeadlessReady,
    fileVault: "FileVault is Off.",
    autoLoginUser: "mini",
    remoteLogin: true,
    screenSharing: true
)

@Test func headlessReadySystemIsAllOK() {
    let checks = ReadinessCheck.evaluate(headlessReadySnapshot)
    #expect(check(checks, "wake-for-network").status == .ok)
    #expect(check(checks, "auto-restart").status == .ok)
    #expect(check(checks, "system-sleep").status == .ok)
    #expect(check(checks, "filevault").status == .ok)
    #expect(check(checks, "auto-login").status == .ok)
    #expect(check(checks, "remote-login").status == .ok)
    #expect(check(checks, "screen-sharing").status == .ok)
    #expect(checks.allSatisfy { $0.remediation == nil })
}

// MARK: - Remote access

@Test func remoteAccessOffIsTipWithSharingLink() {
    // SSH / Screen Sharing are conveniences, not requirements, so off is a tip.
    let checks = ReadinessCheck.evaluate(
        SystemSnapshot(remoteLogin: false, screenSharing: false)
    )
    #expect(check(checks, "remote-login").status == .tip)
    #expect(check(checks, "screen-sharing").status == .tip)
    #expect(check(checks, "remote-login").remediation?.settingsURL != nil)
}

@Test func remoteAccessUndetectableIsTip() {
    let checks = ReadinessCheck.evaluate(SystemSnapshot()) // both nil
    #expect(check(checks, "remote-login").status == .tip)
    #expect(check(checks, "screen-sharing").status == .tip)
    // The tip still guides the user to Sharing.
    #expect(check(checks, "remote-login").remediation != nil)
}

@Test func wakeForNetworkOffWarnsWithRemediation() {
    let pmset = pmsetHeadlessReady.replacingOccurrences(of: "womp                 1", with: "womp                 0")
    let c = check(ReadinessCheck.evaluate(SystemSnapshot(pmset: pmset)), "wake-for-network")
    #expect(c.status == .warning)
    #expect(c.remediation?.command == "sudo pmset -a womp 1")
    #expect(c.remediation?.settingsURL != nil)
}

@Test func autoRestartOffWarns() {
    let pmset = pmsetHeadlessReady.replacingOccurrences(of: "autorestart          1", with: "autorestart          0")
    let c = check(ReadinessCheck.evaluate(SystemSnapshot(pmset: pmset)), "auto-restart")
    #expect(c.status == .warning)
    #expect(c.remediation?.command == "sudo pmset -a autorestart 1")
}

@Test func systemSleepEnabledWarns() {
    let pmset = pmsetHeadlessReady.replacingOccurrences(of: "sleep                0", with: "sleep                1")
    let c = check(ReadinessCheck.evaluate(SystemSnapshot(pmset: pmset)), "system-sleep")
    #expect(c.status == .warning)
    #expect(c.remediation?.command == "sudo pmset -a sleep 0")
}

@Test func missingPmsetIsUnknown() {
    let checks = ReadinessCheck.evaluate(SystemSnapshot(pmset: nil))
    #expect(check(checks, "wake-for-network").status == .unknown)
    #expect(check(checks, "auto-restart").status == .unknown)
    #expect(check(checks, "system-sleep").status == .unknown)
    // Unknown still offers remediation guidance.
    #expect(check(checks, "system-sleep").remediation != nil)
}

// MARK: - FileVault

@Test func fileVaultOnWarns() {
    let c = check(ReadinessCheck.evaluate(SystemSnapshot(fileVault: "FileVault is On.")), "filevault")
    #expect(c.status == .warning)
    #expect(c.remediation?.settingsURL != nil)
}

@Test func fileVaultOffIsOK() {
    let c = check(ReadinessCheck.evaluate(SystemSnapshot(fileVault: "FileVault is Off.")), "filevault")
    #expect(c.status == .ok)
    #expect(c.remediation == nil)
}

@Test func fileVaultUnreadableIsUnknown() {
    let c = check(ReadinessCheck.evaluate(SystemSnapshot(fileVault: nil)), "filevault")
    #expect(c.status == .unknown)
}

// MARK: - Auto-login

@Test func autoLoginSetIsOK() {
    let c = check(ReadinessCheck.evaluate(SystemSnapshot(autoLoginUser: "mini")), "auto-login")
    #expect(c.status == .ok)
    #expect(c.detail.contains("mini"))
}

@Test func autoLoginUnsetWarns() {
    let c = check(ReadinessCheck.evaluate(SystemSnapshot(autoLoginUser: nil)), "auto-login")
    #expect(c.status == .warning)
    #expect(c.remediation != nil)
}

@Test func autoLoginBlankWarns() {
    let c = check(ReadinessCheck.evaluate(SystemSnapshot(autoLoginUser: "  \n")), "auto-login")
    #expect(c.status == .warning)
}

// MARK: - Standing tip

@Test func myAgensSuggestionIsATipWithLinks() {
    let tip = ReadinessCheck.myAgensSuggestion()
    #expect(tip.status == .tip)
    let links = tip.remediation?.links ?? []
    #expect(links.count == 2)
    #expect(links.contains { $0.url.absoluteString == "https://github.com/gyorgysh/myagens" })
    #expect(links.contains { $0.url.absoluteString == "https://gyorgy.sh/blog/myagens" })
    #expect(tip.remediation?.command == nil) // links, not a shell command
}

// MARK: - Controller

@MainActor
@Test func controllerRefreshPopulatesChecks() async {
    let probe = FakeProbe(headlessReadySnapshot)
    let controller = SystemReadinessController(probe: probe)
    #expect(controller.checks.isEmpty) // nothing until refresh
    await controller.refresh()
    // 7 system checks + the standing MyAgens tip.
    #expect(controller.checks.count == 8)
    #expect(controller.checks.filter { $0.status != .tip }.allSatisfy { $0.status == .ok })
    #expect(controller.checks.last?.id == "tip-myagens") // tip after the system checks
}

@MainActor
@Test func tipsAreConsecutive() async {
    // SSH + Screen Sharing off → both tips; the MyAgens tip should sit right after them.
    let probe = FakeProbe(SystemSnapshot(
        pmset: pmsetHeadlessReady, fileVault: "FileVault is Off.", autoLoginUser: "mini",
        remoteLogin: false, screenSharing: false
    ))
    let controller = SystemReadinessController(probe: probe)
    await controller.refresh()
    let ids = controller.checks.map(\.id)
    let i = ids.firstIndex(of: "remote-login")!
    #expect(Array(ids[i...(i + 2)]) == ["remote-login", "screen-sharing", "tip-myagens"])
}

@MainActor
@Test func controllerAppendsPermissionChecks() async {
    let probe = FakeProbe(headlessReadySnapshot)
    let controller = SystemReadinessController(probe: probe)
    await controller.refresh()
    controller.permissionChecks = [
        ReadinessCheck(id: "perm-login-item", title: "Launch at login", status: .warning, detail: "Off.")
    ]
    // 7 system + 1 tip + 1 permission.
    #expect(controller.checks.count == 9)
    #expect(controller.checks.contains { $0.id == "tip-myagens" })
    #expect(controller.checks.last?.id == "perm-login-item") // permission checks come last
    // A later system refresh keeps the permission checks in place.
    await controller.refresh()
    #expect(controller.checks.contains { $0.id == "perm-login-item" })
}

@MainActor
@Test func controllerReReadsOnEachRefresh() async {
    let probe = FakeProbe(SystemSnapshot(pmset: pmsetHeadlessReady, fileVault: "FileVault is On.", autoLoginUser: nil))
    let controller = SystemReadinessController(probe: probe)
    await controller.refresh()
    #expect(check(controller.checks, "filevault").status == .warning)

    probe.snapshotToReturn = SystemSnapshot(pmset: pmsetHeadlessReady, fileVault: "FileVault is Off.", autoLoginUser: "mini")
    await controller.refresh()
    #expect(check(controller.checks, "filevault").status == .ok)
}
