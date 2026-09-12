import AVFoundation
import CoreAudio
import Synchronization

/// The system's current default audio-input device (design ST-04 "Input device"). A protocol so
/// `AudioViewModel` can be tested against a fake instead of the real hardware/`AVCaptureDevice`.
protocol InputDeviceProviding: Sendable {
    /// The default input device's display name, or nil when nothing is available (ST-04n).
    func defaultInputName() -> String?
    /// Default-input changes while Settings is open, including connect/disconnect transitions.
    func changes() -> AsyncStream<String?>
}

extension InputDeviceProviding {
    func changes() -> AsyncStream<String?> { AsyncStream { $0.finish() } }
}

struct AVCaptureInputDeviceProvider: InputDeviceProviding {
    func defaultInputName() -> String? { AVCaptureDevice.default(for: .audio)?.localizedName }

    func changes() -> AsyncStream<String?> {
        AsyncStream { continuation in
            let listener = DefaultInputListener(continuation: continuation)
            guard listener.start() else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [listener] _ in listener.stop() }
        }
    }
}

/// CoreAudio's imported listener block lacks `Sendable`; this token confines it to one private
/// queue and synchronizes its only cross-thread operation, once-only removal on stream termination.
private final class DefaultInputListener: @unchecked Sendable {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.default-input")
    private let listener: AudioObjectPropertyListenerBlock
    private let registered = Mutex(false)

    init(continuation: AsyncStream<String?>.Continuation) {
        listener = { _, _ in
            continuation.yield(AVCaptureDevice.default(for: .audio)?.localizedName)
        }
    }

    func start() -> Bool {
        var address = address
        let succeeded = AudioObjectAddPropertyListenerBlock(system, &address, queue, listener) == noErr
        if succeeded { registered.withLock { $0 = true } }
        return succeeded
    }

    func stop() {
        let shouldRemove = registered.withLock { value -> Bool in
            guard value else { return false }
            value = false
            return true
        }
        guard shouldRemove else { return }
        var address = address
        AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
    }

    deinit { stop() }
}
