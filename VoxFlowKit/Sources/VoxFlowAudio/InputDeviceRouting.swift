@preconcurrency import AVFoundation
import AudioToolbox
import VoxFlowCore

/// Accessed only while configuring or validating a capture on its serial queue.
protocol InputDeviceNode: AnyObject {
    func selectInputDevice(_ id: AudioDeviceID) throws
    func currentInputDevice() throws -> AudioDeviceID
}

enum InputDeviceRouting {
    /// Nil retains AVAudioEngine's automatic default route. Explicit UIDs never fall back.
    static func apply(uid: String?, to node: any InputDeviceNode,
                      resolve: (String) -> AudioDeviceID?) throws -> AudioDeviceID? {
        guard let uid else { return nil }
        guard let requested = resolve(uid), requested != kAudioObjectUnknown else {
            throw MicrophoneError.noInputDevice
        }
        // Avoid reconfiguring an already-selected unit and generating another engine-change event.
        if (try? node.currentInputDevice()) != requested { try node.selectInputDevice(requested) }
        try verify(expected: requested, on: node)
        return requested
    }

    static func verify(expected: AudioDeviceID?, on node: any InputDeviceNode) throws {
        guard let expected else { return }
        guard try node.currentInputDevice() == expected else { throw MicrophoneError.noInputDevice }
    }
}

extension AVAudioInputNode: InputDeviceNode {
    func selectInputDevice(_ id: AudioDeviceID) throws {
        guard let audioUnit else { throw MicrophoneError.noInputDevice }
        var device = id
        let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw MicrophoneError.engineFailed("Could not select microphone (AudioUnit status \(status)).")
        }
    }

    func currentInputDevice() throws -> AudioDeviceID {
        guard let audioUnit else { throw MicrophoneError.noInputDevice }
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, &size)
        guard status == noErr, size == MemoryLayout<AudioDeviceID>.size else {
            throw MicrophoneError.engineFailed("Could not verify microphone (AudioUnit status \(status)).")
        }
        return device
    }
}
