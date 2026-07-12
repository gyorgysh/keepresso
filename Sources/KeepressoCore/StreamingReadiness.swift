import Foundation
import Observation
import CoreWLAN

/// Which Wi-Fi band the current association uses.
public enum WiFiBand: Equatable, Sendable {
    case ghz2, ghz5, ghz6
}

/// Raw inputs of the Gaming & Streaming checks, before interpretation. Same
/// split as ``SystemSnapshot``: the impure probe gathers, a pure evaluator
/// judges, tests feed literals.
public struct StreamingSnapshot: Equatable, Sendable {
    /// Current Wi-Fi channel number, or `nil` when not associated (or Wi-Fi
    /// is off). Channel details don't need Location access; the SSID does.
    public var wifiChannel: Int?
    public var wifiBand: WiFiBand?
    public var wifiWidthMHz: Int?
    /// The regulatory country code (e.g. "US"), `nil` when unreadable
    /// (it's Location-gated on modern macOS).
    public var wifiCountryCode: String?
    /// stdout of `networksetup -listallhardwareports`.
    public var hardwarePorts: String?
    /// stdout of `ifconfig -a`.
    public var ifconfig: String?
    /// Whether the Bluetooth radio is powered on.
    public var bluetoothOn: Bool?

    public init(
        wifiChannel: Int? = nil,
        wifiBand: WiFiBand? = nil,
        wifiWidthMHz: Int? = nil,
        wifiCountryCode: String? = nil,
        hardwarePorts: String? = nil,
        ifconfig: String? = nil,
        bluetoothOn: Bool? = nil
    ) {
        self.wifiChannel = wifiChannel
        self.wifiBand = wifiBand
        self.wifiWidthMHz = wifiWidthMHz
        self.wifiCountryCode = wifiCountryCode
        self.hardwarePorts = hardwarePorts
        self.ifconfig = ifconfig
        self.bluetoothOn = bluetoothOn
    }
}

/// System-touching seam: gathers a ``StreamingSnapshot``. Mirrors
/// ``SystemProbing``.
public protocol StreamingProbing: AnyObject, Sendable {
    func snapshot() -> StreamingSnapshot
}

public extension ReadinessCheck {
    /// Interpret a ``StreamingSnapshot`` into the check rows of the Gaming &
    /// Streaming Setup screen. Pure: the unit under test.
    static func evaluateStreaming(_ snapshot: StreamingSnapshot) -> [ReadinessCheck] {
        [
            ethernet(snapshot),
            wifiChannel(snapshot),
            bluetoothRadio(snapshot),
        ]
    }

    // MARK: - Ethernet (the reliable fix)

