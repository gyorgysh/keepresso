import Testing
import Foundation
@testable import KeepressoCore

private func check(_ checks: [ReadinessCheck], _ id: String) -> ReadinessCheck {
    checks.first { $0.id == id }!
}

@Test func captiveSuccessIsOk() {
    let snap = CaptiveSnapshot(http: .success, path: .satisfied)
    let c = check(ReadinessCheck.evaluateCaptive(snap), "wifi-captive")
    #expect(c.status == .ok)
}

@Test func captiveRedirectIsAWarningWithLoginHint() {
    let snap = CaptiveSnapshot(
        associated: true,
        http: .portal(status: 302, location: "http://login.hotel.example/"),
        path: .constrained
    )
    let checks = ReadinessCheck.evaluateCaptive(snap)
    let c = check(checks, "wifi-captive")
    #expect(c.status == .warning)
    #expect(c.detail.contains("http://login.hotel.example/"))
    #expect(c.remediation != nil)
    #expect(check(checks, "wifi-path").status == .warning)
}

@Test func captiveTimeoutIsNoPathWarning() {
    let snap = CaptiveSnapshot(associated: true, http: .timeout, path: .unsatisfied)
    let c = check(ReadinessCheck.evaluateCaptive(snap), "wifi-captive")
    #expect(c.status == .warning)
    #expect(c.detail.contains("timed out"))
}

@Test func vpnOnAddsATip() {
    let snap = CaptiveSnapshot(http: .portal(status: 302, location: nil), vpnConnected: true)
    let checks = ReadinessCheck.evaluateCaptive(snap)
    #expect(checks.contains { $0.id == "wifi-vpn" && $0.status == .tip })
}

@Test func vpnOffOmitsTheTip() {
    let snap = CaptiveSnapshot(http: .success, vpnConnected: false)
    #expect(!ReadinessCheck.evaluateCaptive(snap).contains { $0.id == "wifi-vpn" })
}

@Test func customDNSIsATipWhenServersAreNotTheRouter() {
    let snap = CaptiveSnapshot(nameservers: ["1.1.1.1"], router: "192.168.1.1")
    let c = check(ReadinessCheck.evaluateCaptive(snap), "wifi-custom-dns")
    #expect(c.status == .tip)
    #expect(c.detail.contains("1.1.1.1"))
}

@Test func routerNameserverIsNotCustomDNS() {
    let snap = CaptiveSnapshot(nameservers: ["192.168.1.1"], router: "192.168.1.1")
    let c = check(ReadinessCheck.evaluateCaptive(snap), "wifi-custom-dns")
    #expect(c.status == .ok)
}

@Test func wifiOffIsAWarningAndAssociationIsSkipped() {
    let snap = CaptiveSnapshot(wifiPowered: false, associated: false)
    let checks = ReadinessCheck.evaluateCaptive(snap)
    #expect(check(checks, "wifi-radio").status == .warning)
    #expect(check(checks, "wifi-associated").status == .ok)
}

@Test func associatedWithoutAddressIsAWarning() {
    let snap = CaptiveSnapshot(associated: true, ipv4: nil, ipv6: nil)
    #expect(check(ReadinessCheck.evaluateCaptive(snap), "wifi-address").status == .warning)
}

@Test func associatedSSIDShowsInTheRow() {
    let snap = CaptiveSnapshot(wifiPowered: true, associated: true, ssid: "Cafe Guest")
    let c = check(ReadinessCheck.evaluateCaptive(snap), "wifi-associated")
    #expect(c.status == .ok)
    #expect(c.detail.contains("Cafe Guest"))
}

@Test func dnsFailureIsAWarningWithFlushCommand() {
    let snap = CaptiveSnapshot(associated: true, dnsResolved: false)
    let c = check(ReadinessCheck.evaluateCaptive(snap), "wifi-dns")
    #expect(c.status == .warning)
    #expect(c.remediation?.command?.contains("dscacheutil") == true)
}

@Test func privateMACAndRelayTipsAlwaysAppear() {
    let ids = Set(ReadinessCheck.evaluateCaptive(CaptiveSnapshot()).map(\.id))
    #expect(ids.contains("wifi-private-mac"))
    #expect(ids.contains("wifi-private-relay"))
}

