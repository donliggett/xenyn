import AVFoundation
import CoreAudio
import Foundation

struct AudioDevice: Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// Thin helpers over the Core Audio hardware API.
enum AudioDevices {
    static let blackHoleUID = "BlackHole2ch_UID"

    static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let name = string(id, kAudioObjectPropertyName),
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDevice(id: id, name: name, uid: uid)
        }
    }

    /// The BlackHole 2ch virtual device, if installed.
    static func blackHole2ch() -> AudioDevice? {
        all().first { $0.uid == blackHoleUID || $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") }
    }

    static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// Points an engine's output node at a specific device. Call before the engine starts.
    static func bind(_ engine: AVAudioEngine, to device: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else {
            throw XenynError.audio("The audio engine has no output unit.")
        }
        var id = device
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw XenynError.coreAudio(status, "select the output device") }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}