    static func ethernet(_ snapshot: StreamingSnapshot) -> ReadinessCheck {
        let id = "stream-ethernet"
        let title = L("Wired network")
        guard let ports = snapshot.hardwarePorts, let ifconfig = snapshot.ifconfig else {
            return ReadinessCheck(
                id: id, title: title, status: .unknown,
                detail: L("Couldn't read the network interfaces.")
            )
        }
        let wired = wiredPortDevices(fromHardwarePorts: ports)
        if let active = wired.first(where: { isActive(device: $0, inIfconfig: ifconfig) }) {
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("Ethernet is connected (%@). A wired link sidesteps Wi-Fi jitter entirely, the most reliable fix.", active)
            )
        }
        if !wired.isEmpty {
            return ReadinessCheck(
                id: id, title: title, status: .tip,
                detail: L("An Ethernet adapter is available but no cable is connected."),
                remediation: Remediation(
                    hint: L("For gaming or streaming, a wired connection beats any Wi-Fi tuning.")
                )
            )
        }
        return ReadinessCheck(
            id: id, title: title, status: .tip,
            detail: L("No wired network adapter found."),
            remediation: Remediation(
                hint: L("A USB-C or Thunderbolt Ethernet adapter sidesteps Wi-Fi jitter entirely.")
            )
        )
    }

    /// Devices of hardware ports that are wired network ports: named like
    /// Ethernet/LAN, excluding Wi-Fi, Bluetooth PAN, bridges, and tethered
    /// devices. ("Thunderbolt Ethernet" adapters stay in; bare "Thunderbolt N"
    /// ports carry neither keyword and fall out on their own.)
    static func wiredPortDevices(fromHardwarePorts output: String) -> [String] {
        var devices: [String] = []
        var currentPortIsWired = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port: ") {
                currentPortIsWired = isWiredPortName(String(line.dropFirst("Hardware Port: ".count)))
            } else if line.hasPrefix("Device: "), currentPortIsWired {
                devices.append(String(line.dropFirst("Device: ".count)))
            }
        }
        return devices
    }

    private static func isWiredPortName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let excluded = ["wi-fi", "airport", "bluetooth", "bridge", "iphone", "ipad", "vlan"]
        guard !excluded.contains(where: lower.contains) else { return false }
        return lower.contains("ethernet") || lower.contains("lan")
    }

    /// Whether a device's `ifconfig -a` block reports `status: active`
    /// (a cable with link, not just a known adapter).
    static func isActive(device: String, inIfconfig output: String) -> Bool {
        var inBlock = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("\(device): ") {
                inBlock = true
                continue
            }
            guard inBlock else { continue }
            // The next interface starts at column zero; the block is over.
            if !line.hasPrefix("\t"), !line.hasPrefix(" ") { break }
            if line.trimmingCharacters(in: .whitespaces) == "status: active" { return true }
        }
        return false
    }

    // MARK: - Wi-Fi channel vs AWDL's social channels

    /// AWDL parks its off-channel hops on fixed "social channels": 6 on
    /// 2.4 GHz, and on 5 GHz either 44 (EU) or 149 (the US, Canada, and other
    /// regions that allow UNII-3). A router aligned with the right one keeps the
    /// hop on-channel, so it stops costing a retune. 6 GHz has no social channel.
    static func wifiChannel(_ snapshot: StreamingSnapshot) -> ReadinessCheck {
        let id = "stream-wifi-channel"
        let title = L("Wi-Fi channel")
        guard let channel = snapshot.wifiChannel, let band = snapshot.wifiBand else {
            return ReadinessCheck(
                id: id, title: title, status: .unknown,
                detail: L("Not connected to Wi-Fi, or its details are unreadable."),
                remediation: Remediation(
                    hint: L("If you game or stream over Wi-Fi, re-check while connected.")
                )
            )
        }
        // "channel 6" or "channel 6 at 80 MHz", the shared clause every
        // sentence below builds on.
        let channelClause: String = snapshot.wifiWidthMHz.map {
            L("channel %d at %d MHz", channel, $0)
        } ?? L("channel %d", channel)

        let five = Self.social5GHzChannel(countryCode: snapshot.wifiCountryCode)
        switch band {
        case .ghz2:
            return ReadinessCheck(
                id: id, title: title, status: .warning,
                detail: L("On 2.4 GHz (%@), the slowest band, where every AWDL hop costs the most.", channelClause),
                remediation: Remediation(
                    hint: L("Prefer a 5 GHz network on %@ at 80 MHz. If 2.4 GHz is unavoidable, set the router to channel 6, AWDL's 2.4 GHz social channel.", five.description)
                )
            )
        case .ghz6:
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("On 6 GHz (%@). AWDL's social channels live on 2.4 and 5 GHz, so there's nothing to align here. If stutter persists, a 5 GHz network on %@ keeps AWDL's hops on-channel.", channelClause, five.description)
            )
        case .ghz5:
            if let target = five.channel, channel == target {
                let detail: String
                if (snapshot.wifiWidthMHz ?? 80) >= 80 {
                    detail = L("On %@, aligned with AWDL's 5 GHz social channel, so its hops stay on-channel.", channelClause)
                } else {
                    detail = L("On %@, aligned with AWDL's 5 GHz social channel, so its hops stay on-channel. Raising the router to 80 MHz width completes the alignment.", channelClause)
                }
                return ReadinessCheck(
                    id: id, title: title, status: .ok,
                    detail: detail
                )
            }
            return ReadinessCheck(
                id: id, title: title, status: .tip,
                detail: L("On 5 GHz %@. AWDL's off-channel hops leave this channel roughly every second.", channelClause),
                remediation: Remediation(
                    hint: L("Set the router to %@ at 80 MHz so AWDL's hops stay on-channel.", five.description)
                )
            )
        }
    }

    /// AWDL's 5 GHz social channel is region-dependent: 44 in the EU and other
    /// regions that don't permit the UNII-3 band, 149 where UNII-3 is allowed
    /// (the US, Canada, and much of the world). Returns the aligned channel (or
    /// `nil` when the region is unknown, so alignment can't be confirmed) plus a
    /// human phrase naming it. The country read is Location-gated, so when it's
    /// unavailable both channels are named and no alignment is claimed.
    static func social5GHzChannel(countryCode: String?) -> (channel: Int?, description: String) {
        guard let code = countryCode?.uppercased() else {
            return (nil, L("channel 44 (the EU social channel) or 149 (the US and Canada social channel), whichever your region allows"))
        }
        if euCountryCodes.contains(code) {
            return (44, L("channel 44, AWDL's 5 GHz social channel in the EU"))
        }
        return (149, L("channel 149, AWDL's 5 GHz social channel where UNII-3 is allowed (the US, Canada, and most of the world)"))
    }

    /// EU / EEA / UK regulatory regions, where UNII-3 (channels 149+) is not
    /// permitted, so AWDL parks its 5 GHz social channel on 44 instead of 149.
    static let euCountryCodes: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR",
        "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK",
        "SI", "ES", "SE", "GB", "UK", "NO", "IS", "LI", "CH",
    ]

    // MARK: - Bluetooth (shares the radio chip)

    static func bluetoothRadio(_ snapshot: StreamingSnapshot) -> ReadinessCheck {
        let id = "stream-bluetooth"
        let title = L("Bluetooth during play")
        switch snapshot.bluetoothOn {
        case true:
            return ReadinessCheck(
                id: id, title: title, status: .tip,
                detail: L("Bluetooth is on. It shares the radio chip with Wi-Fi, so heavy Bluetooth traffic (audio, controllers) can add its own blips."),
                remediation: Remediation(
                    hint: L("Nothing to fix: just a variable to know about if stutter persists on a clean channel.")
                )
            )
        case false:
            return ReadinessCheck(
                id: id, title: title, status: .ok,
                detail: L("Bluetooth is off, so it isn't competing with Wi-Fi for the radio.")
            )
        case nil:
            return ReadinessCheck(
                id: id, title: title, status: .unknown,
                detail: L("Couldn't read the Bluetooth radio state.")
            )
        }
    }

    // MARK: - Standing notes

    /// Game Mode explainer. There is no supported way for an app to turn
    /// Game Mode on (the only switch, `gamepolicyctl`, ships inside Xcode),
    /// but macOS enables it by itself when a game runs full screen, so the
    /// actionable advice is simply "go full screen".
    static func gameModeTip() -> ReadinessCheck {
        ReadinessCheck(
            id: "stream-game-mode",
            title: L("Game Mode"),
            status: .tip,
            detail: L("macOS turns on Game Mode by itself when a game runs full screen: the game gets CPU and GPU priority, and Bluetooth controllers and audio get faster sampling. If the game-controller icon doesn't appear in the menu bar while playing, put the game into full screen."),
            remediation: Remediation(
                hint: L("How Game Mode works:"),
                links: [
                    ReadinessLink(
                        label: L("Learn more"),
                        url: URL(string: "https://support.apple.com/105118")!
                    ),
                ]
            )
        )
    }

    /// Browser cloud gaming can't be matched by an app rule; the
    /// audio-playing condition is the reliable stand-in.
    static func browserCloudGamingTip() -> ReadinessCheck {
        ReadinessCheck(
            id: "stream-browser-gaming",
            title: L("Cloud gaming in the browser"),
            status: .tip,
            detail: L("Xbox Cloud Gaming and the web versions of GeForce NOW run in a browser tab, so there's no app for the gaming condition to spot. The \u{201C}Audio playing\u{201D} condition covers them: game sound keeps the session brewing."),
            remediation: Remediation(
                hint: L("Add it under Preferences \u{25B8} Triggers \u{25B8} Add \u{25B8} Apps & Activity \u{25B8} Media.")
            )
        )
    }

    /// Location Services runs its own periodic Wi-Fi scans. Deliberately a
    /// note, not advice to turn it off: Keepresso itself needs Location for
    /// Wi-Fi name rules.
    static func locationScansNote() -> ReadinessCheck {
        ReadinessCheck(
            id: "stream-location-note",
            title: L("Location Services and Wi-Fi scans"),
            status: .tip,
            detail: L("Location Services triggers independent Wi-Fi scans, another source of occasional blips. Keepresso itself uses Location to read Wi-Fi network names for triggers, so weigh that before turning anything off."),
            remediation: Remediation(
                hint: L("Review which apps use Location:"),
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
            )
        )
    }

    /// Pointer to the blog post the whole screen is built around.
    static func awdlReadMore() -> ReadinessCheck {
        ReadinessCheck(
            id: "stream-read-more",
            title: L("Why streams stutter once a second"),
            status: .tip,
            detail: L("The Wi-Fi radio hops off-channel for AWDL (AirDrop, Handoff, Sidecar, Continuity) roughly every second, which shows up as 50-100 ms ping spikes. The jitter test reproduces the diagnosis; the AWDL watchdog is the session-scoped fix."),
            remediation: Remediation(
                hint: L("The full story:"),
                links: [
                    ReadinessLink(
                        label: L("Read more"),
                        url: URL(string: "https://gyorgy.sh/blog/macos-awdl-network-jitter")!
                    ),
                ]
            )
        )
    }
}

