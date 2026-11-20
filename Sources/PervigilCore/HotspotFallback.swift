import Foundation
import Observation

public struct HotspotFallbackConfig: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, CaseIterable, Sendable {
        case activeSession, closedDisplay, always
    }
    public var enabled = false
    public var ssid = ""
    public var scope: Scope = .activeSession
    public var delaySeconds: TimeInterval = 10
    public var retrySeconds: TimeInterval = 30
    public var minimumBatteryPercent = 20
    public var notifyOnConnect = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        ssid = try values.decodeIfPresent(String.self, forKey: .ssid) ?? defaults.ssid
        scope = try values.decodeIfPresent(Scope.self, forKey: .scope) ?? defaults.scope
        delaySeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .delaySeconds) ?? defaults.delaySeconds
        retrySeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .retrySeconds) ?? defaults.retrySeconds
        minimumBatteryPercent = try values.decodeIfPresent(Int.self, forKey: .minimumBatteryPercent) ?? defaults.minimumBatteryPercent
        notifyOnConnect = try values.decodeIfPresent(Bool.self, forKey: .notifyOnConnect) ?? defaults.notifyOnConnect
        self = normalized()
    }

    public func normalized() -> Self {
        var copy = self
        copy.delaySeconds = delaySeconds.isFinite ? min(120, max(0, delaySeconds)) : 10
        copy.retrySeconds = retrySeconds.isFinite ? min(300, max(15, retrySeconds)) : 30
        copy.minimumBatteryPercent = min(80, max(0, minimumBatteryPercent))
        return copy
    }
}

public struct HotspotConditions: Equatable, Sendable {
    public var sessionActive: Bool
    public var lidClosed: Bool
    public var closedDisplayActive: Bool
    public var onBattery: Bool
    public var powerKnown: Bool
    public var batteryPercent: Int?
    public init(sessionActive: Bool, lidClosed: Bool, closedDisplayActive: Bool,
                onBattery: Bool, batteryPercent: Int?, powerKnown: Bool = true) {
        self.sessionActive = sessionActive
        self.lidClosed = lidClosed
        self.closedDisplayActive = closedDisplayActive
        self.onBattery = onBattery
        self.powerKnown = powerKnown
        self.batteryPercent = batteryPercent
    }
    public func allows(_ config: HotspotFallbackConfig) -> Bool {
        guard config.enabled, !config.ssid.isEmpty, config.ssid.utf8.count <= 32 else { return false }
        if config.minimumBatteryPercent > 0, !powerKnown { return false }
        if onBattery, config.minimumBatteryPercent > 0 {
            guard let batteryPercent, batteryPercent >= config.minimumBatteryPercent else { return false }
        }
        switch config.scope {
        case .activeSession: return sessionActive
        case .closedDisplay: return lidClosed && closedDisplayActive
        case .always: return true
        }
    }
}

public struct HotspotNetworkState: Equatable, Sendable {
    public var wifiPowered: Bool
    /// nil until the route monitor has its first result. An unknown path never triggers a switch.
    public var hasRoute: Bool?
    public var ssid: String?
    public init(wifiPowered: Bool, hasRoute: Bool?, ssid: String?) {
        self.wifiPowered = wifiPowered
        self.hasRoute = hasRoute
        self.ssid = ssid
    }
}

/// Pure grace/retry policy. A recovered route or an ineligible session resets the outage.
public struct HotspotFallbackPolicy: Sendable {
    private var offlineSince: Date?
    private var lastAttempt: Date?
    public init() {}
    public mutating func reset() { offlineSince = nil; lastAttempt = nil }
    public mutating func shouldConnect(config: HotspotFallbackConfig, conditions: HotspotConditions,
                                       network: HotspotNetworkState, now: Date) -> Bool {
        guard conditions.allows(config), network.wifiPowered, network.hasRoute == false,
              network.ssid != config.ssid else { reset(); return false }
        if offlineSince == nil { offlineSince = now }
        guard now.timeIntervalSince(offlineSince!) >= config.delaySeconds else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < config.retrySeconds { return false }
        lastAttempt = now
        return true
    }
}

