import Foundation
import CoreAudio
import CoreMediaIO

/// A point-in-time reading of the machine's AV activity: whether any process
/// is using a camera or a microphone, and whether sound is playing.
public struct MediaActivitySnapshot: Equatable, Sendable {
    /// Some process is capturing from a camera (the green-dot state).
    public var cameraInUse: Bool
    /// Some process is capturing from an audio input device (the orange-dot
    /// state).
    public var microphoneInUse: Bool
    /// Some process is playing sound through an audio output device.
    public var audioPlaying: Bool
    /// Bundle ids of the processes currently capturing the microphone, from
    /// the macOS 14 per-process CoreAudio API. Lets an app-scoped mic rule ask
    /// "is *Discord* on a call" rather than "is *anything* using the mic".
    ///
    /// These are the *capturing* process's ids, which for Electron/Chromium
    /// call apps is a child helper (`com.hnc.Discord.helper.Renderer`), not the
    /// top-level app, so callers match by bundle-id prefix. Empty when the mic
    /// is idle, or when the process API is unavailable; the device-level
    /// ``microphoneInUse`` stays the authority for the unscoped rule.
    public var micCapturingBundleIDs: Set<String>

    public init(
        cameraInUse: Bool = false,
        microphoneInUse: Bool = false,
        audioPlaying: Bool = false,
        micCapturingBundleIDs: Set<String> = []
    ) {
        self.cameraInUse = cameraInUse
        self.microphoneInUse = microphoneInUse
        self.audioPlaying = audioPlaying
        self.micCapturingBundleIDs = micCapturingBundleIDs
    }
}

/// One process captured from the microphone right now: its pid and the bundle
/// id CoreAudio reported for it. The pid lets the UI resolve an Electron helper
/// back to its top-level app (via its executable path) when offering "add the
/// app using your mic now"; matching itself only needs the bundle id.
public struct MicCapturer: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String

    public init(pid: pid_t, bundleID: String) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Abstraction over the system's AV device activity so media triggers can be
/// tested without a real camera or call. Mirrors the other monitor seams.
public protocol MediaActivityMonitoring: AnyObject {
    var current: MediaActivitySnapshot { get }
}

/// Real backend over CoreMediaIO (camera) and CoreAudio (microphone, playback).
///
/// It reads only the devices' "is running somewhere" property, the same state
/// that drives the menu bar's green camera dot: whether *any* process has the
/// device running. It never opens a capture session, so no TCC camera or
/// microphone permission is involved and no prompt ever appears.
///
/// The property reads are cheap HAL queries, but the trigger engine and the
/// menu's live rule list both evaluate within the same tick, so readings are
/// cached briefly (mirroring ``HostCPULoadReader``). One caveat, documented
/// rather than special-cased: a combined input+output device (some USB
/// headsets, aggregate devices) reports a single running flag, so playback
/// through it also reads as microphone use. Built-in mics and speakers are
/// separate devices, where the distinction is exact.
public final class CoreMediaActivityMonitor: MediaActivityMonitoring {
    private let cache: TTLCache<MediaActivitySnapshot>

    public convenience init() {
        self.init(probe: Self.probeSystem)
    }

    /// The probe and clock are injectable so the cache can be unit-tested
    /// without real AV hardware.
    init(
        ttl: TimeInterval = 1.5,
        now: @escaping () -> Date = Date.init,
        probe: @escaping () -> MediaActivitySnapshot
    ) {
        cache = TTLCache(ttl: ttl, now: now, probe: probe)
    }

    public var current: MediaActivitySnapshot { cache.current }

    /// The real probe: sweep CoreMediaIO video devices and CoreAudio devices.
    static func probeSystem() -> MediaActivitySnapshot {
        let audio = audioActivity()
        // Only walk the per-process list when the mic is actually live: an idle
        // mic yields an empty capturer set without touching the process API.
        let capturers = audio.inputRunning ? currentMicCapturers() : []
        return MediaActivitySnapshot(
            cameraInUse: cameraInUse(),
            microphoneInUse: audio.inputRunning,
            audioPlaying: audio.outputRunning,
            micCapturingBundleIDs: Set(capturers.map(\.bundleID))
        )
    }

