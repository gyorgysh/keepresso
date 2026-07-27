import Foundation

/// A serializable description of a single trigger condition.
///
/// Triggers themselves are live objects bound to system monitors, so they can't
/// be persisted directly. A `TriggerRule` is the saved, value-typed form; the
/// ``TriggerFactory`` rebuilds live ``Trigger``s from rules at launch.
public enum TriggerRule: Codable, Equatable, Hashable, Sendable {
    /// On AC / on battery / charging (see ``PowerSourceTrigger/Match``).
    case powerSource(PowerSourceTrigger.Match)
    /// At least one external display connected.
    case externalDisplay
    /// Joined to this exact Wi-Fi SSID.
    case wifiSSID(String)
    /// An app is running / frontmost, optionally with a deactivation grace.
    case app(AppRule)
    /// Any process whose command line contains this string is running
    /// (matches command-line tools and background jobs, not just GUI apps).
    case process(String)
    /// The current time falls inside a recurring daily window.
    case timeWindow(TimeWindowRule)
    /// A volume with this name is mounted (external drive, SD card, NAS share).
    case volumeMounted(String)
    /// Smoothed overall CPU usage is above this percentage.
    case cpuLoad(thresholdPercent: Int)
    /// Any process is using the camera or the microphone (a call, a recording).
    case mediaInUse(MediaInUseTrigger.Device)
    /// The microphone is in use by one of a chosen set of apps (Discord, Slack,
    /// Zoom, ...), matched by bundle id. A sibling of ``mediaInUse`` rather than
    /// a parameter on it, so existing saved rules and presets decode unchanged;
    /// the camera has no per-process API, so scoping is microphone-only.
    case micInUse(MicInUseRule)
    /// Sound is playing through any output device (with a release grace).
    case audioPlaying
    /// Any VPN configuration is connected.
    case vpnConnected
    /// A paired Bluetooth device with this name is connected (with a release
    /// grace, so a brief drop while switching hosts doesn't flap the session).
    case bluetoothDevice(String)
    /// A timed (non-all-day) calendar event is in progress.
    case calendarEvent
    /// A game (by declared app category) or a cloud-gaming client is frontmost
    /// (with a generous release grace, so alt-tabbing doesn't drop the session).
    case gaming
    /// Smoothed overall network throughput (in + out) is above this many KB/s.
    case throughput(kilobytesPerSecond: Int)
    /// An in-progress download exists in this folder (a partial-download file,
    /// with a release grace bridging the gap between files in a batch).
    case downloadInFolder(URL)
    /// Any detected AI-agent session (claude, codex, ...) is actively working,
    /// judged by its process subtree's smoothed CPU, with a release grace once
    /// every session goes idle.
    case agentActivity(AgentRule)
    /// At least one game controller is connected (with a short release grace,
    /// so a controller briefly rebonding doesn't flap the session).
    case controllerConnected
    /// Steam is actively downloading or updating a game in any library
    /// (with a generous release grace bridging between-depot verification).
    case steamDownload

    /// A human-readable summary for the rules UI.
    public var label: String {
        switch self {
        case .powerSource(let match): return match.label
        case .externalDisplay:        return L("External display connected")
        case .wifiSSID(let ssid):     return L("On Wi-Fi \u{201C}%@\u{201D}", ssid)
        case .app(let rule):          return rule.label
        case .process(let query):     return L("Process \u{201C}%@\u{201D} running", query)
        case .timeWindow(let rule):   return rule.label
        case .volumeMounted(let name): return L("Volume \u{201C}%@\u{201D} mounted", name)
        case .cpuLoad(let threshold): return L("CPU above %d%%", threshold)
        case .mediaInUse(let device): return device.label
        case .micInUse(let rule):     return rule.label
        case .audioPlaying:           return L("Audio playing")
        case .vpnConnected:           return L("VPN connected")
        case .bluetoothDevice(let name):
            return L("Bluetooth \u{201C}%@\u{201D} connected", name)
        case .calendarEvent:          return L("Calendar event in progress")
        case .gaming:                 return L("Playing a game")
        case .throughput(let kb):
            return L("Network above %@", NetworkThroughput.rateLabel(kilobytesPerSecond: kb))
        case .downloadInFolder(let url):
            return L("Downloading in \u{201C}%@\u{201D}", url.lastPathComponent)
        case .agentActivity(let rule): return rule.label
        case .controllerConnected:    return L("Game controller connected")
        case .steamDownload:          return L("Steam is downloading")
        }
    }

