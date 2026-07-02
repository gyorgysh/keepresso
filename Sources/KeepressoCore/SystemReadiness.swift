import Foundation
import Observation

/// How a single headless-readiness check came out.
public enum ReadinessStatus: String, Codable, Sendable {
    /// Configured the headless-friendly way (✅).
    case ok
    /// Set in a way that will bite an always-on, headless Mac (⚠️).
    case warning
    /// An optional suggestion, not a problem (💡): a nice-to-have for a headless
    /// Mac that the user can take or leave.
    case tip
    /// We couldn't read the underlying state (e.g. a command failed).
    case unknown
}

/// A labeled hyperlink shown under a check (e.g. "GitHub", "Read more").
public struct ReadinessLink: Equatable, Sendable {
    public var label: String
    public var url: URL
    public init(label: String, url: URL) {
        self.label = label
        self.url = url
    }
}

/// What the user can do about a check that isn't ``ReadinessStatus/ok``. All
/// fields are advisory: Keepresso never mutates system state itself (most of
/// these are admin-only and we ship unsandboxed but unprivileged).
public struct Remediation: Equatable, Sendable {
    /// One-line "do this" hint shown under the check.
    public var hint: String
    /// `x-apple.systempreferences:` deep link to the relevant pane, if any.
    public var settingsURL: URL?
    /// A copyable shell command (typically `sudo pmset …`) for the admin-only
    /// settings we can't deep-link to a toggle for.
    public var command: String?
    /// Extra labeled links (e.g. a tip pointing at a repo and a blog post).
    public var links: [ReadinessLink]

    public init(
        hint: String,
        settingsURL: URL? = nil,
        command: String? = nil,
        links: [ReadinessLink] = []
    ) {
        self.hint = hint
        self.settingsURL = settingsURL
        self.command = command
        self.links = links
    }
}

/// One row in the Setup screen: a probed system fact, judged for headless use.
public struct ReadinessCheck: Identifiable, Equatable, Sendable {
    /// Stable identifier (also the SwiftUI list id).
    public let id: String
    /// Short human title, e.g. "Restart after power failure".
    public let title: String
    public let status: ReadinessStatus
    /// Human-readable description of the *current* state.
    public let detail: String
    /// Present unless ``status`` is ``ReadinessStatus/ok``.
    public let remediation: Remediation?

    public init(
        id: String,
        title: String,
        status: ReadinessStatus,
        detail: String,
        remediation: Remediation? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.remediation = remediation
    }
}

/// Raw outputs of the system probes, before interpretation. Keeping the impure
/// shell-out separate from the parsing is what makes the readiness logic
/// unit-testable: tests build a snapshot literal, no `Process` required.
public struct SystemSnapshot: Sendable, Equatable {
    /// stdout of `pmset -g`, or `nil` if the command couldn't be run.
    public var pmset: String?
    /// stdout of `fdesetup status`.
    public var fileVault: String?
    /// The configured auto-login user from
    /// `com.apple.loginwindow autoLoginUser`, or `nil` when unset (the default,
    /// which is *not* headless-friendly).
    public var autoLoginUser: String?

    /// Whether Remote Login (SSH) appears to be enabled. Best-effort: `nil` when
    /// detection wasn't possible (no privilege, command unavailable).
    public var remoteLogin: Bool?

    /// Whether Screen Sharing appears to be enabled. Best-effort, same caveat as
    /// ``remoteLogin``.
    public var screenSharing: Bool?

    public init(
        pmset: String? = nil,
        fileVault: String? = nil,
        autoLoginUser: String? = nil,
        remoteLogin: Bool? = nil,
        screenSharing: Bool? = nil
    ) {
        self.pmset = pmset
        self.fileVault = fileVault
        self.autoLoginUser = autoLoginUser
        self.remoteLogin = remoteLogin
        self.screenSharing = screenSharing
    }
}

