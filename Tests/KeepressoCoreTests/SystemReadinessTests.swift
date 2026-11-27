import Testing
import Foundation
@testable import KeepressoCore

private final class FakeProbe: SystemProbing, @unchecked Sendable {
    var snapshotToReturn: SystemSnapshot
    init(_ snapshot: SystemSnapshot) { snapshotToReturn = snapshot }
    func snapshot() -> SystemSnapshot { snapshotToReturn }
}

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
    let onlyDisplaySleep = " displaysleep         10\n disksleep            10"
    #expect(PMSet.value(forKey: "sleep", in: onlyDisplaySleep) == nil)
}


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


@Test func remoteAccessOffIsTipWithSharingLink() {
    let checks = ReadinessCheck.evaluate(
        SystemSnapshot(remoteLogin: false, screenSharing: false)
    )
    #expect(check(checks, "remote-login").status == .tip)
    #expect(check(checks, "screen-sharing").status == .tip)
    #expect(check(checks, "remote-login").remediation?.settingsURL != nil)
}

@Test func remoteAccessUndetectableIsTip() {
    let checks = ReadinessCheck.evaluate(SystemSnapshot())
    #expect(check(checks, "remote-login").status == .tip)
    #expect(check(checks, "screen-sharing").status == .tip)
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
    #expect(check(checks, "system-sleep").remediation != nil)
}


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


@Test func tokenstatSuggestionIsATipWithLink() {
    let tip = ReadinessCheck.tokenstatSuggestion()
    #expect(tip.status == .tip)
    let links = tip.remediation?.links ?? []
    #expect(links.count == 1)
    #expect(links.contains { $0.url.absoluteString == "https://tokenstat.ai" })
    #expect(tip.remediation?.command == nil)
}


@MainActor
@Test func controllerRefreshPopulatesChecks() async {
    let probe = FakeProbe(headlessReadySnapshot)
    let controller = SystemReadinessController(probe: probe)
    #expect(controller.checks.isEmpty)
    await controller.refresh()
    #expect(controller.checks.count == 8)
    #expect(controller.checks.filter { $0.status != .tip }.allSatisfy { $0.status == .ok })
    #expect(controller.checks.last?.id == "tip-tokenstat")
}

@MainActor
@Test func tipsAreConsecutive() async {
    let probe = FakeProbe(SystemSnapshot(
        pmset: pmsetHeadlessReady, fileVault: "FileVault is Off.", autoLoginUser: "mini",
        remoteLogin: false, screenSharing: false
    ))
    let controller = SystemReadinessController(probe: probe)
    await controller.refresh()
    let ids = controller.checks.map(\.id)
    let i = ids.firstIndex(of: "remote-login")!
    #expect(Array(ids[i...(i + 2)]) == ["remote-login", "screen-sharing", "tip-tokenstat"])
}

@MainActor
@Test func controllerAppendsPermissionChecks() async {
    let probe = FakeProbe(headlessReadySnapshot)
    let controller = SystemReadinessController(probe: probe)
    await controller.refresh()
    controller.permissionChecks = [
        ReadinessCheck(id: "perm-login-item", title: "Launch at login", status: .warning, detail: "Off.")
    ]
    #expect(controller.checks.count == 9)
    #expect(controller.checks.contains { $0.id == "tip-tokenstat" })
    #expect(controller.checks.last?.id == "perm-login-item")
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