    /// A system privacy permission a rule needs before it can evaluate.
    public enum Permission: String, Sendable, CaseIterable {
        /// Location access, needed to read the current Wi-Fi network name.
        case location
        /// Bluetooth access, needed to see which paired devices are connected.
        case bluetooth
        /// Full calendar access, needed to see events in progress.
        case calendar
    }

    /// The privacy permission this rule needs to evaluate, or `nil` when it
    /// reads only unrestricted state. Lets the Setup screen build its per-rule
    /// permission checks from one table instead of a scan per permission.
    public var requiredPermission: Permission? {
        switch self {
        case .wifiSSID:        return .location
        case .bluetoothDevice: return .bluetooth
        case .calendarEvent:   return .calendar
        default:               return nil
        }
    }
}

/// A persisted "caffeinating app" rule: which app, how it's matched, and how
/// long to linger after it stops matching.
public struct AppRule: Codable, Equatable, Hashable, Sendable {
    /// Bundle identifier, e.g. `com.apple.FaceTime`.
    public var bundleID: String
    /// A friendly display name (e.g. "NVIDIA GeForce NOW") shown instead of the
    /// bundle id in the menu and rules editor. Optional (older rules and hand-made
    /// ones may lack it); set when the rule is built from a known app, i.e. a
    /// preset or the running-apps menu, which already have the name. Matching is
    /// always by ``bundleID``, so a stale or missing name never affects behavior.
    public var name: String?
    /// Running vs frontmost.
    public var match: AppMatch
    /// Seconds to stay active after the app stops matching (0 = no grace).
    public var grace: TimeInterval

    public init(bundleID: String, name: String? = nil, match: AppMatch = .running, grace: TimeInterval = 0) {
        self.bundleID = bundleID
        self.name = name
        self.match = match
        self.grace = grace
    }

    public var label: String {
        // A bundle id reads as machine noise in the UI, so prefer the friendly
        // name when we have it; keep the "App " prefix only as the bare-id fallback.
        let subject = name ?? L("App %@", bundleID)
        let base = "\(subject) \(match.label)"
        return grace > 0 ? L("%@ (+%ds)", base, Int(grace)) : base
    }
}

/// A persisted "AI agent working" rule: keep awake while any detected agent
/// session is actively working, lingering ``grace`` seconds once all go idle.
public struct AgentRule: Codable, Equatable, Hashable, Sendable {
    /// Seconds to stay active after every agent session goes idle (0 = none).
    /// Three minutes by default: a genuinely zero-CPU stretch (a long network
    /// wait, a slow model turn) reads as idle, and the grace is what bridges it.
    public var grace: TimeInterval
    /// When true, a hook `waiting` state (idle nudge after a prompt went
    /// unanswered) still counts as working. Off by default: overnight
    /// unattended runs that sit on a permission prompt would otherwise hold
    /// the Mac awake indefinitely. `waiting-approval` always counts as
    /// working regardless of this flag (mid-task, flipping on every prompt
    /// would flap the trigger).
    public var countWaitingAsWorking: Bool

    public init(
        grace: TimeInterval = AgentActivityTrigger.defaultGrace,
        countWaitingAsWorking: Bool = false
    ) {
        self.grace = grace
        self.countWaitingAsWorking = countWaitingAsWorking
    }

