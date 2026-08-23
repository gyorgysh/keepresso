import Foundation
import Darwin
import CoreWLAN
import Observation

/// Result of GET `http://captive.apple.com/hotspot-detect.html` with redirects
/// not followed.
public enum CaptiveHTTPResult: Equatable, Sendable {
    /// Body contained Apple's "Success" token: the network has internet.
    case success
    /// 3xx or an HTML login page. `location` is the portal URL when present.
    case portal(status: Int, location: String?)
    case timeout
    case failed
}

public enum CaptivePathStatus: Equatable, Sendable {
    case satisfied
    case constrained
    case expensive
    case unsatisfied
}

/// Raw inputs of the Public Wi-Fi assistant, before interpretation. Same split
/// as ``SystemSnapshot``: the impure probe gathers, a pure evaluator judges.
public struct CaptiveSnapshot: Equatable, Sendable {
    public var wifiPowered: Bool?
    /// Associated to an AP, judged without reading the SSID (Location-gated).
    public var associated: Bool?
    /// Only filled when Location is already granted. Opening the window must
    /// not request it.
    public var ssid: String?
    public var ipv4: String?
    public var ipv6: String?
    public var http: CaptiveHTTPResult?
    public var dnsResolved: Bool?
    public var nameservers: [String]
    public var router: String?
    public var vpnConnected: Bool
    public var path: CaptivePathStatus?
    /// BSD device of the Wi-Fi service (`en0`), for power-cycle commands.
    public var wifiDevice: String?

    public init(
        wifiPowered: Bool? = nil,
        associated: Bool? = nil,
        ssid: String? = nil,
        ipv4: String? = nil,
        ipv6: String? = nil,
        http: CaptiveHTTPResult? = nil,
        dnsResolved: Bool? = nil,
        nameservers: [String] = [],
        router: String? = nil,
        vpnConnected: Bool = false,
        path: CaptivePathStatus? = nil,
        wifiDevice: String? = nil
    ) {
        self.wifiPowered = wifiPowered
        self.associated = associated
        self.ssid = ssid
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.http = http
        self.dnsResolved = dnsResolved
        self.nameservers = nameservers
        self.router = router
        self.vpnConnected = vpnConnected
        self.path = path
        self.wifiDevice = wifiDevice
    }

    /// One-line dump for the Copy diagnostics button. No passwords.
    public var diagnosticsText: String {
        var lines: [String] = []
        if let ssid { lines.append("SSID: \(ssid)") }
        else { lines.append("SSID: (not available)") }
        lines.append("Wi-Fi powered: \(wifiPowered.map(String.init) ?? "unknown")")
        lines.append("Associated: \(associated.map(String.init) ?? "unknown")")
        lines.append("IPv4: \(ipv4 ?? "none")")
        lines.append("IPv6: \(ipv6 ?? "none")")
        switch http {
        case .success: lines.append("Captive HTTP: Success")
        case .portal(let status, let location):
            lines.append("Captive HTTP: portal \(status)")
            if let location { lines.append("Location: \(location)") }
        case .timeout: lines.append("Captive HTTP: timeout")
        case .failed: lines.append("Captive HTTP: failed")
        case nil: lines.append("Captive HTTP: (not probed)")
        }
        lines.append("DNS resolved: \(dnsResolved.map(String.init) ?? "unknown")")
        if nameservers.isEmpty {
            lines.append("DNS servers: (none)")
        } else {
            lines.append("DNS servers: \(nameservers.joined(separator: ", "))")
        }
        if let router { lines.append("Router: \(router)") }
        lines.append("VPN: \(vpnConnected ? "on" : "off")")
        if let path { lines.append("Path: \(String(describing: path))") }
        if let wifiDevice { lines.append("Wi-Fi device: \(wifiDevice)") }
        return lines.joined(separator: "\n")
    }
}

/// System-touching seam: gathers a ``CaptiveSnapshot``. Mirrors ``SystemProbing``.
public protocol CaptiveProbing: AnyObject, Sendable {
    func snapshot() -> CaptiveSnapshot
}

