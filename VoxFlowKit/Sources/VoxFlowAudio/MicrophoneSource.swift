@preconcurrency import AVFoundation
import Darwin
import Foundation
import Synchronization
import VoxFlowCore

/// `AVAudioEngine` input tap → 16 kHz mono chunks with RMS (design §4 `MicrophoneSource`, ST-04n, FB-07).
public final class MicrophoneSource: MicrophoneCapturing, Sendable {
    private let chunkSeconds: Double
    private let microphoneUse: any MicrophoneUseMonitoring
    private let processing: @Sendable () -> MicrophoneProcessingOptions
    private let lease = MicrophoneCaptureLease()

    public init(chunkSeconds: Double = 0.1, microphoneUse: any MicrophoneUseMonitoring = UnmonitoredMicrophoneUse(),
                processing: @escaping @Sendable () -> MicrophoneProcessingOptions = { .init() }) {
        self.chunkSeconds = chunkSeconds
        self.microphoneUse = microphoneUse
        self.processing = processing
    }

    public func classifiedStartError(_ description: String) -> MicrophoneError {
        Self.classifyStartError(description, microphoneUse: microphoneUse)
    }

    private static func classifyStartError(
        _ description: String, microphoneUse: any MicrophoneUseMonitoring
    ) -> MicrophoneError {
        if case .inUse(let app) = microphoneUse.freshState() {
            return .inUse(by: app)
        }
        return .engineFailed(description)
    }

    public func start() -> AsyncThrowingStream<MicrophoneEvent, Error> {
        AsyncThrowingStream { continuation in
            guard lease.acquire() else {
                continuation.finish(throwing: MicrophoneError.inUse(by: "VoxFlow")); return
            }
            let classifyStartError: @Sendable (String) -> MicrophoneError = { [microphoneUse] description in
                Self.classifyStartError(description, microphoneUse: microphoneUse)
            }
            let session = CaptureSession(chunkSeconds: chunkSeconds, processing: processing(), classifyStartError: classifyStartError,
                                         continuation: continuation, onStopped: { [lease] in lease.release() })
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }
}

/// Everything mutable for one capture is confined to `queue`. The render callback only converts its
/// immutable input and hands samples back to that queue; each installed tap owns a separate chunker.
private final class CaptureSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.microphone")
    private let engine = AVAudioEngine()
    private let chunkSeconds: Double
    private let processing: MicrophoneProcessingOptions
    private let classifyStartError: @Sendable (String) -> MicrophoneError
    private let continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation
    private let onStopped: @Sendable () -> Void
    private var observer: NSObjectProtocol?
    private var stopped = false
    private var gapTracker = CaptureGapTracker()
    private var currentTap: CaptureAudioTapBox?

    init(chunkSeconds: Double, processing: MicrophoneProcessingOptions,
         classifyStartError: @escaping @Sendable (String) -> MicrophoneError,
         continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation,
         onStopped: @escaping @Sendable () -> Void) {
        self.chunkSeconds = chunkSeconds
        self.processing = processing
        self.classifyStartError = classifyStartError
        self.continuation = continuation
        self.onStopped = onStopped
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                guard let self else { return }
                let interruptedAt = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                self.queue.async { self.restart(interruptedAt: interruptedAt) }
            }
            do { try installTapAndRun(generation: gapTracker.activeToken) } catch { fail(error) }
        }
    }

    private func installTapAndRun(generation: UInt64) throws {
        let input = engine.inputNode
        try VoiceProcessingConfiguration.apply(processing, to: input)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { throw MicrophoneError.noInputDevice }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioSamples.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else { throw MicrophoneError.engineFailed("no converter \(inputFormat) → 16 kHz mono") }
        let tap = CaptureAudioTapBox(token: generation,
                                     chunkSamples: Int(chunkSeconds * AudioSamples.sampleRate))
        currentTap = tap
        let continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [self] buffer, time in
            let ratio = target.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            // `consumed` is read and set from the converter's input block, which `convert` invokes
            // synchronously and repeatedly on the calling (audio render) thread — never concurrently —
            // but the block's type is still checked as @Sendable, so the flag is boxed in a `Mutex`
            // (Sendable, no `@unchecked`/`nonisolated(unsafe)`) rather than captured as a plain `var`.
            let consumed = Mutex(false)
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                let alreadyConsumed = consumed.withLock { flag -> Bool in
                    let was = flag
                    flag = true
                    return was
                }
                if alreadyConsumed { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            let resumedAt = if time.isHostTimeValid {
                AVAudioTime.seconds(forHostTime: time.hostTime)
            } else {
                AVAudioTime.seconds(forHostTime: mach_absolute_time()) - Double(out.frameLength) / target.sampleRate
            }
            queue.async { [self] in
                guard !stopped, gapTracker.isActive(generation) else { return }
                let chunks = tap.append(samples, resumedAt: resumedAt, tracker: &gapTracker)
                for chunk in chunks { continuation.yield(.chunk(chunk)) }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            throw classifyStartError(error.localizedDescription)
        }
    }

    private func restart(interruptedAt: TimeInterval) {
        guard !stopped else { return }
        if let tail = currentTap?.flush(tracker: &gapTracker) {
            continuation.yield(.chunk(tail))
        }
        let resumeToken = gapTracker.begin(at: interruptedAt)
        currentTap = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { fail(MicrophoneError.noInputDevice); return }
        continuation.yield(.deviceChanged(name: AVCaptureDevice.default(for: .audio)?.localizedName))
        do { try installTapAndRun(generation: resumeToken) } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        stopInternal()
        continuation.finish(throwing: (error as? MicrophoneError) ?? MicrophoneError.engineFailed(String(describing: error)))
    }

    func stop() { queue.async { [self] in stopInternal() } }

    private func stopInternal() {
        guard !stopped else { return }
        stopped = true
        gapTracker.reset()
        currentTap = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Disabling the stopped voice-processing IO also releases its output attenuation.
        try? VoiceProcessingConfiguration.apply(.init(), to: engine.inputNode)
        onStopped()
    }
}
