import AudioToolbox
import CoreAudio
import Foundation

/// An output device's volume and mute, and the device's stable UID, so lid
/// open restores the device lid close muted even if the default output
/// changed in between (spec section 4).
struct AudioOutput: Equatable, Sendable {
    var deviceUID: String
    var volume: Float
    var muted: Bool
}

/// Volume and mute of output devices, so lid close can mute and lid open
/// can restore exactly (spec section 4).
protocol AudioControlling: Sendable {
    /// The default output device now.
    func read() throws -> AudioOutput
    /// Sets the device with this UID, or the default output device when
    /// nil (a journal entry from a build that did not record the device).
    /// Throws `AudioDeviceMissingError` when no connected device has the UID.
    func apply(volume: Float, muted: Bool, deviceUID: String?) throws
    /// Mutes the device with this UID; throws `AudioDeviceMissingError`
    /// when it is not connected.
    func mute(deviceUID: String) throws
}

struct AudioControlError: Error, LocalizedError, Sendable {
    let what: String
    let status: OSStatus

    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

/// The output device a journal entry is for is not connected.
struct AudioDeviceMissingError: Error, LocalizedError, Sendable {
    let deviceUID: String

    var errorDescription: String? { "output device \(deviceUID) is not connected" }
}

/// Does nothing; the default for SessionManager so tests and non-audio
/// paths need no CoreAudio.
struct NoopAudioControl: AudioControlling {
    func read() throws -> AudioOutput { AudioOutput(deviceUID: "none", volume: 1, muted: false) }
    func apply(volume: Float, muted: Bool, deviceUID: String?) throws {}
    func mute(deviceUID: String) throws {}
}

/// CoreAudio implementation: reads the default output device, and sets the
/// device a UID names.
struct CoreAudioControl: AudioControlling {
    func read() throws -> AudioOutput {
        let device = try defaultOutputDevice()
        var volume: Float32 = 0
        try get(device, Self.volumeAddress, &volume, "read volume")
        var muted: UInt32 = 0
        try get(device, Self.muteAddress, &muted, "read mute")
        return AudioOutput(deviceUID: try uid(of: device), volume: Float(volume), muted: muted != 0)
    }

    func apply(volume: Float, muted: Bool, deviceUID: String?) throws {
        let device = try deviceUID.map { try self.device(withUID: $0) } ?? defaultOutputDevice()
        var v = Float32(min(max(volume, 0), 1))
        try set(device, Self.volumeAddress, &v, "set volume")
        var m: UInt32 = muted ? 1 : 0
        try set(device, Self.muteAddress, &m, "set mute")
    }

    func mute(deviceUID: String) throws {
        let device = try device(withUID: deviceUID)
        var m: UInt32 = 1
        try set(device, Self.muteAddress, &m, "mute")
    }

    // MARK: CoreAudio plumbing

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw AudioControlError(what: "default output device", status: status)
        }
        return device
    }

    private func uid(of device: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr, let uid = value?.takeRetainedValue() else {
            throw AudioControlError(what: "read device UID", status: status)
        }
        return uid as String
    }

    /// The connected device with this UID, looked up in the device list.
    private func device(withUID uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { throw AudioControlError(what: "list devices", status: status) }
        var devices = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if !devices.isEmpty {
            status = devices.withUnsafeMutableBytes { buffer in
                AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
            }
            guard status == noErr else { throw AudioControlError(what: "list devices", status: status) }
        }
        let count = min(devices.count, Int(size) / MemoryLayout<AudioObjectID>.size)
        for device in devices.prefix(count) where (try? self.uid(of: device)) == uid {
            return device
        }
        throw AudioDeviceMissingError(deviceUID: uid)
    }

    private func get<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }

    private func set<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &value) { ptr in
            AudioObjectSetPropertyData(device, &addr, 0, nil, size, UnsafeRawPointer(ptr))
        }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }
}
