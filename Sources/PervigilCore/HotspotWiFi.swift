import Foundation
import CoreWLAN
import CoreLocation
import Network
import Security
import LocalAuthentication

public enum HotspotWiFiError: Error, LocalizedError {
    case missingPassword, unavailable, locationRequired, networkRecovered, wifiOff
    public var errorDescription: String? {
        switch self {
        case .missingPassword: return L("Save the hotspot password first.")
        case .unavailable: return L("Hotspot not found. Enable Personal Hotspot on your phone.")
        case .locationRequired: return L("Allow Location access to find Wi-Fi networks.")
        case .networkRecovered: return L("A network connection is already available.")
        case .wifiOff: return L("Turn on Wi-Fi to connect to the hotspot.")
        }
    }
}

/// All CoreWLAN work is called off the main actor. No radio power changes and no system auto-join changes.
public final class CoreWLANHotspotNetworking: HotspotNetworking, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private let wifiLock = NSLock()
    private var route: Bool?
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            switch path.status {
            case .satisfied: self.route = true
            case .unsatisfied: self.route = false
            default: self.route = nil
            }
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "io.github.bubb4rd.pervigil.hotspot-route"))
    }
    deinit { monitor.cancel() }
    public func snapshot() -> HotspotNetworkState {
        let iface = CWWiFiClient.shared().interface()
        lock.lock(); let route = route; lock.unlock()
        return HotspotNetworkState(wifiPowered: iface?.powerOn() == true, hasRoute: route, ssid: iface?.ssid())
    }
    private func interface() throws -> CWInterface {
        let authorization = CLLocationManager().authorizationStatus
        guard authorization == .authorizedAlways || authorization == .authorized else {
            throw HotspotWiFiError.locationRequired
        }
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else { throw HotspotWiFiError.wifiOff }
        return iface
    }
    private func isSecure(_ network: CWNetwork) -> Bool {
        network.supportsSecurity(.wpa2Personal) || network.supportsSecurity(.wpa3Personal)
            || network.supportsSecurity(.wpa3Transition)
    }
    public func nearbyNetworks() throws -> [String] {
        wifiLock.lock(); defer { wifiLock.unlock() }
        try Task.checkCancellation()
        let networks = try interface().scanForNetworks(withName: nil)
        return Array(Set(networks.filter(isSecure).compactMap(\.ssid))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
    public func connect(ssid: String, password: String) throws {
        wifiLock.lock(); defer { wifiLock.unlock() }
        try Task.checkCancellation()
        guard snapshot().hasRoute == false else { throw HotspotWiFiError.networkRecovered }
        let iface = try interface()
        let networks = try iface.scanForNetworks(withName: ssid)
        guard let target = networks.filter({ $0.ssid == ssid && isSecure($0) })
            .max(by: { $0.rssiValue < $1.rssiValue }) else { throw HotspotWiFiError.unavailable }
        try Task.checkCancellation()
        guard snapshot().hasRoute == false else { throw HotspotWiFiError.networkRecovered }
        try iface.associate(to: target, password: password)
    }
}

/// App-owned generic-password items. Secrets never enter UserDefaults or settings exports.
public struct KeychainHotspotCredentials: HotspotCredentialStoring {
    public init() {}
    private func query(_ ssid: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.bubb4rd.pervigil.hotspot",
         kSecAttrAccount as String: ssid,
         kSecUseAuthenticationContext as String: context]
    }
    public func password(for ssid: String) throws -> String? {
        var request = query(ssid)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return String(data: data, encoding: .utf8)
    }
    public func save(password: String, for ssid: String) throws {
        let request = query(ssid)
        let value = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(request as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = request.merging(value) { _, new in new }
            item.removeValue(forKey: kSecUseAuthenticationContext as String)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }
    public func removePassword(for ssid: String) throws {
        let status = SecItemDelete(query(ssid) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
        ])
    }
}