    /// Forgiving decoder: older saves without the waiting flag keep the
    /// default (false).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grace = try c.decodeIfPresent(TimeInterval.self, forKey: .grace)
            ?? AgentActivityTrigger.defaultGrace
        countWaitingAsWorking = try c.decodeIfPresent(Bool.self, forKey: .countWaitingAsWorking) ?? false
    }

    public var label: String {
        let base = L("AI agent working")
        var parts: [String] = []
        if grace > 0 { parts.append(L("+%ds", Int(grace))) }
        if countWaitingAsWorking { parts.append(L("waiting counts")) }
        return parts.isEmpty ? base : L("%@ (%@)", base, parts.joined(separator: ", "))
    }
}

/// One app watched by a ``MicInUseRule``: its bundle id (how it is matched)
/// plus an optional friendly name for the UI, mirroring ``AppRule``. Matching
/// is always by ``bundleID`` (by prefix, so an app's Electron helper
/// subprocess counts), so a stale or missing name never changes behavior.
public struct ScopedApp: Codable, Equatable, Hashable, Sendable {
    /// Bundle identifier of the app to watch, e.g. `com.hnc.Discord`.
    public var bundleID: String
    /// Friendly display name (e.g. "Discord"), set when the rule is built from
    /// a known app (the "using the mic now" list, a preset, or the app picker).
    public var name: String?

    public init(bundleID: String, name: String? = nil) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// A persisted "microphone in use by specific apps" rule: keep awake only while
/// one of ``apps`` is capturing the microphone, i.e. that app is on a call.
/// Reads the macOS 14 per-process CoreAudio API, unprivileged and prompt-free.
/// Microphone only: the camera has no equivalent per-process API to scope by.
public struct MicInUseRule: Codable, Equatable, Hashable, Sendable {
    /// The apps to watch, by bundle id (+ optional friendly name). An empty
    /// list matches nothing, so the rule holds nothing awake until an app is
    /// added; the editor drops the whole rule when its last app is removed.
    public var apps: [ScopedApp]

    public init(apps: [ScopedApp] = []) {
        self.apps = apps
    }

    public var label: String {
        guard !apps.isEmpty else { return L("Microphone in use by app") }
        // De-duplicate display names so a multi-id app (several bundle ids under
        // one name) reads as "Telegram", not "Telegram, Telegram".
        var seen = Set<String>()
        let names = apps.compactMap { app -> String? in
            let name = app.name ?? app.bundleID
            return seen.insert(name).inserted ? name : nil
        }.joined(separator: ", ")
        return L("Microphone in use by %@", names)
    }
}

/// A named set of trigger rules plus how they combine, the persisted shape of
/// a trigger configuration.
public struct RuleSet: Codable, Equatable, Sendable {
    /// OR (any) or AND (all). Defaults to OR.
    public var combine: CombineMode
    /// The conditions in this set, in display order.
    public var rules: [TriggerRule]

    public init(combine: CombineMode = .any, rules: [TriggerRule] = []) {
        self.combine = combine
        self.rules = rules
    }

    /// Forgiving decoder, mirroring the pattern used across the settings types.
    /// A rule case added by a newer build (reached via a version downgrade, or
    /// a set exported from a newer version and imported) is dropped rather than
    /// throwing. A synthesized `[TriggerRule]` decode fails the whole array on
    /// one unknown element, and because ``KeepressoSettings`` loads through
    /// `try?` that would silently reset every setting to defaults; dropping only
    /// the unreadable rules keeps the rest of the configuration intact.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        combine = try c.decodeIfPresent(CombineMode.self, forKey: .combine) ?? .any
        var decoded: [TriggerRule] = []
        if var array = try? c.nestedUnkeyedContainer(forKey: .rules) {
            while !array.isAtEnd {
                let before = array.currentIndex
                if let rule = try? array.decode(TriggerRule.self) {
                    decoded.append(rule)
                } else {
                    // A failed decode above doesn't consume the element, so
                    // read a value of any shape to step the cursor past it.
                    _ = try? array.decode(DiscardedRule.self)
                }
                if array.currentIndex == before { break } // never spin
            }
        }
        rules = decoded
    }

    /// An empty rule set (which a ``TriggerEngine`` treats as "never fire").
    public static let empty = RuleSet()
}