/// System-touching seam: gathers a ``SystemSnapshot``. Mirrors the other seams
/// (``PowerAsserting``, ``DiskTouching``): the app wires ``ShellSystemProbe``
/// and tests feed a canned snapshot.
public protocol SystemProbing: AnyObject, Sendable {
    func snapshot() -> SystemSnapshot
}

public extension ReadinessCheck {
    /// Interpret a raw ``SystemSnapshot`` into the ordered list of checks shown
    /// on the Setup screen. Pure: this is the heart of the feature and the unit
    /// under test.
    static func evaluate(_ snapshot: SystemSnapshot) -> [ReadinessCheck] {
        [
            wakeForNetwork(snapshot),
            autoRestart(snapshot),
            systemSleep(snapshot),
            fileVault(snapshot),
            autoLogin(snapshot),
            remoteLogin(snapshot),
            screenSharing(snapshot),
        ]
    }

    // MARK: - Remote access (best-effort)

    private static let sharingDeepLink = URL(
        string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
    )

    static func remoteLogin(_ snapshot: SystemSnapshot) -> ReadinessCheck {
        remoteAccess(
            id: "remote-login",
            title: "Remote Login (SSH)",
            enabled: snapshot.remoteLogin,
            on: "Remote Login is on, so you can reach this Mac over SSH.",
            off: "Remote Login is off. You might want to enable it for SSH access to a headless Mac.",
            unknown: "Couldn't confirm Remote Login. If you want SSH access, enable it in System Settings."
        )
    }

    static func screenSharing(_ snapshot: SystemSnapshot) -> ReadinessCheck {
        remoteAccess(
            id: "screen-sharing",
            title: "Screen Sharing",
            enabled: snapshot.screenSharing,
            on: "Screen Sharing is on, so you can connect with the Screen Sharing app or VNC.",
            off: "Screen Sharing is off. You might want to enable it to view a headless Mac's screen.",
            unknown: "Couldn't confirm Screen Sharing. If you want remote viewing, enable it in System Settings."
        )
    }

    /// Shared shape for the two remote-access checks. These are conveniences, not
    /// requirements: an always-on Mac runs fine without them. So when they're on
    /// it's ✅, and otherwise it's a 💡 tip (pointing at System Settings ▸ Sharing),
    /// never a ⚠️ warning.
    private static func remoteAccess(
        id: String,
        title: String,
        enabled: Bool?,
        on: String,
        off: String,
        unknown: String
    ) -> ReadinessCheck {
        let status: ReadinessStatus = enabled == true ? .ok : .tip
        return ReadinessCheck(
            id: id,
            title: title,
            status: status,
            detail: enabled == true ? on : (enabled == false ? off : unknown),
            remediation: status == .ok ? nil : Remediation(
                hint: "Enable it in System Settings ▸ General ▸ Sharing.",
                settingsURL: sharingDeepLink
            )
        )
    }

    // MARK: - Standing suggestions

    /// A standing tip (not derived from the system): use MyAgens to let AI
    /// agents operate this Mac. Especially relevant for an always-on machine
    /// reached remotely. Surfaced by ``SystemReadinessController`` after the
    /// real checks.
    static func myAgensSuggestion() -> ReadinessCheck {
        ReadinessCheck(
            id: "tip-myagens",
            title: "Run AI agents on this Mac with MyAgens",
            status: .tip,
            detail: "MyAgens lets AI agents operate your Mac and help with your work, which is handy on an always-on machine you mostly reach remotely.",
            remediation: Remediation(
                hint: "Learn more about MyAgens:",
                links: [
                    ReadinessLink(label: "GitHub", url: URL(string: "https://github.com/gyorgysh/myagens")!),
                    ReadinessLink(label: "Read more", url: URL(string: "https://gyorgy.sh/blog/myagens")!),
                ]
            )
        )
    }

    // MARK: - Power management (`pmset -g`)

    private static let energyDeepLink = URL(
        string: "x-apple.systempreferences:com.apple.preference.battery"
    )