public extension ReadinessCheck {
    /// Interpret a ``CaptiveSnapshot`` into the Public Wi-Fi assistant rows.
    static func evaluateCaptive(_ snapshot: CaptiveSnapshot) -> [ReadinessCheck] {
        var rows = [
            wifiRadio(snapshot),
            wifiAssociated(snapshot),
            wifiAddress(snapshot),
            wifiCaptive(snapshot),
            wifiDNS(snapshot),
            wifiPath(snapshot),
        ]
        if snapshot.vpnConnected {
            rows.append(wifiVPNTip())
        }
        rows.append(wifiCustomDNS(snapshot))
        rows.append(wifiPrivateMACTip())
        rows.append(wifiPrivateRelayTip())
        return rows
    }

    static func wifiRadio(_ snapshot: CaptiveSnapshot) -> ReadinessCheck {
        let id = "wifi-radio"
        let title = L("Wi-Fi radio")
        switch snapshot.wifiPowered {
        case true:
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("Wi-Fi is on."))
        case false:
            return ReadinessCheck(
                id: id, title: title, status: .warning,
                detail: L("Wi-Fi is off."),
                remediation: Remediation(
                    hint: L("Turn Wi-Fi on in Control Center or System Settings ▸ Wi-Fi."),
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")
                ))
        case nil:
            return ReadinessCheck(
                id: id, title: title, status: .unknown,
                detail: L("Couldn't read the Wi-Fi radio."))
        }
    }

    static func wifiAssociated(_ snapshot: CaptiveSnapshot) -> ReadinessCheck {
        let id = "wifi-associated"
        let title = L("Associated")
        if snapshot.wifiPowered == false {
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("Wi-Fi is off, so there is no network to join."))
        }
        switch snapshot.associated {
        case true:
            if let ssid = snapshot.ssid {
                return ReadinessCheck(
                    id: id, title: title, status: .ok,
                    detail: L("Joined %@.", ssid))
            }
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("Joined a Wi-Fi network."))
        case false:
            return ReadinessCheck(
                id: id, title: title, status: .warning,
                detail: L("Wi-Fi is on but not associated to a network."),
                remediation: Remediation(
                    hint: L("Pick the network in Control Center or System Settings ▸ Wi-Fi."),
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")
                ))
        case nil:
            return ReadinessCheck(
                id: id, title: title, status: .unknown,
                detail: L("Couldn't tell whether Wi-Fi is associated."))
        }
    }

    static func wifiAddress(_ snapshot: CaptiveSnapshot) -> ReadinessCheck {
        let id = "wifi-address"
        let title = L("IP address")
        if snapshot.associated != true {
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("Not associated, so no address is expected."))
        }
        if snapshot.ipv4 != nil || snapshot.ipv6 != nil {
            let parts = [snapshot.ipv4, snapshot.ipv6].compactMap { $0 }
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("Address: %@.", parts.joined(separator: ", ")))
        }
        return ReadinessCheck(
            id: id, title: title, status: .warning,
            detail: L("Associated, but no IPv4 or IPv6 address yet."),
            remediation: Remediation(
                hint: L("Turn Wi-Fi off and on, or wait a moment for DHCP.")
            ))
    }

    static func wifiCaptive(_ snapshot: CaptiveSnapshot) -> ReadinessCheck {
        let id = "wifi-captive"
        let title = L("Captive portal")
        switch snapshot.http {
        case .success:
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("captive.apple.com returned Success. This network has internet."))
        case .portal(_, let location):
            let whereTo = location.map { L("The login page is %@.", $0) }
                ?? L("The network is asking you to sign in.")
            return ReadinessCheck(
                id: id, title: title, status: .warning,
                detail: whereTo,
                remediation: Remediation(
                    hint: L("Open the login page. If it never appears, try Flush DNS or turn Private Wi-Fi Address off for this network.")
                ))
        case .timeout:
            return ReadinessCheck(
                id: id, title: title, status: .warning,
                detail: L("No path to captive.apple.com (the request timed out)."),
                remediation: Remediation(
                    hint: L("Open the login page anyway. Hotel and airport portals often never auto-launch.")
                ))
        case .failed:
            return ReadinessCheck(
                id: id, title: title, status: .warning,
                detail: L("Couldn't reach captive.apple.com."),
                remediation: Remediation(
                    hint: L("Open the login page, or turn Wi-Fi off and on.")
                ))
        case nil:
            return ReadinessCheck(
                id: id, title: title, status: .unknown,
                detail: L("Captive HTTP was not probed."))
        }
    }

    static func wifiDNS(_ snapshot: CaptiveSnapshot) -> ReadinessCheck {
        let id = "wifi-dns"
        let title = L("DNS")
        if snapshot.associated != true {
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("Not associated, so DNS is not in play."))
        }
        switch snapshot.dnsResolved {
        case true:
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("captive.apple.com resolves."))
        case false:
            return ReadinessCheck(
                id: id, title: title, status: .warning,
                detail: L("Associated, but captive.apple.com does not resolve."),
                remediation: Remediation(
                    hint: L("Flush DNS, or check that this network's DNS servers are reachable."),
                    command: "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
                ))
        case nil:
            return ReadinessCheck(
                id: id, title: title, status: .unknown,
                detail: L("Couldn't check DNS."))
        }
    }

    static func wifiPath(_ snapshot: CaptiveSnapshot) -> ReadinessCheck {
        let id = "wifi-path"
        let title = L("Network path")
        switch snapshot.path {
        case .satisfied:
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("The system path is satisfied."))
        case .constrained:
            return ReadinessCheck(
                id: id, title: title, status: .warning,
                detail: L("The system path is constrained (often a captive portal)."),
                remediation: Remediation(
                    hint: L("Complete the login page, then Re-check.")
                ))
        case .expensive:
            return ReadinessCheck(
                id: id, title: title, status: .tip,
                detail: L("The system path is marked expensive."))
        case .unsatisfied:
            return ReadinessCheck(
                id: id, title: title, status: .warning,
                detail: L("The system path is unsatisfied: no usable route."),
                remediation: Remediation(
                    hint: L("Turn Wi-Fi off and on, or pick the network again.")
                ))
        case nil:
            return ReadinessCheck(
                id: id, title: title, status: .unknown,
                detail: L("Path status was not read."))
        }
    }

    static func wifiVPNTip() -> ReadinessCheck {
        ReadinessCheck(
            id: "wifi-vpn",
            title: L("VPN"),
            status: .tip,
            detail: L("A VPN is connected. Captive portals often fail through a tunnel: the login page never appears, or DNS goes somewhere the portal cannot see."),
            remediation: Remediation(
                hint: L("Disconnect the VPN, open the login page, then reconnect.")
            )
        )
    }

    static func wifiCustomDNS(_ snapshot: CaptiveSnapshot) -> ReadinessCheck {
        let id = "wifi-custom-dns"
        let title = L("Custom DNS")
        let custom = !snapshot.nameservers.isEmpty
            && snapshot.router.map { router in !snapshot.nameservers.contains(router) } ?? false
        if custom {
            return ReadinessCheck(
                id: id, title: title, status: .tip,
                detail: L("DNS servers (%@) are not this network's router. A portal that hijacks DNS will not see those queries.",
                          snapshot.nameservers.joined(separator: ", ")),
                remediation: Remediation(
                    hint: L("Wi-Fi ▸ Details ▸ DNS, and clear custom servers for this network."),
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")
                ))
        }
        if snapshot.nameservers.isEmpty {
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("No DNS servers were listed."))
        }
        return ReadinessCheck(
            id: id, title: title, status: .ok,
            detail: L("DNS servers: %@.", snapshot.nameservers.joined(separator: ", ")))
    }

    static func wifiPrivateMACTip() -> ReadinessCheck {
        ReadinessCheck(
            id: "wifi-private-mac",
            title: L("Private Wi-Fi Address"),
            status: .tip,
            detail: L("A randomized MAC can make a hotel or airport portal fail to recognise this Mac after a reconnect."),
            remediation: Remediation(
                hint: L("Wi-Fi ▸ Details ▸ Private Wi-Fi Address ▸ Off for this network."),
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")
            )
        )
    }

    static func wifiPrivateRelayTip() -> ReadinessCheck {
        ReadinessCheck(
            id: "wifi-private-relay",
            title: L("iCloud Private Relay"),
            status: .tip,
            detail: L("Private Relay can hide the portal's redirect, so Safari never shows the login page."),
            remediation: Remediation(
                hint: L("iCloud ▸ Private Relay, and turn it off for this network."),
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")
            )
        )
    }
}