/// Drives the check list of the Gaming & Streaming Setup screen. Owns no
/// timer; the host calls ``refresh()`` on appear and from a Re-check button
/// (mirrors ``SystemReadinessController``).
@MainActor
@Observable
public final class StreamingReadinessController {
    /// The ordered rows: probed checks, then the standing notes. Empty until
    /// the first ``refresh()``.
    public private(set) var checks: [ReadinessCheck] = []

    private let probe: StreamingProbing

    public init(probe: StreamingProbing = SystemStreamingProbe()) {
        self.probe = probe
    }

    /// Re-probe and recompute. The probe shells out and reads CoreWLAN, so it
    /// runs on a detached task and the result lands back on the main actor.
    public func refresh() async {
        let probe = self.probe
        let snapshot = await Task.detached { probe.snapshot() }.value
        checks = ReadinessCheck.evaluateStreaming(snapshot)
            + [.gameModeTip(), .browserCloudGamingTip(), .locationScansNote(), .awdlReadMore()]
    }
}

/// Real ``StreamingProbing``: CoreWLAN for the channel, and shell-outs for
/// the interface inventory and the Bluetooth radio state. Bluetooth
/// deliberately comes from `system_profiler`, not IOBluetooth/CoreBluetooth:
/// those frameworks throw the Bluetooth privacy prompt just for the power
/// state, and this screen must open without asking for anything. Not
/// `@MainActor`; the controller hops off main before calling ``snapshot()``.
public final class SystemStreamingProbe: StreamingProbing {
    public init() {}