    static func wakeForNetwork(_ snapshot: SystemSnapshot) -> ReadinessCheck {
        let value = PMSet.value(forKey: "womp", in: snapshot.pmset)
        return ReadinessCheck(
            id: "wake-for-network",
            title: "Wake for network access",
            status: value.map { $0 == 1 ? .ok : .warning } ?? .unknown,
            detail: detail(
                value,
                on: "The Mac wakes when accessed over the network.",
                off: "The Mac won't wake for network access, so remote logins may fail.",
                unknown: "Couldn't read the power settings."
            ),
            remediation: value == 1 ? nil : Remediation(
                hint: "Enable “Wake for network access”.",
                settingsURL: energyDeepLink,
                command: "sudo pmset -a womp 1"
            )
        )
    }

    static func autoRestart(_ snapshot: SystemSnapshot) -> ReadinessCheck {
        let value = PMSet.value(forKey: "autorestart", in: snapshot.pmset)
        return ReadinessCheck(
            id: "auto-restart",
            title: "Restart after power failure",
            status: value.map { $0 == 1 ? .ok : .warning } ?? .unknown,
            detail: detail(
                value,
                on: "The Mac restarts automatically after a power failure.",
                off: "The Mac stays off after a power cut, so it won't come back headless.",
                unknown: "Couldn't read the power settings."
            ),
            remediation: value == 1 ? nil : Remediation(
                hint: "Enable automatic restart after a power failure.",
                settingsURL: energyDeepLink,
                command: "sudo pmset -a autorestart 1"
            )
        )
    }

    static func systemSleep(_ snapshot: SystemSnapshot) -> ReadinessCheck {
        let value = PMSet.value(forKey: "sleep", in: snapshot.pmset)
        // `sleep 0` disables idle system sleep, the headless-friendly setting.
        return ReadinessCheck(
            id: "system-sleep",
            title: "System sleep disabled",
            status: value.map { $0 == 0 ? .ok : .warning } ?? .unknown,
            detail: detail(
                value,
                on: "Idle system sleep is disabled, so the Mac stays reachable.",
                off: "The Mac sleeps when idle; Keepresso prevents this while a session runs, but a global setting is safer headless.",
                unknown: "Couldn't read the power settings.",
                onWhen: { $0 == 0 }
            ),
            remediation: value == 0 ? nil : Remediation(
                hint: "Disable idle system sleep.",
                settingsURL: energyDeepLink,
                command: "sudo pmset -a sleep 0"
            )
        )
    }

    // MARK: - FileVault (`fdesetup status`)

    static func fileVault(_ snapshot: SystemSnapshot) -> ReadinessCheck {
        let status: ReadinessStatus
        let detail: String
        if let output = snapshot.fileVault?.lowercased() {
            if output.contains("off") {
                status = .ok
                detail = "FileVault is off, so the Mac can reboot unattended to the login window."
            } else if output.contains("on") {
                status = .warning
                detail = "FileVault is on, so a reboot blocks at the disk-unlock screen until someone types the password, defeating headless restart."
            } else {
                status = .unknown
                detail = "Couldn't determine the FileVault status."
            }
        } else {
            status = .unknown
            detail = "Couldn't determine the FileVault status."
        }
        return ReadinessCheck(
            id: "filevault",
            title: "FileVault disabled",
            status: status,
            detail: detail,
            remediation: status == .ok ? nil : Remediation(
                hint: "For an unattended Mac, consider turning FileVault off (weigh the security trade-off).",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")
            )
        )
    }

    // MARK: - Auto-login

    static func autoLogin(_ snapshot: SystemSnapshot) -> ReadinessCheck {
        let user = snapshot.autoLoginUser?.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = !(user?.isEmpty ?? true)
        return ReadinessCheck(
            id: "auto-login",
            title: "Automatic login",
            status: enabled ? .ok : .warning,
            detail: enabled
                ? "Automatic login is on (\(user!)), so the Mac reaches the desktop after a reboot without a keyboard."
                : "Automatic login is off. After a reboot the Mac waits at the login window for a password.",
            remediation: enabled ? nil : Remediation(
                hint: "Turn on automatic login for this account.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")
            )
        )
    }

    // MARK: - Helpers

    private static func detail(
        _ value: Int?,
        on: String,
        off: String,
        unknown: String,
        onWhen isOn: (Int) -> Bool = { $0 == 1 }
    ) -> String {
        guard let value else { return unknown }
        return isOn(value) ? on : off
    }
}