/// Drives the Public Wi-Fi assistant. Owns no timer; the host calls
/// ``refresh()`` on appear and from Re-check.
@MainActor
@Observable
public final class CaptiveNetworkController {
    public private(set) var checks: [ReadinessCheck] = []
    public private(set) var snapshot = CaptiveSnapshot()
    public private(set) var isRefreshing = false

    private let probe: CaptiveProbing

    public init(probe: CaptiveProbing = SystemCaptiveProbe()) {
        self.probe = probe
    }

    public func refresh() async {
        isRefreshing = true
        let probe = self.probe
        let snap = await Task.detached { probe.snapshot() }.value
        snapshot = snap
        checks = ReadinessCheck.evaluateCaptive(snap)
        isRefreshing = false
    }

    public var portalLocation: String? {
        if case .portal(_, let location) = snapshot.http { return location }
        return nil
    }

    public var captiveDetected: Bool {
        switch snapshot.http {
        case .portal, .timeout: return true
        default: return false
        }
    }
}

/// Real probe. Does not request Location: SSID is read only when
/// ``ssidAllowed`` is already true. HTTP does not follow redirects.
public final class SystemCaptiveProbe: CaptiveProbing, @unchecked Sendable {
    private let ssidAllowed: @Sendable () -> Bool
    private let vpnConnected: @Sendable () -> Bool
    private let httpProbe: @Sendable () -> CaptiveHTTPResult
    private let dnsProbe: @Sendable () -> Bool?
    private let run: (String, [String]) -> String?