/// Consumes one element of any shape from an unkeyed container, so the lossy
/// ``RuleSet`` decoder can skip a rule case it doesn't recognize.
private struct DiscardedRule: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Rebuilds live ``Trigger``s and ``TriggerEngine``s from persisted ``RuleSet``s.
///
/// Holds one instance of each system monitor and shares it across every trigger
/// it builds, so all conditions read a consistent view of the world. Inject
/// fakes in tests; the defaults wire the real IOKit/CoreGraphics/CoreWLAN/AppKit
/// backends.
public struct TriggerFactory {
    private let powerSource: PowerSourceMonitoring
    private let displays: DisplayMonitoring
    private let network: NetworkMonitoring
    private let workspace: WorkspaceMonitoring
    private let processes: ProcessListing
    private let volumes: VolumeMonitoring
    private let cpu: CPULoadReading
    private let media: MediaActivityMonitoring
    private let vpn: VPNMonitoring
    private let bluetooth: BluetoothMonitoring
    private let calendar: CalendarMonitoring
    private let gaming: GamingMonitoring
    private let throughput: NetworkThroughputReading
    private let downloads: DownloadFolderScanning
    private let agents: AgentActivityMonitoring
    private let controllers: ControllerMonitoring
    private let steam: SteamDownloadMonitoring
    private let now: () -> Date
    /// Real agent backend when the factory owns one, so evidence work can be
    /// gated off when no agent rule is live. Nil when tests inject a fake.
    private let agentMonitor: PSAgentActivityMonitor?

    public init(
        powerSource: PowerSourceMonitoring = IOKitPowerSourceMonitor(),
        displays: DisplayMonitoring = CoreGraphicsDisplayMonitor(),
        network: NetworkMonitoring = CoreWLANNetworkMonitor(),
        workspace: WorkspaceMonitoring = NSWorkspaceMonitor(),
        processes: ProcessListing? = nil,
        volumes: VolumeMonitoring = FileManagerVolumeMonitor(),
        cpu: CPULoadReading = HostCPULoadReader(),
        media: MediaActivityMonitoring = CoreMediaActivityMonitor(),
        vpn: VPNMonitoring = SCUtilVPNMonitor(),
        bluetooth: BluetoothMonitoring = IOBluetoothDeviceMonitor(),
        calendar: CalendarMonitoring = EventKitCalendarMonitor(),
        gaming: GamingMonitoring = WorkspaceGamingMonitor(),
        throughput: NetworkThroughputReading = GetifaddrsThroughputReader(),
        downloads: DownloadFolderScanning = FileManagerDownloadScanner(),
        agents: AgentActivityMonitoring? = nil,
        controllers: ControllerMonitoring = GCControllerMonitor(),
        steam: SteamDownloadMonitoring = FileSteamDownloadMonitor(),
        now: @escaping () -> Date = Date.init
    ) {
        // One shared `ps` snapshot for process matching and agent detection
        // unless the caller injects its own backends (tests).
        let sharedPS = SharedPSSnapshot(now: now)
        let resolvedProcesses = processes ?? PSProcessLister(
            now: now, fetch: sharedPS.fetchCommandListing)
        let resolvedAgents: AgentActivityMonitoring
        let resolvedMonitor: PSAgentActivityMonitor?
        if let agents {
            resolvedAgents = agents
            resolvedMonitor = agents as? PSAgentActivityMonitor
        } else {
            let monitor = PSAgentActivityMonitor(now: now, fetch: sharedPS.fetchRaw)
            resolvedAgents = monitor
            resolvedMonitor = monitor
        }
        self.powerSource = powerSource
        self.displays = displays
        self.network = network
        self.workspace = workspace
        self.processes = resolvedProcesses
        self.volumes = volumes
        self.cpu = cpu
        self.media = media
        self.vpn = vpn
        self.bluetooth = bluetooth
        self.calendar = calendar
        self.gaming = gaming
        self.throughput = throughput
        self.downloads = downloads
        self.agents = resolvedAgents
        self.agentMonitor = resolvedMonitor
        self.controllers = controllers
        self.steam = steam
        self.now = now
    }

