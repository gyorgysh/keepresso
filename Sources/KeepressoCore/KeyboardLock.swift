import Foundation
import Observation

/// Outcome of a lock attempt. Cancelled means the administrator prompt was
/// dismissed: the keyboard stays live and no overlay should appear.
public enum KeyboardLockResult: Equatable, Sendable {
    /// hidutil remapped keys globally, including Mac special function keys.
    /// Letters stay live at the HID layer (macOS would otherwise ignore the
    /// whole map). The overlay swallows those while it is in front.
    case applied
    /// The remap did not land (Karabiner, a managed Mac). Overlay can swallow
    /// ordinary keyDown while focused; special keys still need the remap.
    case overlayOnly
    /// User dismissed the administrator-password prompt. Do not lock.
    case cancelled
}

/// One UserKeyMapping entry (`HIDKeyboardModifierMappingSrc` /
/// `HIDKeyboardModifierMappingDst`). Stored as integers so a snapshot round-trips
/// through JSON without hidutil's NeXTSTEP plist dialect.
public struct KeyboardKeyMapping: Equatable, Codable, Sendable {
    public var entries: [Entry]

    public struct Entry: Equatable, Codable, Sendable {
        public var src: UInt64
        public var dst: UInt64

        public init(src: UInt64, dst: UInt64) {
            self.src = src
            self.dst = dst
        }
    }

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// An empty mapping: hidutil's "no remaps" state, never a missing key.
    public static let empty = KeyboardKeyMapping()

    /// hidutil encodes a usage as `(page << 32) | usage`.
    public static func hidUsage(page: UInt64, usage: UInt64) -> UInt64 {
        (page << 32) | usage
    }
}

/// Applies or reads the keyboard `UserKeyMapping`. Tests inject a fake;
/// production shells `hidutil`.
public protocol KeyboardRemapping: AnyObject, Sendable {
    func currentMapping() -> KeyboardKeyMapping
    /// Returns whether the write landed. A failure leaves the hardware mapping
    /// untouched; the overlay can still swallow keys while focused.
    func apply(_ mapping: KeyboardKeyMapping) -> Bool
}

/// Crash-recovery marker: the mapping that was live before a lock, persisted
/// under Application Support so a force-quit mid-lock can restore it.
public protocol KeyboardLockMarking: AnyObject, Sendable {
    func save(original: KeyboardKeyMapping)
    func load() -> KeyboardKeyMapping?
    func clear()
}

/// Global keyboard lock without Accessibility: snapshot the current hidutil
/// `UserKeyMapping`, remap Mac special-function keys and unrestricted
/// keyboard usages to 0, restore the snapshot (never an empty mapping that
/// would wipe the user's own remaps).
public protocol KeyboardLocking: AnyObject, Sendable {
    /// Apply the lock. `.cancelled` must not flip `isLocked`.
    func lock() -> KeyboardLockResult
    func unlock()
    var isLocked: Bool { get }
    /// If a previous run crashed while locked, restore now. Idempotent, and
    /// must not prompt for a password (launch restore).
    func restoreIfNeeded()
}

/// Real hidutil backend. `hidutil property --set` is the same mechanism some
/// keyboard-cleaner utilities use; it needs no TCC prompt. On current macOS
/// the set often requires root, so production lock goes through the helper
/// or osascript rather than this class alone.
public final class HidutilKeyboardRemapper: KeyboardRemapping, @unchecked Sendable {
    private let runner: (String, [String]) -> String?

    public init(runner: @escaping (String, [String]) -> String? = HidutilKeyboardRemapper.run) {
        self.runner = runner
    }

    public func currentMapping() -> KeyboardKeyMapping {
        let raw = runner("/usr/bin/hidutil", ["property", "--get", "UserKeyMapping"]) ?? ""
        return KeyboardKeyMapping.parseHidutilGet(raw)
    }

    public func apply(_ mapping: KeyboardKeyMapping) -> Bool {
        let json = mapping.hidutilSetJSON()
        let output = runner("/usr/bin/hidutil", ["property", "--set", json])
        return output != nil
    }

    /// Spawn hidutil and return stdout (empty string on success with no output),
    /// or `nil` on a non-zero exit.
    public static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
}