    public func snapshot() -> StreamingSnapshot {
        let channel = CWWiFiClient.shared().interface()?.wlanChannel()
        return StreamingSnapshot(
            wifiChannel: channel.map(\.channelNumber),
            wifiBand: channel.flatMap { Self.band($0.channelBand) },
            wifiWidthMHz: channel.flatMap { Self.widthMHz($0.channelWidth) },
            wifiCountryCode: CWWiFiClient.shared().interface()?.countryCode(),
            hardwarePorts: run("/usr/sbin/networksetup", ["-listallhardwareports"]),
            ifconfig: run("/sbin/ifconfig", ["-a"]),
            bluetoothOn: Self.parseBluetoothOn(fromProfilerJSON: run(
                "/usr/sbin/system_profiler",
                ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
            ))
        )
    }

    /// Pure parse of `system_profiler SPBluetoothDataType -json`: the
    /// controller state reads `attrib_on` / `attrib_off`. `nil` when the
    /// shape is unexpected (no Bluetooth hardware, a future format change).
    static func parseBluetoothOn(fromProfilerJSON json: String?) -> Bool? {
        guard let data = json?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPBluetoothDataType"] as? [[String: Any]],
              let properties = entries.first?["controller_properties"] as? [String: Any],
              let state = properties["controller_state"] as? String
        else { return nil }
        switch state {
        case "attrib_on": return true
        case "attrib_off": return false
        default: return nil
        }
    }

    static func band(_ band: CWChannelBand) -> WiFiBand? {
        switch band {
        case .band2GHz: return .ghz2
        case .band5GHz: return .ghz5
        case .band6GHz: return .ghz6
        case .bandUnknown: return nil
        @unknown default: return nil
        }
    }

    static func widthMHz(_ width: CWChannelWidth) -> Int? {
        switch width {
        case .width20MHz: return 20
        case .width40MHz: return 40
        case .width80MHz: return 80
        case .width160MHz: return 160
        case .widthUnknown: return nil
        @unknown default: return nil
        }
    }

    private func run(_ path: String, _ arguments: [String]) -> String? {
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