/// Tiny parser for `pmset -g` output. Lines look like `  womp   1`; we pull the
/// integer that follows a given key.
enum PMSet {
    static func value(forKey key: String, in output: String?) -> Int? {
        guard let output else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == Substring(key) else { continue }
            return Int(fields[1])
        }
        return nil
    }
}

/// Drives the Setup screen. Like the other controllers it owns no timer; the
/// host calls ``refresh()`` (on appear / on a "Re-check" button).
@MainActor
@Observable
public final class SystemReadinessController {
    /// Checks derived from the system probe (shell-readable state).
    public private(set) var systemChecks: [ReadinessCheck] = []

    /// App-level checks the host supplies (notification / Location / login-item
    /// permission), which depend on app frameworks rather than the shell. The
    /// app assigns these; setting them refreshes ``checks``.
    public var permissionChecks: [ReadinessCheck] = [] {
        didSet { recompute() }
    }

    /// The full ordered list shown on the Setup screen: system checks, then the
    /// standing tips (so they sit next to the remote-access tips), then the app's
    /// permission checks.
    public private(set) var checks: [ReadinessCheck] = []

    /// Standing suggestions, not probed from the system. Placed right after the
    /// system checks so the MyAgens tip follows the remote-access tips. Not
    /// shown until the first ``refresh()`` so the screen starts blank.
    private let suggestions: [ReadinessCheck] = [.myAgensSuggestion()]

    private let probe: SystemProbing

    public init(probe: SystemProbing = ShellSystemProbe()) {
        self.probe = probe
    }

    /// Re-probe the system and recompute every check. Leaves ``permissionChecks``
    /// untouched (the host refreshes those separately).
    ///
    /// The probe shells out via `Process`, which must not block the main thread
    /// (a synchronous `waitUntilExit` spins the run loop and can crash re-entrantly
    /// when a virtual display is active), so it runs on a detached task and the
    /// result lands back on the main actor.
    public func refresh() async {
        let probe = self.probe
        let snapshot = await Task.detached { probe.snapshot() }.value
        systemChecks = ReadinessCheck.evaluate(snapshot)
        recompute()
    }

    private func recompute() {
        checks = systemChecks + suggestions + permissionChecks
    }
}

/// Real ``SystemProbing`` that shells out via `Process`. Not `@MainActor`: the
/// blocking reads should run off the UI; ``SystemReadinessController`` can hop
/// to a background task before calling ``snapshot()``.
public final class ShellSystemProbe: SystemProbing {
    public init() {}

    public func snapshot() -> SystemSnapshot {
        SystemSnapshot(
            pmset: run("/usr/bin/pmset", ["-g"]),
            fileVault: run("/usr/bin/fdesetup", ["status"]),
            autoLoginUser: run(
                "/usr/bin/defaults",
                ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"]
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            remoteLogin: serviceLoaded("com.openssh.sshd"),
            screenSharing: serviceLoaded("com.apple.screensharing")
        )
    }

    /// Best-effort check of whether a launchd service is loaded in the system
    /// domain. `launchctl print` exits 0 when the label exists, non-zero when it
    /// doesn't; `nil` if `launchctl` itself couldn't be run.
    private func serviceLoaded(_ label: String) -> Bool? {
        guard let status = exitStatus("/bin/launchctl", ["print", "system/\(label)"]) else { return nil }
        return status == 0
    }

    /// Run a command and return trimmed stdout, or `nil` on any failure (a
    /// missing key, a non-zero exit, a launch error).
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

    /// Run a command for its exit status only (stdout/stderr discarded), or `nil`
    /// if it couldn't be launched.
    private func exitStatus(_ path: String, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return nil
        }
    }
}