/// Privileged hidutil via osascript's "with administrator privileges". Blocks
/// until the password dialog is answered. The JSON is read from a temp file so
/// the AppleScript does not have to quote a 20 KB mapping inline.
public enum OsascriptKeyboardRemapper: Sendable {
    public static func apply(_ mapping: KeyboardKeyMapping) -> KeyboardLockResult {
        let json = mapping.hidutilSetJSON()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepresso-keyboard-lock-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try Data(json.utf8).write(to: file, options: .atomic)
        } catch {
            return .overlayOnly
        }
        let path = file.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        set p to "\(path)"
        set j to do shell script "/bin/cat " & quoted form of p
        do shell script "/usr/bin/hidutil property --set " & quoted form of j with administrator privileges
        """
        guard let result = runOsascript(script) else { return .overlayOnly }
        return outcome(status: result.status, stderr: result.stderr)
    }

    /// Maps osascript's exit and stderr onto a lock result. Factored so tests
    /// cover cancel (`-128`) without spawning SecurityAgent.
    public static func outcome(status: Int32, stderr: String) -> KeyboardLockResult {
        if status == 0 { return .applied }
        if stderr.contains("-128") || stderr.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        return .overlayOnly
    }

    private static func runOsascript(_ script: String) -> (status: Int32, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }
}

/// Marker file at `~/Library/Application Support/Keepresso/keyboard-lock.json`.
public final class FileKeyboardLockMarker: KeyboardLockMarking, @unchecked Sendable {
    private let url: URL

    public init(url: URL = FileKeyboardLockMarker.defaultURL()) {
        self.url = url
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keepresso", isDirectory: true)
            .appendingPathComponent("keyboard-lock.json")
    }

    public func save(original: KeyboardKeyMapping) {
        guard let data = try? JSONEncoder().encode(original) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func load() -> KeyboardKeyMapping? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeyboardKeyMapping.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Combines a remapper and a marker. Lock writes the marker *before* applying
/// the remap so a crash mid-apply still restores.
///
/// Apply order: the privileged helper (silent, already authorized), then
/// osascript's administrator prompt, then a user-level hidutil as last resort.
/// The overlay must not appear until this returns: osascript blocks on the
/// password dialog, and cancel leaves the keyboard unlocked.
public final class KeyboardLocker: KeyboardLocking, @unchecked Sendable {
    /// Protocol version that first shipped `setKeyboardLock`. Older daemons
    /// are treated as missing for this verb.
    public static let helperMinProtocol = 9

    private let remapper: KeyboardRemapping
    private let marker: KeyboardLockMarking
    private let helper: PrivilegedHelperCalling?
    private let helperAvailable: @Sendable () -> Bool
    /// Production passes osascript. Nil in tests (and as a last resort) uses
    /// the user-level remapper, which never pops a password dialog.
    private let privilegedApply: ((KeyboardKeyMapping) -> KeyboardLockResult)?
    private let lockQueue = NSLock()
    private var locked = false
    private var usedHelper = false

    public init(
        remapper: KeyboardRemapping = HidutilKeyboardRemapper(),
        marker: KeyboardLockMarking = FileKeyboardLockMarker(),
        helper: PrivilegedHelperCalling? = nil,
        helperAvailable: @escaping @Sendable () -> Bool = { false },
        privilegedApply: ((KeyboardKeyMapping) -> KeyboardLockResult)? = nil
    ) {
        self.remapper = remapper
        self.marker = marker
        self.helper = helper
        self.helperAvailable = helperAvailable
        self.privilegedApply = privilegedApply
    }

    public var isLocked: Bool {
        lockQueue.lock()
        defer { lockQueue.unlock() }
        return locked
    }

    public func lock() -> KeyboardLockResult {
        lockQueue.lock()
        if locked {
            lockQueue.unlock()
            return .applied
        }
        lockQueue.unlock()

        let original = remapper.currentMapping()
        marker.save(original: original)

        if helperAvailable(),
           let helper,
           (helper.pingVersion() ?? 0) >= Self.helperMinProtocol,
           helper.setKeyboardLock(true) {
            lockQueue.lock()
            locked = true
            usedHelper = true
            lockQueue.unlock()
            return .applied
        }

        if let privilegedApply {
            switch privilegedApply(.disabledKeyboard) {
            case .applied:
                lockQueue.lock()
                locked = true
                usedHelper = false
                lockQueue.unlock()
                return .applied
            case .cancelled:
                marker.clear()
                return .cancelled
            case .overlayOnly:
                break
            }
        }

        // User-level hidutil: tests, or a last try after a failed privileged
        // apply. Never a password dialog. Still mark locked on failure so
        // the overlay can swallow ordinary keys.
        let ok = remapper.apply(.disabledKeyboard)
        lockQueue.lock()
        locked = true
        usedHelper = false
        lockQueue.unlock()
        return ok ? .applied : .overlayOnly
    }

    public func unlock() {
        restoreMapping(allowPrompt: true)
    }

    public func restoreIfNeeded() {
        guard marker.load() != nil else { return }
        restoreMapping(allowPrompt: false)
    }

    /// `allowPrompt` is false at launch: a leftover marker must not pop the
    /// administrator dialog before the menu bar is up.
    private func restoreMapping(allowPrompt: Bool) {
        lockQueue.lock()
        let viaHelper = usedHelper
        usedHelper = false
        locked = false
        lockQueue.unlock()

        let original = marker.load() ?? .empty
        if viaHelper {
            _ = helper?.setKeyboardLock(false)
        }
        if remapper.apply(original) {
            marker.clear()
            return
        }
        if viaHelper {
            marker.clear()
            return
        }
        if allowPrompt, let privilegedApply {
            _ = privilegedApply(original)
        }
        marker.clear()
    }
}

/// Duration-aware wrapper the window drives. `duration == 0` means until click.
/// Tick is injected so tests advance a fake clock. `lock` is async because the
/// administrator prompt (when the helper is not installed) blocks; callers
/// must not show the overlay until it returns.
@MainActor
@Observable
public final class KeyboardLockController {
    public private(set) var isLocked = false
    /// Whether the last lock actually remapped keys globally.
    public private(set) var isGlobal = true
    public private(set) var unlockAt: Date?
    /// True while a lock attempt is in flight (password dialog). The window
    /// uses this to explain the prompt *before* any overlay.
    public private(set) var isBusy = false

    private let locker: KeyboardLocking
    private let now: () -> Date

    public init(
        locker: KeyboardLocking = KeyboardLocker(),
        now: @escaping () -> Date = Date.init
    ) {
        self.locker = locker
        self.now = now
    }

    /// `duration` 0 or `nil` means until the user clicks Unlock.
    @discardableResult
    public func lock(duration: TimeInterval? = nil) async -> KeyboardLockResult {
        if isLocked { return isGlobal ? .applied : .overlayOnly }
        isBusy = true
        let result = await Task.detached { [locker] in locker.lock() }.value
        isBusy = false
        switch result {
        case .cancelled:
            return .cancelled
        case .applied, .overlayOnly:
            isLocked = true
            isGlobal = (result == .applied)
            if let duration, duration > 0 {
                unlockAt = now().addingTimeInterval(duration)
            } else {
                unlockAt = nil
            }
            return result
        }
    }

    public func unlock() {
        guard isLocked || locker.isLocked else { return }
        locker.unlock()
        isLocked = false
        isGlobal = true
        unlockAt = nil
        isBusy = false
    }

    /// Auto-unlock when a timed lock has elapsed. The window calls this from
    /// its timer; tests call it after advancing `now`.
    public func tick() {
        guard isLocked, let unlockAt, now() >= unlockAt else { return }
        unlock()
    }

    public func restoreIfNeeded() {
        locker.restoreIfNeeded()
        isLocked = locker.isLocked
        if !isLocked {
            unlockAt = nil
            isGlobal = true
        }
    }
}

extension KeyboardKeyMapping {
    /// Keyboard-page usages that make a `UserKeyMapping` restricted.
    /// IOHIDKeyboardFilter then ignores the whole map unless the caller has
    /// Input Monitoring or a private entitlement. Letters, digits, and
    /// punctuation are restricted. Function, media, modifier, and navigation
    /// keys are not.
    static func isRestrictedKeyboardUsage(_ usage: UInt64) -> Bool {
        switch usage {
        case 0x04...0x27, 0x2D...0x38, 0x54...0x57, 0x59...0x64, 0x67:
            return true
        default:
            return false
        }
    }

    /// Keyboard usage page 0x07 (unrestricted keys only), plus the Apple /
    /// consumer usages the Mac top-row keys actually send when they are not
    /// standard F-keys (Mission Control, Spotlight, Dictation, brightness,
    /// media, Focus).
    ///
    /// Letters, digits, and punctuation are omitted on purpose: including
    /// any of them makes macOS silently discard the entire map, so Mission
    /// Control and the other special keys keep working. The overlay swallows
    /// ordinary typing while it is in front. Destination 0 is an invalid
    /// HID key, which the filter drops.
    ///
    /// Special usages are listed first so a hidutil mapping-count cap still
    /// disables the keys an overlay cannot swallow.
    public static let disabledKeyboard: KeyboardKeyMapping = {
        var entries: [Entry] = []
        func add(page: UInt64, _ usages: [UInt64]) {
            for usage in usages {
                entries.append(Entry(src: hidUsage(page: page, usage: usage), dst: 0))
            }
        }
        func addRange(page: UInt64, _ range: ClosedRange<UInt64>) {
            for usage in range {
                entries.append(Entry(src: hidUsage(page: page, usage: usage), dst: 0))
            }
        }

        // Apple Vendor Keyboard (0xFF01): Spotlight, Launchpad, Fn, Mission
        // Control / Exposé, brightness. Range covers the documented table
        // plus a little headroom for newer top-row keys.
        addRange(page: 0xFF01, 0x01...0x40)

        // Apple Vendor Top Case (0x00FF): Fn, keyboard illumination,
        // brightness, video mirror.
        addRange(page: 0x00FF, 0x01...0x10)

        // Consumer (0x0C): dictation (Voice Command 0xCF), Spotlight / Search
        // (AC Search 0x221), Mission Control / Launchpad, brightness, media.
        add(page: 0x000C, [
            0x30, 0x40,
            0x6F, 0x70,
            0xB0, 0xB1, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xCD,
            0xCF,
            0xE2, 0xE9, 0xEA,
            0x221,
            0x29D, 0x29F, 0x2A0, 0x2A2,
        ])

        // Generic Desktop (0x01): power / sleep / wake, Focus / Do Not Disturb
        // (System Display Toggle 0x9B on current Apple keyboards).
        add(page: 0x0001, [0x81, 0x82, 0x83, 0x9B])

        // Keyboard page 0x07, skipping restricted alphanumeric / punctuation
        // usages. Covers Enter, Space, arrows, F1–F24, and modifiers so
        // Cmd-Space and Control-Up cannot fire while the overlay is up.
        for usage in UInt64(0x28)...UInt64(0xE7) where !isRestrictedKeyboardUsage(usage) {
            entries.append(Entry(src: hidUsage(page: 0x0007, usage: usage), dst: 0))
        }

        return KeyboardKeyMapping(entries: entries)
    }()

    /// JSON blob for `hidutil property --set`.
    func hidutilSetJSON() -> String {
        let items = entries.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}"
        }.joined(separator: ",")
        return "{\"UserKeyMapping\":[\(items)]}"
    }

    /// Parse `hidutil property --get UserKeyMapping`. `(null)` and unreadable
    /// dumps become an empty mapping, which unlock restores as "no remaps".
    static func parseHidutilGet(_ raw: String) -> KeyboardKeyMapping {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("(null)") {
            return .empty
        }
        var entries: [Entry] = []
        var currentSrc: UInt64?
        var currentDst: UInt64?
        func flushPair() {
            if let src = currentSrc, let dst = currentDst {
                entries.append(Entry(src: src, dst: dst))
            }
            currentSrc = nil
            currentDst = nil
        }
        for line in trimmed.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("HIDKeyboardModifierMappingSrc") {
                currentSrc = trailingInteger(line)
            } else if line.hasPrefix("HIDKeyboardModifierMappingDst") {
                currentDst = trailingInteger(line)
            } else if line.hasPrefix("}") {
                flushPair()
            }
        }
        flushPair()
        return KeyboardKeyMapping(entries: entries)
    }

    private static func trailingInteger(_ line: String) -> UInt64? {
        var s = Substring(line)
        while let last = s.last, !last.isNumber { s = s.dropLast() }
        let digits = s.reversed().prefix(while: { $0.isNumber }).reversed()
        return UInt64(String(digits))
    }
}
