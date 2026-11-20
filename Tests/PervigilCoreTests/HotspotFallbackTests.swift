import Foundation
import Testing
@testable import PervigilCore

private let online = HotspotNetworkState(wifiPowered: true, hasRoute: true, ssid: "Home")
private let offline = HotspotNetworkState(wifiPowered: true, hasRoute: false, ssid: nil)
private let active = HotspotConditions(sessionActive: true, lidClosed: false, closedDisplayActive: false,
                                     onBattery: true, batteryPercent: 80)
private func configured() -> HotspotFallbackConfig {
    var config = HotspotFallbackConfig(); config.enabled = true; config.ssid = "My iPhone"; return config
}
@Test func hotspotWaitsForOutageAndThrottlesRetries() {
    var policy = HotspotFallbackPolicy(); let config = configured(); let now = Date(timeIntervalSince1970: 100)
    #expect({ !policy.shouldConnect(config: config, conditions: active, network: online, now: now) }())
    #expect({ !policy.shouldConnect(config: config, conditions: active, network: offline, now: now) }())
    #expect({ !policy.shouldConnect(config: config, conditions: active, network: offline, now: now.addingTimeInterval(9)) }())
    #expect({ policy.shouldConnect(config: config, conditions: active, network: offline, now: now.addingTimeInterval(10)) }())
    #expect({ !policy.shouldConnect(config: config, conditions: active, network: offline, now: now.addingTimeInterval(39)) }())
    #expect({ policy.shouldConnect(config: config, conditions: active, network: offline, now: now.addingTimeInterval(40)) }())
    #expect({ !policy.shouldConnect(config: config, conditions: active, network: online, now: now.addingTimeInterval(41)) }())
    #expect({ !policy.shouldConnect(config: config, conditions: active, network: offline, now: now.addingTimeInterval(42)) }())
}
@Test func hotspotHonorsScopesAndBatteryGuard() {
    var config = configured(); var conditions = active
    conditions.sessionActive = false
    #expect(!conditions.allows(config))
    config.scope = .always; #expect(conditions.allows(config))
    config.scope = .closedDisplay; conditions.lidClosed = true
    #expect(!conditions.allows(config))
    conditions.closedDisplayActive = true; #expect(conditions.allows(config))
    conditions.batteryPercent = 19; #expect(!conditions.allows(config))
    conditions.batteryPercent = nil; #expect(!conditions.allows(config))
    conditions.onBattery = false; #expect(conditions.allows(config))
    config.enabled = false; #expect(!conditions.allows(config))
}
@Test func hotspotNeverConnectsOnUnknownPathOrWithWifiOff() {
    var config = configured(); config.delaySeconds = 0
    for network in [HotspotNetworkState(wifiPowered: false, hasRoute: false, ssid: nil),
                    HotspotNetworkState(wifiPowered: true, hasRoute: nil, ssid: nil),
                    HotspotNetworkState(wifiPowered: true, hasRoute: false, ssid: config.ssid)] {
        var policy = HotspotFallbackPolicy()
        #expect({ !policy.shouldConnect(config: config, conditions: active, network: network, now: Date()) }())
    }
}
@Test func hotspotSettingsUpgradeAndExportWithoutCredentials() throws {
    let old = try JSONDecoder().decode(PervigilSettings.self, from: Data("{}".utf8))
    #expect(!old.hotspotFallback.enabled); #expect(!old.closedLidLowPower)
    #expect(old.closedLidMinimumFanPercent == nil)
    var settings = old; settings.hotspotFallback = configured(); settings.closedLidLowPower = true
    let data = try SettingsTransfer.exportData(settings)
    #expect(try SettingsTransfer.importSettings(from: data) == settings)
    #expect(!String(decoding: data, as: UTF8.self).contains("password"))
    let corrupt = try JSONDecoder().decode(PervigilSettings.self, from: Data(#"{"hotspotFallback":false,"startOnLaunch":true}"#.utf8))
    #expect(corrupt.startOnLaunch); #expect(!corrupt.hotspotFallback.enabled)
}
@Test func hotspotClampsImportedOptions() {
    var config = configured(); config.delaySeconds = -.infinity; config.retrySeconds = 0; config.minimumBatteryPercent = 110
    let normalized = config.normalized()
    #expect(normalized.delaySeconds == 10); #expect(normalized.retrySeconds == 15)
    #expect(normalized.minimumBatteryPercent == 80)
}

private final class PausedHotspotNetwork: HotspotNetworking, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var connections = 0
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections }
    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 10) == .success }
    func snapshot() -> HotspotNetworkState { offline }
    func nearbyNetworks() throws -> [String] { ["My iPhone"] }
    func connect(ssid: String, password: String) throws {
        started.signal()
        guard proceed.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
        try Task.checkCancellation()
        lock.lock(); connections += 1; lock.unlock()
    }
}
private struct TestHotspotCredentials: HotspotCredentialStoring {
    let stored: String?
    func password(for ssid: String) throws -> String? { stored }
    func save(password: String, for ssid: String) throws {}
    func removePassword(for ssid: String) throws {}
}
@Test @MainActor func hotspotCancelsInFlightAssociationWhenSessionEnds() async throws {
    let network = PausedHotspotNetwork()
    let controller = HotspotFallbackController(network: network, credentials: TestHotspotCredentials(stored: "test-password"))
    var config = configured(); config.delaySeconds = 0; controller.config = config
    controller.tick(conditions: active)
    let started = await Task.detached { network.waitUntilStarted() }.value
    #expect(started)
    var idle = active; idle.sessionActive = false
    controller.tick(conditions: idle)
    network.proceed.signal()
    try await Task.sleep(for: .milliseconds(50))
    #expect(network.connectionCount == 0)
    #expect(controller.status == .waiting)
}
@Test @MainActor func hotspotRetryNowChecksCredentialsImmediately() async throws {
    let network = PausedHotspotNetwork()
    let controller = HotspotFallbackController(network: network, credentials: TestHotspotCredentials(stored: nil))
    controller.config = configured()
    controller.retryNow()
    controller.tick(conditions: active)
    for _ in 0..<100 {
        if controller.status == .needsPassword { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.status == .needsPassword)
    #expect(network.connectionCount == 0)
}

@Test func hotspotPartialConfigurationKeepsSelectedNetworkAndFillsDefaults() throws {
    let config = try JSONDecoder().decode(HotspotFallbackConfig.self, from: Data(#"{"enabled":true,"ssid":"My iPhone"}"#.utf8))
    #expect(config.enabled); #expect(config.ssid == "My iPhone")
    #expect(config.scope == .activeSession); #expect(config.delaySeconds == 10)
    #expect(config.minimumBatteryPercent == 20)
}
@Test func hotspotBatteryMinimumDoesNotTreatUnknownPowerAsAC() {
    var config = configured(); var conditions = active
    conditions.powerKnown = false; conditions.onBattery = false
    #expect(!conditions.allows(config))
    config.minimumBatteryPercent = 0
    #expect(conditions.allows(config))
}
@Test @MainActor func hotspotCredentialFailureStaysVisibleDuringRetryDelay() async throws {
    let network = PausedHotspotNetwork()
    let controller = HotspotFallbackController(network: network, credentials: TestHotspotCredentials(stored: nil))
    controller.config = configured(); controller.retryNow()
    let now = Date(timeIntervalSince1970: 100)
    controller.tick(conditions: active, now: now)
    for _ in 0..<100 {
        if controller.status == .needsPassword { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.status == .needsPassword)
    controller.tick(conditions: active, now: now.addingTimeInterval(5))
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.status == .needsPassword)
}
private struct UnavailableScanNetwork: HotspotNetworking {
    func snapshot() -> HotspotNetworkState { offline }
    func nearbyNetworks() throws -> [String] { throw HotspotWiFiError.unavailable }
    func connect(ssid: String, password: String) throws {}
}
@Test @MainActor func hotspotScanErrorsDoNotOverwriteAutomaticConnectionStatus() async {
    let controller = HotspotFallbackController(network: UnavailableScanNetwork(), credentials: TestHotspotCredentials(stored: nil))
    controller.config = configured()
    await controller.scan()
    #expect(controller.status == .waiting)
    #expect(controller.scanError != nil)
}