public protocol HotspotNetworking: Sendable {
    func snapshot() -> HotspotNetworkState
    func nearbyNetworks() throws -> [String]
    /// Recheck route and cancellation after scanning, immediately before association.
    func connect(ssid: String, password: String) throws
}

public protocol HotspotCredentialStoring: Sendable {
    func password(for ssid: String) throws -> String?
    func save(password: String, for ssid: String) throws
    func removePassword(for ssid: String) throws
}

@MainActor @Observable
public final class HotspotFallbackController {
    public enum Status: Equatable, Sendable {
        case off, waiting, monitoring, wifiOff, connecting, connected, needsPassword
        case failed(String)
    }
    public var config = HotspotFallbackConfig() {
        didSet {
            if config != oldValue {
                policy.reset(); task?.cancel(); lastPoll = nil; retryImmediately = false
                status = config.enabled ? .waiting : .off
            }
        }
    }
    public private(set) var status: Status = .off
    public private(set) var nearby: [String] = []
    public private(set) var scanning = false
    public private(set) var scanError: String?
    public var onConnected: ((String) -> Void)?
    @ObservationIgnored private let network: HotspotNetworking
    @ObservationIgnored private let credentials: HotspotCredentialStoring
    @ObservationIgnored private var policy = HotspotFallbackPolicy()
    @ObservationIgnored private var retryImmediately = false
    @ObservationIgnored private var lastPoll: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(network: HotspotNetworking, credentials: HotspotCredentialStoring) {
        self.network = network
        self.credentials = credentials
    }
    public func tick(conditions: HotspotConditions, now: Date = Date()) {
        guard conditions.allows(config) else {
            task?.cancel(); policy.reset(); lastPoll = nil; retryImmediately = false
            status = config.enabled ? .waiting : .off
            return
        }
        guard task == nil, lastPoll.map({ now.timeIntervalSince($0) >= 5 }) ?? true else { return }
        lastPoll = now
        var nextConfig = config.normalized()
        if retryImmediately { nextConfig.delaySeconds = 0; retryImmediately = false }
        let config = nextConfig
        task = Task { [weak self, network, credentials] in
            guard let self else { return }
            defer { self.task = nil }
            let state = await Task.detached { network.snapshot() }.value
            guard !Task.isCancelled else { return }
            if state.ssid == config.ssid && state.hasRoute == true { self.status = .connected; return }
            guard self.policy.shouldConnect(config: config, conditions: conditions, network: state, now: now) else {
                // Keep a failure visible during this outage's retry interval.
                // A recovered route or powered-off radio gets a fresh status.
                if state.wifiPowered && state.hasRoute == false && state.ssid != config.ssid {
                    switch self.status {
                    case .failed, .needsPassword: return
                    default: break
                    }
                }
                self.status = state.wifiPowered ? .monitoring : .wifiOff
                return
            }
            self.status = .connecting
            // The worker itself is cancelled too, so it can stop after its blocking Wi-Fi scan.
            let worker = Task.detached { () -> Result<Void, Error> in
                do {
                    guard let password = try credentials.password(for: config.ssid), !password.isEmpty else {
                        throw HotspotWiFiError.missingPassword
                    }
                    try Task.checkCancellation()
                    try network.connect(ssid: config.ssid, password: password)
                    return .success(())
                } catch { return .failure(error) }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                self.status = .connected
                if config.notifyOnConnect { self.onConnected?(config.ssid) }
            case .failure(HotspotWiFiError.missingPassword): self.status = .needsPassword
            case .failure(let error): self.status = .failed(error.localizedDescription)
            }
        }
    }
    public func scan() async {
        guard !scanning else { return }
        scanning = true; scanError = nil
        defer { scanning = false }
        let result = await Task.detached { [network] in Result { try network.nearbyNetworks() } }.value
        switch result {
        case .success(let names): nearby = names
        case .failure(let error): scanError = error.localizedDescription
        }
    }
    public func retryNow() { policy.reset(); lastPoll = nil; retryImmediately = true }
}
