import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Wired-port parsing

private let realHardwarePorts = """
Hardware Port: Ethernet Adapter (en4)
Device: en4
Ethernet Address: ca:31:37:f4:ed:ac

Hardware Port: Thunderbolt Bridge
Device: bridge0
Ethernet Address: 36:02:80:32:e8:c0

Hardware Port: Wi-Fi
Device: en0
Ethernet Address: f4:d4:88:5d:e9:ad

Hardware Port: Thunderbolt 1
Device: en1
Ethernet Address: 36:02:80:32:e8:c0

Hardware Port: Thunderbolt Ethernet
Device: en7
Ethernet Address: 40:6c:8f:11:22:33

Hardware Port: USB 10/100/1000 LAN
Device: en8
Ethernet Address: 00:e0:4c:aa:bb:cc

Hardware Port: iPhone USB
Device: en9
Ethernet Address: aa:bb:cc:dd:ee:ff

Hardware Port: Bluetooth PAN
Device: en10
Ethernet Address: aa:bb:cc:dd:ee:00
"""

@Test func wiredPortParsingKeepsEthernetAndLANOnly() {
    let devices = ReadinessCheck.wiredPortDevices(fromHardwarePorts: realHardwarePorts)
    // Ethernet adapters and LAN dongles are wired candidates; Wi-Fi, bare
    // Thunderbolt ports, bridges, tethered phones, and PAN are not.
    #expect(devices == ["en4", "en7", "en8"])
}

private func ifconfigBlock(_ device: String, status: String?) -> String {
    var block = "\(device): flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n"
    block += "\toptions=6460<TSO4,TSO6>\n"
    block += "\tether ca:31:37:f4:ed:ac\n"
    if let status { block += "\tstatus: \(status)\n" }
    return block
}

@Test func interfaceActivityIsReadPerDeviceBlock() {
    let output = ifconfigBlock("en0", status: "active")
        + ifconfigBlock("en4", status: "inactive")
        + ifconfigBlock("en7", status: "active")
    #expect(ReadinessCheck.isActive(device: "en7", inIfconfig: output))
    #expect(!ReadinessCheck.isActive(device: "en4", inIfconfig: output))
    // en0's active status must not bleed into a device without one.
    #expect(!ReadinessCheck.isActive(device: "en5", inIfconfig: output))
}

// MARK: - Ethernet check

@Test func connectedEthernetIsOK() {
    let snapshot = StreamingSnapshot(
        hardwarePorts: realHardwarePorts,
        ifconfig: ifconfigBlock("en0", status: "active") + ifconfigBlock("en7", status: "active")
    )
    let check = ReadinessCheck.ethernet(snapshot)
    #expect(check.status == .ok)
    #expect(check.detail.contains("en7"))
}

@Test func idleEthernetAdapterIsATip() {
    let snapshot = StreamingSnapshot(
        hardwarePorts: realHardwarePorts,
        ifconfig: ifconfigBlock("en0", status: "active") + ifconfigBlock("en4", status: "inactive")
    )
    #expect(ReadinessCheck.ethernet(snapshot).status == .tip)
}

@Test func missingProbeOutputIsUnknown() {
    #expect(ReadinessCheck.ethernet(StreamingSnapshot()).status == .unknown)
}

// MARK: - Wi-Fi channel check

@Test func band24IsAWarningPointingAtChannel6() {
    let check = ReadinessCheck.wifiChannel(StreamingSnapshot(
        wifiChannel: 11, wifiBand: .ghz2, wifiWidthMHz: 20))
    #expect(check.status == .warning)
    #expect(check.remediation?.hint.contains("channel 6") == true)
}

@Test func alignedSocialChannelIsOK() {
    let us = ReadinessCheck.wifiChannel(StreamingSnapshot(
        wifiChannel: 149, wifiBand: .ghz5, wifiWidthMHz: 80, wifiCountryCode: "US"))
    #expect(us.status == .ok)

    let eu = ReadinessCheck.wifiChannel(StreamingSnapshot(
        wifiChannel: 44, wifiBand: .ghz5, wifiWidthMHz: 80, wifiCountryCode: "DE"))
    #expect(eu.status == .ok)

    // Aligned channel but narrow width: still ok, nudged toward 80 MHz.
    let narrow = ReadinessCheck.wifiChannel(StreamingSnapshot(
        wifiChannel: 149, wifiBand: .ghz5, wifiWidthMHz: 40, wifiCountryCode: "US"))
    #expect(narrow.status == .ok)
    #expect(narrow.detail.contains("80 MHz"))
}

