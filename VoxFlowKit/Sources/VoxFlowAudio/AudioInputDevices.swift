import CoreAudio
import Foundation
import Synchronization
import VoxFlowCore

/// Read-only CoreAudio discovery: enumeration and notifications never open a microphone or change
/// the system default. Hardware object IDs are resolved afresh; persisted selections use device UIDs.
public enum AudioInputDevices {
    public static func available() -> [AudioInputDevice] {
        deviceIDs().compactMap(device).sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    public static func defaultDevice() -> AudioInputDevice? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return device(id)
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return deviceIDs().first { device($0)?.id == uid }
    }

    public static func changes() -> AsyncStream<Void> {
        changes { selector, changed in
            let listener = InputDeviceListener(selector: selector, changed: changed)
            guard listener.start() else { return nil }
            return { listener.stop() }
        }
    }

    typealias Registration = @Sendable (AudioObjectPropertySelector, @escaping @Sendable () -> Void) -> (@Sendable () -> Void)?

    static func changes(register: Registration) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let lifetime = InputDeviceListenerLifetime()
            continuation.onTermination = { _ in lifetime.stop() }
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                guard let stop = register(selector, { continuation.yield(()) }) else {
                    lifetime.stop(); continuation.finish(); return
                }
                lifetime.add(stop)
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size >= MemoryLayout<AudioDeviceID>.size else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    private static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard id != kAudioObjectUnknown, hasInputChannels(id),
              let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty,
              let name = string(id, kAudioObjectPropertyName), !name.isEmpty else { return nil }
        return AudioInputDevice(id: uid, name: name)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        // CoreAudio transfers ownership for both Name and DeviceUID (AudioHardwareBase.h).
        return value?.takeRetainedValue() as String?
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }
}

/// A stream may terminate while registration is completing. Newly acquired tokens are immediately
/// removed after termination; normal shutdown atomically takes every remover exactly once.
private final class InputDeviceListenerLifetime: Sendable {
    private let removers = Mutex<[@Sendable () -> Void]?>([])
    func add(_ remove: @escaping @Sendable () -> Void) {
        let stopped = removers.withLock { values in
            guard values != nil else { return true }
            values?.append(remove); return false
        }
        if stopped { remove() }
    }
    func stop() {
        let pending = removers.withLock { values in defer { values = nil }; return values ?? [] }
        pending.forEach { $0() }
    }
    deinit { stop() }
}

/// CoreAudio's block is not imported as Sendable. It is immutable, invoked only on the private
/// queue and captures only a Sendable callback. Registration completes before the token is published;
/// the lock makes removal once-only, and CoreAudio is called outside that lock when removing.
private final class InputDeviceListener: @unchecked Sendable {
    private let selector: AudioObjectPropertySelector
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.input-device-catalog")
    private let block: AudioObjectPropertyListenerBlock
    private let registered = Mutex(false)
    init(selector: AudioObjectPropertySelector, changed: @escaping @Sendable () -> Void) {
        self.selector = selector
        block = { _, _ in changed() }
    }
    func start() -> Bool {
        registered.withLock { value in
            if value { return true }
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            value = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr
            return value
        }
    }
    func stop() {
        let shouldRemove = registered.withLock { value in
            guard value else { return false }
            value = false; return true
        }
        guard shouldRemove else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }
    deinit { stop() }
}