@Test func wifiDeviceParserPicksTheWiFiPort() {
    let output = """
    Hardware Port: Ethernet
    Device: en1
    Ethernet Address: 11:22:33:44:55:66

    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: aa:bb:cc:dd:ee:ff
    """
    #expect(SystemCaptiveProbe.wifiDevice(fromHardwarePorts: output) == "en0")
}

@Test func ifconfigParsersSkipLinkLocal() {
    let output = """
    inet 10.0.0.12 netmask 0xffffff00 broadcast 10.0.0.255
    inet6 fe80::1%en0 prefixlen 64
    inet6 2001:db8::1 prefixlen 64
    """
    #expect(SystemCaptiveProbe.ipv4(inIfconfig: output) == "10.0.0.12")
    #expect(SystemCaptiveProbe.ipv6(inIfconfig: output) == "2001:db8::1")
}

@Test func scutilNameserversReadTheFirstResolver() {
    let output = """
    resolver #1
      nameserver[0] : 8.8.8.8
      nameserver[1] : 1.1.1.1
    resolver #2
      nameserver[0] : 9.9.9.9
    """
    #expect(SystemCaptiveProbe.nameservers(fromSCUtil: output) == ["8.8.8.8", "1.1.1.1"])
}

@Test func pathStatusFollowsHTTP() {
    #expect(SystemCaptiveProbe.pathStatus(from: .success, associated: true) == .satisfied)
    #expect(SystemCaptiveProbe.pathStatus(from: .portal(status: 302, location: nil), associated: true) == .constrained)
    #expect(SystemCaptiveProbe.pathStatus(from: .timeout, associated: true) == .unsatisfied)
    #expect(SystemCaptiveProbe.pathStatus(from: .timeout, associated: false) == nil)
}

@Test func diagnosticsOmitsPasswordsAndIncludesSSIDWhenKnown() {
    let snap = CaptiveSnapshot(
        wifiPowered: true,
        associated: true,
        ssid: "Airport",
        ipv4: "10.1.2.3",
        http: .portal(status: 302, location: "http://portal.example/"),
        dnsResolved: false,
        nameservers: ["8.8.8.8"],
        vpnConnected: true,
        wifiDevice: "en0"
    )
    let text = snap.diagnosticsText
    #expect(text.contains("SSID: Airport"))
    #expect(text.contains("10.1.2.3"))
    #expect(text.contains("http://portal.example/"))
    #expect(text.contains("VPN: on"))
    #expect(!text.lowercased().contains("password"))
}

private final class FakeCaptiveProbe: CaptiveProbing, @unchecked Sendable {
    var snap = CaptiveSnapshot()
    func snapshot() -> CaptiveSnapshot { snap }
}

@Test @MainActor func controllerUsesTheInjectedProbe() async {
    let probe = FakeCaptiveProbe()
    probe.snap.http = .success
    probe.snap.wifiPowered = true
    probe.snap.associated = true
    probe.snap.ipv4 = "10.0.0.2"
    let controller = CaptiveNetworkController(probe: probe)
    await controller.refresh()
    #expect(check(controller.checks, "wifi-captive").status == .ok)
    #expect(!controller.captiveDetected)
    #expect(controller.portalLocation == nil)
}

@Test @MainActor func controllerSurfacesPortalLocation() async {
    let probe = FakeCaptiveProbe()
    probe.snap.http = .portal(status: 302, location: "http://login.example/")
    let controller = CaptiveNetworkController(probe: probe)
    await controller.refresh()
    #expect(controller.captiveDetected)
    #expect(controller.portalLocation == "http://login.example/")
    #expect(controller.portalURL == URL(string: "http://login.example/"))
}

@Test @MainActor func controllerRejectsUnsafeOrHostlessPortalURLs() async {
    let probe = FakeCaptiveProbe()
    let controller = CaptiveNetworkController(probe: probe)

    for location in [
        "file:///tmp/portal.html",
        "keepresso://stop",
        "javascript:alert(1)",
        "https:///missing-host",
        "not a URL",
    ] {
        probe.snap.http = .portal(status: 302, location: location)
        await controller.refresh()
        #expect(controller.portalURL == nil)
        #expect(controller.portalLocation == nil)
    }

    probe.snap.http = .portal(status: 302, location: "https://login.example/path")
    await controller.refresh()
    #expect(controller.portalURL == URL(string: "https://login.example/path"))
}
