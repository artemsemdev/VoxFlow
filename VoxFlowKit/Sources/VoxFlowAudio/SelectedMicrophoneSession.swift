@preconcurrency import AudioToolbox
import Foundation
import VoxFlowCore

/// All state and AudioQueue callbacks run on `queue`. Disposal is enqueued outside callbacks;
/// it completes before releasing the shared capture lease. No audio pointer crosses this queue.
final class SelectedMicrophoneSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.selected-microphone")
    private let uid: String
    private let classifyError: @Sendable (String) -> MicrophoneError
    private let continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation
    private let onStopped: @Sendable () -> Void
    private var audioQueue: AudioQueueRef?
    private var changes: Task<Void, Never>?
    private var stopped = false
    private var chunker: AudioChunker

    init(uid: String, chunkSeconds: Double,
         classifyError: @escaping @Sendable (String) -> MicrophoneError,
         continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation,
         onStopped: @escaping @Sendable () -> Void) {
        self.uid = uid
        self.classifyError = classifyError
        self.continuation = continuation
        self.onStopped = onStopped
        chunker = AudioChunker(seconds: chunkSeconds)
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            do {
                try requireDevice()
                let events = AudioInputDevices.changes()
                changes = Task { [weak self] in
                    for await _ in events {
                        guard !Task.isCancelled, let self else { return }
                        self.queue.async {
                            guard !self.stopped else { return }
                            do { try self.requireDevice() } catch { self.fail(error) }
                        }
                    }
                }
                // AudioQueue performs hardware conversion without a shared input/output graph.
                var format = AudioStreamBasicDescription(mSampleRate: AudioSamples.sampleRate,
                    mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                    mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
                try check(AudioQueueNewInputWithDispatchQueue(&audioQueue, &format, 0, queue) {
                    [weak self] native, buffer, _, _, _ in
                    self?.receive(native, buffer: buffer)
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
                try requireDevice()
                try check(AudioQueueStart(audioQueue, nil))
            } catch { fail(error) }
        }
    }

    private func receive(_ native: AudioQueueRef, buffer: AudioQueueBufferRef) {
        guard !stopped else { return }
        do {
            try requireDevice()
            let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
            let samples = Array(UnsafeBufferPointer(
                start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: count))
            for chunk in chunker.append(samples) { continuation.yield(.chunk(chunk)) }
            try check(AudioQueueEnqueueBuffer(native, buffer, 0, nil))
        } catch {
            // AudioQueueDispose must not run within its own buffer callback.
            queue.async { [self] in fail(error) }
        }
    }

    private func requireDevice() throws {
        guard AudioInputDevices.deviceID(forUID: uid) != nil else { throw MicrophoneError.noInputDevice }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw classifyError("Could not record from the selected microphone (AudioQueue status \(status)).")
        }
    }

    private func fail(_ error: Error) {
        stopInternal()
        continuation.finish(throwing: error)
    }

    func stop() { queue.async { [self] in stopInternal() } }

    private func stopInternal() {
        guard !stopped else { return }
        stopped = true
        changes?.cancel(); changes = nil
        if let audioQueue {
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, true)
            self.audioQueue = nil
        }
        onStopped()
    }
}
