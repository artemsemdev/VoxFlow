@preconcurrency import AudioToolbox
import Foundation
import VoxFlowCore

/// The callback returns false after shutdown begins, so pending buffers are not re-enqueued.
protocol SelectedMicrophoneQueuing: Sendable {
    func start(on queue: DispatchQueue,
               receive: @escaping @Sendable (Result<[Float], MicrophoneError>) -> Bool) throws
    func stop()
}

/// Startup and callbacks are serialized by the session. Stop receives exclusive ownership after
/// the session marks itself stopped; callbacks then return false without touching queue resources.
/// Synchronous disposal waits for those callbacks before releasing the native handle.
final class SelectedMicrophoneQueue: SelectedMicrophoneQueuing, @unchecked Sendable {
    private let uid: String
    private let classifyError: @Sendable (String) -> MicrophoneError
    private var audioQueue: AudioQueueRef?

    init(uid: String, classifyError: @escaping @Sendable (String) -> MicrophoneError) {
        self.uid = uid
        self.classifyError = classifyError
    }

    func start(on queue: DispatchQueue,
               receive: @escaping @Sendable (Result<[Float], MicrophoneError>) -> Bool) throws {
        // AudioQueue performs hardware conversion without a shared input/output graph.
        var format = AudioStreamBasicDescription(mSampleRate: AudioSamples.sampleRate,
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioQueueNewInputWithDispatchQueue(&audioQueue, &format, 0, queue) {
            [classifyError] native, buffer, _, _, _ in
            let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
            let samples = Array(UnsafeBufferPointer(
                start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: count))
            guard receive(.success(samples)) else { return }
            let status = AudioQueueEnqueueBuffer(native, buffer, 0, nil)
            if status != noErr {
                _ = receive(.failure(classifyError("Could not enqueue microphone buffer (AudioQueue status \(status)).")))
            }
        })
        guard let audioQueue else { throw MicrophoneError.noInputDevice }
        let device = uid as CFString
        var deviceRef = Unmanaged.passUnretained(device)
        try withExtendedLifetime(device) {
            try check(AudioQueueSetProperty(audioQueue, kAudioQueueProperty_CurrentDevice,
                &deviceRef, UInt32(MemoryLayout<Unmanaged<CFString>>.size)))
        }
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            try check(AudioQueueAllocateBuffer(audioQueue, 6_400, &buffer))
            guard let buffer else { throw MicrophoneError.engineFailed("Could not allocate microphone buffer.") }
            try check(AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil))
        }
        guard AudioInputDevices.deviceID(forUID: uid) != nil else { throw MicrophoneError.noInputDevice }
        try check(AudioQueueStart(audioQueue, nil))
    }

    func stop() {
        if let audioQueue {
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, true)
            self.audioQueue = nil
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw classifyError("Could not record from the selected microphone (AudioQueue status \(status)).")
        }
    }
}