    // MARK: - CoreMediaIO (camera)

    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == kCMIOHardwareNoError,
              dataSize > 0
        else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, dataSize, &dataUsed, &devices)
            == kCMIOHardwareNoError
        else { return false }

        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        return devices.contains { device in
            var running: UInt32 = 0
            var used: UInt32 = 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            return CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, size, &used, &running)
                == kCMIOHardwareNoError && running != 0
        }
    }

    // MARK: - CoreAudio (microphone + playback)

    /// Whether any input-capable device and any output-capable device is
    /// running somewhere, in one sweep of the device list.
    private static func audioActivity() -> (inputRunning: Bool, outputRunning: Bool) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return (false, false) }
        var devices = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &devices) == noErr
        else { return (false, false) }

        var inputRunning = false
        var outputRunning = false
        for device in devices {
            guard isRunningSomewhere(device) else { continue }
            if hasStreams(device, scope: kAudioObjectPropertyScopeInput) { inputRunning = true }
            if hasStreams(device, scope: kAudioObjectPropertyScopeOutput) { outputRunning = true }
            if inputRunning && outputRunning { break }
        }
        return (inputRunning, outputRunning)
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr
            && running != 0
    }

    private static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr
            && dataSize > 0
    }

    // MARK: - CoreAudio (per-process microphone capture, macOS 14+)

    /// The processes capturing from the microphone right now, each with the
    /// bundle id CoreAudio attributes to it. Reads the process-object list
    /// (`kAudioHardwarePropertyProcessObjectList`) and keeps those whose
    /// `kAudioProcessPropertyIsRunningInput` flag is set.
    ///
    /// Unprivileged: this reads process *state*, never opening a capture
    /// stream, so no microphone TCC prompt appears (the app has no mic
    /// entitlement and needs none). The macOS 14 deployment floor guarantees
    /// the process API exists.
    public static func currentMicCapturers() -> [MicCapturer] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &processes) == noErr
        else { return [] }

        var capturers: [MicCapturer] = []
        for process in processes where processFlag(process, kAudioProcessPropertyIsRunningInput) {
            guard let bundleID = processBundleID(process), !bundleID.isEmpty else { continue }
            capturers.append(MicCapturer(pid: processPID(process), bundleID: bundleID))
        }
        return capturers
    }

    private static func processFlag(_ process: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func processBundleID(_ process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out: CFString?
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? out as String? : nil
    }

    private static func processPID(_ process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        return pid
    }

    /// The URL of the outermost `.app` bundle enclosing an executable path, or
    /// `nil` when the path is not inside an app bundle. Resolves a capturing
    /// process (often an Electron helper buried inside the app) back to its
    /// top-level app, e.g.
    /// `/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)`
    /// → `/Applications/Discord.app`. Pure string work, no filesystem I/O, so
    /// the app layer can turn a ``MicCapturer`` pid into a clean bundle id and
    /// name for the "add the app using your mic now" picker.
    public static func enclosingAppBundleURL(forExecutablePath path: String) -> URL? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
    }
}

/// Fires while any process is using the camera or the microphone: a video
/// call, a recording, a stream. Covers every meeting app at once, including
/// browser-tab calls that ``AppTrigger`` can't see.
public final class MediaInUseTrigger: Trigger {
    /// Which capture device kind this trigger watches.
    public enum Device: String, Codable, Sendable, CaseIterable {
        case camera
        case microphone

        var label: String {
            switch self {
            case .camera:     return L("Camera in use")
            case .microphone: return L("Microphone in use")
            }
        }
    }

    /// The device kind this trigger watches.
    public var device: Device

    /// Optional bundle-id scope for the microphone. `nil` (the default) is the
    /// unscoped rule: satisfied while *any* process uses the mic. Non-`nil`
    /// scopes it to those apps, so it fires only while one of them is on a
    /// call. An empty array matches nothing (a half-configured scope must not
    /// pin the Mac awake). Ignored for ``Device/camera``, which has no
    /// per-process API to scope by.
    public var appFilter: [String]?

    private let monitor: MediaActivityMonitoring

    public init(
        device: Device,
        appFilter: [String]? = nil,
        monitor: MediaActivityMonitoring = CoreMediaActivityMonitor()
    ) {
        self.device = device
        self.appFilter = appFilter
        self.monitor = monitor
    }

    public var label: String { device.label }

    public func isSatisfied() -> Bool {
        let snapshot = monitor.current
        switch device {
        case .camera:
            return snapshot.cameraInUse
        case .microphone:
            guard let filter = appFilter else { return snapshot.microphoneInUse }
            return Self.captures(filter, in: snapshot.micCapturingBundleIDs)
        }
    }

    /// Whether any capturing bundle id belongs to one of the `targets`. A
    /// target matches a capturer that equals it or is a child of it, i.e. the
    /// capturer's id is `target` or starts with `target + "."`. That prefix
    /// rule is what lets a rule for `com.hnc.Discord` catch Discord's actual
    /// capturer, the helper `com.hnc.Discord.helper.Renderer`, while a native
    /// call app (whose own process captures) matches exactly. Empty targets, or
    /// empty target strings, never match. Exposed for direct unit testing.
    static func captures(_ targets: [String], in capturing: Set<String>) -> Bool {
        for target in targets where !target.isEmpty {
            if capturing.contains(where: { $0 == target || $0.hasPrefix(target + ".") }) {
                return true
            }
        }
        return false
    }
}

/// Fires while sound is playing through any output device: music, a video, a
/// podcast. The factory wraps it in a ``GracePeriodTrigger`` with
/// ``releaseGrace`` so the gap between tracks, or a moment of buffering,
/// doesn't drop the session and immediately restart it.
public final class AudioPlayingTrigger: Trigger {
    /// How long the rule keeps holding after playback stops. Long enough to
    /// ride out track gaps and brief pauses, short enough that the Mac isn't
    /// pinned awake for long once the sound has really ended.
    public static let releaseGrace: TimeInterval = 30

    private let monitor: MediaActivityMonitoring

    public init(monitor: MediaActivityMonitoring = CoreMediaActivityMonitor()) {
        self.monitor = monitor
    }

    public var label: String { L("Audio playing") }

    public func isSatisfied() -> Bool {
        monitor.current.audioPlaying
    }
}
