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

    public init(cameraInUse: Bool = false, microphoneInUse: Bool = false, audioPlaying: Bool = false) {
        self.cameraInUse = cameraInUse
        self.microphoneInUse = microphoneInUse
        self.audioPlaying = audioPlaying
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
    private let ttl: TimeInterval
    private let now: () -> Date
    private let probe: () -> MediaActivitySnapshot
    private var cached: MediaActivitySnapshot?
    private var cachedAt: Date?

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
        self.ttl = ttl
        self.now = now
        self.probe = probe
    }

    public var current: MediaActivitySnapshot {
        if let cached, let cachedAt, now().timeIntervalSince(cachedAt) < ttl {
            return cached
        }
        let snapshot = probe()
        cached = snapshot
        cachedAt = now()
        return snapshot
    }

    /// The real probe: sweep CoreMediaIO video devices and CoreAudio devices.
    static func probeSystem() -> MediaActivitySnapshot {
        let audio = audioActivity()
        return MediaActivitySnapshot(
            cameraInUse: cameraInUse(),
            microphoneInUse: audio.inputRunning,
            audioPlaying: audio.outputRunning
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
            case .camera:     return "Camera in use"
            case .microphone: return "Microphone in use"
            }
        }
    }

    /// The device kind this trigger watches.
    public var device: Device

    private let monitor: MediaActivityMonitoring

    public init(device: Device, monitor: MediaActivityMonitoring = CoreMediaActivityMonitor()) {
        self.device = device
        self.monitor = monitor
    }

    public var label: String { device.label }

    public func isSatisfied() -> Bool {
        let snapshot = monitor.current
        switch device {
        case .camera:     return snapshot.cameraInUse
        case .microphone: return snapshot.microphoneInUse
        }
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

    public var label: String { "Audio playing" }

    public func isSatisfied() -> Bool {
        monitor.current.audioPlaying
    }
}
