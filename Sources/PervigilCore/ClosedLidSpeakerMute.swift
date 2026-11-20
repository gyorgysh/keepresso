import Foundation
import CoreAudio
import Observation

/// The Mac's built-in speakers, behind a seam so the closed-lid mute can be
/// tested without touching real audio.
public protocol BuiltInSpeakerMuting: AnyObject {
    /// Whether the built-in speakers are muted, or `nil` when there are none,
    /// they are not the active route (headphones in the jack), or mute can't
    /// be read or set.
    func isMuted() -> Bool?
    /// Mute or unmute the built-in speakers. Returns whether the change took.
    @discardableResult
    func setMuted(_ muted: Bool) -> Bool
}

/// Real backend over CoreAudio. Only a built-in output whose data source is the
/// internal speaker counts: on Apple silicon the headphone jack is a separate
/// built-in device, and on Intel the one built-in output switches its data
/// source to headphones, so neither ever gets muted. Mute leaves the volume
/// level alone, so unmuting brings back exactly the level the user had.
public final class CoreAudioBuiltInSpeakers: BuiltInSpeakerMuting {
    /// `'ispk'`, the internal speaker data source.
    static let internalSpeakerSource: UInt32 = 0x6973_706B

    public init() {}

    public func isMuted() -> Bool? {
        speakerDevice().flatMap(Self.isMuted)
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    public func setMuted(_ muted: Bool) -> Bool {
        guard let device = speakerDevice() else { return false }
        var address = Self.muteAddress
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr else { return false }
        // The HAL may apply a set asynchronously, so an immediate read-back can
        // still show the old value. An accepted mute counts as landed: calling
        // it failed would drop the marker and strand the speakers muted. An
        // unmute is read back, since a stale read only makes the release retry
        // a little later, which then finds the speakers unmuted.
        return muted || Self.isMuted(device) == false
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func speakerDevice() -> AudioObjectID? {
        Self.allDevices().first { device in
            Self.uint32(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
                == kAudioDeviceTransportTypeBuiltIn
                && Self.hasOutputStreams(device)
                && Self.uint32(device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
                    == Self.internalSpeakerSource
                && Self.muteSettable(device)
        }
    }

    private static func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func uint32(
        _ device: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func muteSettable(_ device: AudioObjectID) -> Bool {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }
}

/// Crash-recovery marker: present only while Pervigil holds the speakers
/// muted, so a relaunch after a crash or force quit can put the sound back.
public protocol SpeakerMuteMarking: AnyObject {
    var isSet: Bool { get }
    @discardableResult
    func set() -> Bool
    func clear()
}

/// Marker file at `~/Library/Application Support/Pervigil/speaker-mute`.
public final class FileSpeakerMuteMarker: SpeakerMuteMarking {
    private let file: AppSupportFlagFile

    public init(url: URL = FileSpeakerMuteMarker.defaultURL()) {
        file = AppSupportFlagFile(url: url)
    }

    public static func defaultURL() -> URL {
        AppSupportFlagFile.defaultURL(named: "speaker-mute")
    }

    public var isSet: Bool { file.isPresent }
    public func set() -> Bool { file.create() }
    public func clear() { file.remove() }
}

/// Mutes the built-in speakers while the lid is closed and closed-display mode
/// is active, then unmutes them when either ends. Only a mute it applied is
/// ever undone: speakers the user had already muted stay muted, and if the
/// user unmutes them while the lid is shut, nothing is touched on open. The
/// marker is written before muting, so a crash in between still restores.
@MainActor
@Observable
public final class ClosedLidSpeakerMuteController {
    /// True while Pervigil holds the built-in speakers muted.
    public private(set) var holding = false

    /// How long to wait before probing again when no built-in speakers are
    /// reachable (headphones on an Intel jack, or none at all). Each probe is
    /// a full CoreAudio device scan, too much to repeat every second.
    static let unreachableRetry: TimeInterval = 10

    @ObservationIgnored private let speakers: BuiltInSpeakerMuting
    @ObservationIgnored private let marker: SpeakerMuteMarking
    @ObservationIgnored private var arming = ThermalArming()
    /// Set once this lid-closed stretch has been handled (muted, or found
    /// already muted), so it never re-mutes after the user unmutes with the
    /// lid shut. Cleared when the stretch ends.
    @ObservationIgnored private var handledThisStretch = false
    /// The last real readings. Either an open lid or an inactive override
    /// releases a recovered mute, even before the other reading arrives.
    @ObservationIgnored private var lastLidClosed: Bool?
    @ObservationIgnored private var lastClosedDisplayActive: Bool?
    /// An unmute may land after its read-back failed. Finish that release
    /// before acquiring another hold, even if the lid has closed again.
    @ObservationIgnored private var releasePending = false
    /// No speaker probe before this instant (see ``unreachableRetry``).
    @ObservationIgnored private var nextProbeAt: Date?

    public init(
        speakers: BuiltInSpeakerMuting = CoreAudioBuiltInSpeakers(),
        marker: SpeakerMuteMarking = FileSpeakerMuteMarker()
    ) {
        self.speakers = speakers
        self.marker = marker
    }

    /// Feed the latest readings. `nil` lid or override readings keep the last
    /// known value, like the other closed-lid features.
    public func tick(enabled: Bool, lidClosed: Bool?, closedDisplayActive: Bool?, now: Date = Date()) {
        if let lidClosed { lastLidClosed = lidClosed }
        if let closedDisplayActive { lastClosedDisplayActive = closedDisplayActive }
        let armed = arming.update(lidClosed: lidClosed, sleepOverrideActive: closedDisplayActive)
        if releasePending {
            release(now: now)
            guard !holding else { return }
        }
        guard enabled, armed else {
            handledThisStretch = false
            // Keep a recovered mute while the readings could still mean a
            // shut lid in closed-display mode. Either known-off input, or
            // the feature off, releases without waiting for the rest.
            if enabled, lastLidClosed != false, lastClosedDisplayActive != false { return }
            release(now: now)
            return
        }
        guard !handledThisStretch, !holding, probeAllowed(now) else { return }
        guard let muted = speakers.isMuted() else {
            nextProbeAt = now.addingTimeInterval(Self.unreachableRetry)
            return
        }
        nextProbeAt = nil
        if muted {
            handledThisStretch = true
            return
        }
        guard marker.set() else {
            nextProbeAt = now.addingTimeInterval(Self.unreachableRetry)
            return
        }
        if speakers.setMuted(true) {
            holding = true
            handledThisStretch = true
        } else {
            marker.clear()
            nextProbeAt = now.addingTimeInterval(Self.unreachableRetry)
        }
    }

    /// Unmute if this controller muted the speakers and they are still muted.
    /// Safe to call at any time, including at quit, where it always probes.
    /// When the unmute can't land (it failed, or the speakers aren't reachable
    /// right now) the hold and the marker stay, so a later tick or the next
    /// launch tries again.
    public func release() {
        release(now: nil)
    }

    private func release(now: Date?) {
        guard holding else { return }
        releasePending = true
        if let now, !probeAllowed(now) { return }
        switch speakers.isMuted() {
        case true?:
            guard speakers.setMuted(false) else {
                // Same backoff as unreachable speakers: each attempt is a
                // full device scan, too much to repeat every second.
                if let now { nextProbeAt = now.addingTimeInterval(Self.unreachableRetry) }
                return
            }
        case nil:
            if let now { nextProbeAt = now.addingTimeInterval(Self.unreachableRetry) }
            return
        case false?:
            // Unmuted by the user while the lid was shut: theirs to keep.
            break
        }
        nextProbeAt = nil
        holding = false
        releasePending = false
        marker.clear()
    }

    private func probeAllowed(_ now: Date) -> Bool {
        guard let nextProbeAt else { return true }
        return now >= nextProbeAt
    }

    /// Launch-time recovery: a marker left behind means a previous run muted
    /// the speakers and never got to unmute them. Taken back as a held mute,
    /// released by the first tick that finds the lid open, the mode off, or
    /// the feature off. With the lid still shut in closed-display mode it
    /// simply stays muted, with no audible gap.
    public func restoreIfNeeded() {
        guard !holding, marker.isSet else { return }
        holding = true
    }
}