    public init(
        ssidAllowed: @escaping @Sendable () -> Bool = { true },
        vpnConnected: (@Sendable () -> Bool)? = nil,
        httpProbe: (@Sendable () -> CaptiveHTTPResult)? = nil,
        dnsProbe: (@Sendable () -> Bool?)? = nil,
        run: @escaping (String, [String]) -> String? = SystemCaptiveProbe.runCommand
    ) {
        self.ssidAllowed = ssidAllowed
        self.vpnConnected = vpnConnected ?? { SCUtilVPNMonitor().isConnected }
        self.httpProbe = httpProbe ?? { SystemCaptiveProbe.probeCaptiveHTTP() }
        self.dnsProbe = dnsProbe ?? { SystemCaptiveProbe.resolveCaptiveHost() }
        self.run = run
    }

    public func snapshot() -> CaptiveSnapshot {
        let iface = CWWiFiClient.shared().interface()
        let powered = iface.map { $0.powerOn() }
        let mode = iface?.interfaceMode()
        let associated: Bool? = mode.map { $0 != .none }
        let device = Self.wifiDevice(fromHardwarePorts: run("/usr/sbin/networksetup", ["-listallhardwareports"]))
            ?? iface?.interfaceName
        let ifconfig = device.flatMap { run("/sbin/ifconfig", [$0]) }
        let ssid = ssidAllowed() ? iface?.ssid() : nil
        let http = httpProbe()
        let router = device.flatMap {
            run("/usr/sbin/ipconfig", ["getoption", $0, "router"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return CaptiveSnapshot(
            wifiPowered: powered,
            associated: associated,
            ssid: ssid,
            ipv4: ifconfig.flatMap { Self.ipv4(inIfconfig: $0) },
            ipv6: ifconfig.flatMap { Self.ipv6(inIfconfig: $0) },
            http: http,
            dnsResolved: dnsProbe(),
            nameservers: Self.nameservers(fromSCUtil: run("/usr/sbin/scutil", ["--dns"])),
            router: router.flatMap { $0.isEmpty ? nil : $0 },
            vpnConnected: vpnConnected(),
            path: Self.pathStatus(from: http, associated: associated),
            wifiDevice: device
        )
    }

    /// GET `http://captive.apple.com/hotspot-detect.html`, no redirects.
    public static func probeCaptiveHTTP() -> CaptiveHTTPResult {
        guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html") else {
            return .failed
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let catcher = RedirectCatcher()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config, delegate: catcher, delegateQueue: nil)
        let box = LockedOutcome()
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            if let urlError = error as? URLError, urlError.code == .timedOut {
                box.settle(.timeout)
            } else if catcher.redirectStatus != nil {
                box.settle(.portal(status: catcher.redirectStatus ?? 302, location: catcher.location))
            } else if let http = response as? HTTPURLResponse {
                let body = data.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
                if (200..<300).contains(http.statusCode),
                   body.range(of: "Success", options: .caseInsensitive) != nil {
                    box.settle(.success)
                } else if (300..<400).contains(http.statusCode) {
                    let location = http.value(forHTTPHeaderField: "Location")
                    box.settle(.portal(status: http.statusCode, location: location))
                } else if http.statusCode == 200, body.range(of: "Success", options: .caseInsensitive) == nil {
                    box.settle(.portal(status: http.statusCode, location: nil))
                } else {
                    box.settle(.failed)
                }
            } else if error != nil {
                box.settle(.timeout)
            } else {
                box.settle(.failed)
            }
            sem.signal()
        }
        task.resume()
        defer { session.finishTasksAndInvalidate() }
        if sem.wait(timeout: .now() + 6) == .timedOut {
            task.cancel()
            return .timeout
        }
        return box.value ?? .failed
    }

    public static func resolveCaptiveHost() -> Bool? {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM, ai_protocol: 0,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo("captive.apple.com", nil, &hints, &result)
        if let result { freeaddrinfo(result) }
        if status == 0 { return true }
        if status == EAI_NONAME || status == EAI_NODATA { return false }
        return nil
    }

    static func wifiDevice(fromHardwarePorts output: String?) -> String? {
        guard let output else { return nil }
        var currentIsWifi = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port: ") {
                let name = line.dropFirst("Hardware Port: ".count).lowercased()
                currentIsWifi = name.contains("wi-fi") || name.contains("airport")
            } else if line.hasPrefix("Device: "), currentIsWifi {
                return String(line.dropFirst("Device: ".count))
            }
        }
        return nil
    }

    static func ipv4(inIfconfig output: String) -> String? {
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("inet "), !line.hasPrefix("inet6") {
                let parts = line.split(separator: " ")
                if parts.count >= 2 { return String(parts[1]) }
            }
        }
        return nil
    }

    static func ipv6(inIfconfig output: String) -> String? {
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("inet6 ") else { continue }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            let addr = String(parts[1]).split(separator: "%").first.map(String.init) ?? String(parts[1])
            if addr.hasPrefix("fe80") { continue }
            return addr
        }
        return nil
    }

    static func nameservers(fromSCUtil output: String?) -> [String] {
        guard let output else { return [] }
        var servers: [String] = []
        var inResolver = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") {
                if inResolver && !servers.isEmpty { break }
                inResolver = true
                continue
            }
            guard inResolver else { continue }
            if line.hasPrefix("nameserver[") {
                if let colon = line.firstIndex(of: ":") {
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { servers.append(value) }
                }
            }
        }
        return servers
    }

    static func pathStatus(from http: CaptiveHTTPResult, associated: Bool?) -> CaptivePathStatus? {
        switch http {
        case .success: return .satisfied
        case .portal: return .constrained
        case .timeout, .failed:
            return associated == true ? .unsatisfied : nil
        }
    }

    public static func runCommand(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(decoding: data, as: UTF8.self)
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}

/// Catches a 3xx without following it, so a portal's Location header is kept.
private final class RedirectCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var location: String?
    var redirectStatus: Int?

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectStatus = response.statusCode
        location = response.value(forHTTPHeaderField: "Location")
        completionHandler(nil)
    }
}

/// Once-settable probe result shared with the waiter.
private final class LockedOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private(set) var value: CaptiveHTTPResult?

    func settle(_ result: CaptiveHTTPResult) {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        value = result
    }
}