@Test func offSocialChannelRecommendsTheRegionsChannel() {
    let us = ReadinessCheck.wifiChannel(StreamingSnapshot(
        wifiChannel: 36, wifiBand: .ghz5, wifiWidthMHz: 80, wifiCountryCode: "US"))
    #expect(us.status == .tip)
    #expect(us.remediation?.hint.contains("channel 149") == true)

    // Country unreadable (Location-gated): both regions offered, and the
    // aligned-channel fast path must not fire on either.
    let unknown = ReadinessCheck.wifiChannel(StreamingSnapshot(
        wifiChannel: 44, wifiBand: .ghz5, wifiWidthMHz: 80))
    #expect(unknown.status == .tip)
    #expect(unknown.remediation?.hint.contains("44 (most regions) or 149 (US)") == true)
}

@Test func sixGHzAndNoWiFiAreHandled() {
    #expect(ReadinessCheck.wifiChannel(StreamingSnapshot(
        wifiChannel: 37, wifiBand: .ghz6, wifiWidthMHz: 160)).status == .ok)
    #expect(ReadinessCheck.wifiChannel(StreamingSnapshot()).status == .unknown)
}

// MARK: - Bluetooth check

@Test func bluetoothStateIsParsedFromSystemProfilerJSON() {
    // system_profiler is deliberately the source (IOBluetooth/CoreBluetooth
    // would throw the Bluetooth privacy prompt just for the power state).
    let on = """
    {"SPBluetoothDataType": [{"controller_properties": {"controller_state": "attrib_on"}}]}
    """
    let off = """
    {"SPBluetoothDataType": [{"controller_properties": {"controller_state": "attrib_off"}}]}
    """
    #expect(SystemStreamingProbe.parseBluetoothOn(fromProfilerJSON: on) == true)
    #expect(SystemStreamingProbe.parseBluetoothOn(fromProfilerJSON: off) == false)
    #expect(SystemStreamingProbe.parseBluetoothOn(fromProfilerJSON: nil) == nil)
    #expect(SystemStreamingProbe.parseBluetoothOn(fromProfilerJSON: "{}") == nil)
    #expect(SystemStreamingProbe.parseBluetoothOn(fromProfilerJSON: "not json") == nil)
}

@Test func bluetoothStatesMapToTipOKUnknown() {
    #expect(ReadinessCheck.bluetoothRadio(StreamingSnapshot(bluetoothOn: true)).status == .tip)
    #expect(ReadinessCheck.bluetoothRadio(StreamingSnapshot(bluetoothOn: false)).status == .ok)
    #expect(ReadinessCheck.bluetoothRadio(StreamingSnapshot()).status == .unknown)
}

// MARK: - Controller

private final class FakeStreamingProbe: StreamingProbing, @unchecked Sendable {
    var result: StreamingSnapshot
    init(result: StreamingSnapshot) { self.result = result }
    func snapshot() -> StreamingSnapshot { result }
}

@MainActor
@Test func streamingControllerAppendsTheStandingNotes() async {
    let controller = StreamingReadinessController(
        probe: FakeStreamingProbe(result: StreamingSnapshot(bluetoothOn: false)))
    #expect(controller.checks.isEmpty) // blank until the first refresh

    await controller.refresh()
    let ids = controller.checks.map(\.id)
    #expect(ids == [
        "stream-ethernet", "stream-wifi-channel", "stream-bluetooth",
        "stream-game-mode", "stream-browser-gaming",
        "stream-location-note", "stream-read-more",
    ])
    // The read-more note links the blog post the screen is built around.
    let readMore = controller.checks.last!
    #expect(readMore.remediation?.links.first?.url.absoluteString
        == "https://gyorgy.sh/blog/macos-awdl-network-jitter")
}