    /// Skip transcript / hook / cwd decoration in the agent monitor when no
    /// agent rule is in the live engine. No-op when a test injected a fake.
    public func setAgentEvidenceEnabled(_ enabled: Bool) {
        agentMonitor?.evidenceEnabled = enabled
    }

    /// Build the live trigger for one rule.
    public func makeTrigger(for rule: TriggerRule) -> Trigger {
        switch rule {
        case .powerSource(let match):
            return PowerSourceTrigger(match: match, monitor: powerSource)
        case .externalDisplay:
            return ExternalDisplayTrigger(monitor: displays)
        case .wifiSSID(let ssid):
            return WiFiSSIDTrigger(ssid: ssid, monitor: network)
        case .app(let rule):
            let trigger = AppTrigger(bundleID: rule.bundleID, match: rule.match, monitor: workspace)
            return rule.grace > 0
                ? GracePeriodTrigger(wrapping: trigger, grace: rule.grace, now: now)
                : trigger
        case .process(let query):
            return ProcessTrigger(query: query, monitor: processes)
        case .timeWindow(let rule):
            return TimeWindowTrigger(rule: rule, now: now)
        case .volumeMounted(let name):
            return VolumeMountedTrigger(volumeName: name, monitor: volumes)
        case .cpuLoad(let threshold):
            return CPULoadTrigger(thresholdPercent: threshold, reader: cpu)
        case .mediaInUse(let device):
            return MediaInUseTrigger(device: device, monitor: media)
        case .micInUse(let rule):
            return MediaInUseTrigger(
                device: .microphone,
                appFilter: rule.apps.map(\.bundleID),
                monitor: media
            )
        case .audioPlaying:
            return GracePeriodTrigger(
                wrapping: AudioPlayingTrigger(monitor: media),
                grace: AudioPlayingTrigger.releaseGrace,
                now: now
            )
        case .vpnConnected:
            return VPNConnectedTrigger(monitor: vpn)
        case .bluetoothDevice(let name):
            return GracePeriodTrigger(
                wrapping: BluetoothDeviceTrigger(deviceName: name, monitor: bluetooth),
                grace: BluetoothDeviceTrigger.releaseGrace,
                now: now
            )
        case .calendarEvent:
            return CalendarEventTrigger(monitor: calendar)
        case .gaming:
            return GracePeriodTrigger(
                wrapping: GamingTrigger(monitor: gaming),
                grace: GamingTrigger.releaseGrace,
                now: now
            )
        case .throughput(let kb):
            return NetworkThroughputTrigger(thresholdKilobytesPerSecond: kb, reader: throughput)
        case .downloadInFolder(let url):
            return GracePeriodTrigger(
                wrapping: DownloadInFolderTrigger(folder: url, scanner: downloads),
                grace: DownloadInFolderTrigger.releaseGrace,
                now: now
            )
        case .agentActivity(let rule):
            let trigger = AgentActivityTrigger(
                monitor: agents,
                countWaitingAsWorking: rule.countWaitingAsWorking
            )
            return rule.grace > 0
                ? GracePeriodTrigger(wrapping: trigger, grace: rule.grace, now: now)
                : trigger
        case .controllerConnected:
            return GracePeriodTrigger(
                wrapping: ControllerTrigger(monitor: controllers),
                grace: ControllerTrigger.releaseGrace,
                now: now
            )
        case .steamDownload:
            return GracePeriodTrigger(
                wrapping: SteamDownloadTrigger(monitor: steam),
                grace: SteamDownloadTrigger.releaseGrace,
                now: now
            )
        }
    }

    /// Build a combined engine for a whole rule set.
    public func makeEngine(from ruleSet: RuleSet) -> TriggerEngine {
        TriggerEngine(combine: ruleSet.combine, triggers: ruleSet.rules.map(makeTrigger))
    }
}
