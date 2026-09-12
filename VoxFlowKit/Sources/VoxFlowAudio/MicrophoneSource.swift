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
    private let inputDeviceUID: @Sendable () -> String?
    private let lease = MicrophoneCaptureLease()

    public init(chunkSeconds: Double = 0.1, microphoneUse: any MicrophoneUseMonitoring = UnmonitoredMicrophoneUse(),
                inputDeviceUID: @escaping @Sendable () -> String? = { nil },
                processing: @escaping @Sendable () -> MicrophoneProcessingOptions = { .init() }) {
        self.chunkSeconds = chunkSeconds
        self.microphoneUse = microphoneUse
        self.processing = processing
        self.inputDeviceUID = inputDeviceUID
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
            // A settings edit affects the next capture, never a running session or its restarts.
            let session = CaptureSession(chunkSeconds: chunkSeconds, processing: processing(), inputDeviceUID: inputDeviceUID(),
                                         classifyStartError: classifyStartError,
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
    private let inputDeviceUID: String?
    private let classifyStartError: @Sendable (String) -> MicrophoneError
    private let continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation
    private let onStopped: @Sendable () -> Void
    private var observer: NSObjectProtocol?
    private var deviceChanges: Task<Void, Never>?
    private var stopped = false
    private var gapTracker = CaptureGapTracker()
    private var currentTap: CaptureAudioTapBox?

    init(chunkSeconds: Double, processing: MicrophoneProcessingOptions, inputDeviceUID: String?,
         classifyStartError: @escaping @Sendable (String) -> MicrophoneError,
         continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation,
         onStopped: @escaping @Sendable () -> Void) {
        self.chunkSeconds = chunkSeconds
        self.processing = processing
        self.inputDeviceUID = inputDeviceUID
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
            if inputDeviceUID != nil {
                // Register before engine startup so disconnects cannot fall into a subscription gap.
                let changes = AudioInputDevices.changes()
                deviceChanges = Task { [weak self] in
                    for await _ in changes {
                        guard !Task.isCancelled, let self else { return }
                        self.queue.async {
                            guard !self.stopped, let uid = self.inputDeviceUID else { return }
                            // A disconnected selected input can stop producing buffers entirely.
                            if AudioInputDevices.deviceID(forUID: uid) == nil { self.fail(MicrophoneError.noInputDevice) }
                        }
                    }
                }
            }
            do { try installTapAndRun(generation: gapTracker.activeToken) } catch { fail(error) }
        }
    }

    private func installTapAndRun(generation: UInt64) throws {
        var input = engine.inputNode
        _ = try InputDeviceRouting.apply(uid: inputDeviceUID, to: input, resolve: AudioInputDevices.deviceID(forUID:))
        try VoiceProcessingConfiguration.apply(processing, to: input)
        // Voice processing can replace the underlying IO unit. Rebind before reading its format.
        input = engine.inputNode
        let selectedDevice = try InputDeviceRouting.apply(uid: inputDeviceUID, to: input, resolve: AudioInputDevices.deviceID(forUID:))
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
                // Refuse audio if hardware disappeared or the engine switched routes before its
                // configuration-change callback reached us. Never emit fallback-device samples.
                do {
                    if let inputDeviceUID, AudioInputDevices.deviceID(forUID: inputDeviceUID) != selectedDevice {
                        throw MicrophoneError.noInputDevice
                    }
                    try InputDeviceRouting.verify(expected: selectedDevice, on: engine.inputNode)
                } catch { fail(error); return }
                let chunks = tap.append(samples, resumedAt: resumedAt, tracker: &gapTracker)
                for chunk in chunks { continuation.yield(.chunk(chunk)) }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            throw classifyStartError(error.localizedDescription)
        }
        try InputDeviceRouting.verify(expected: selectedDevice, on: engine.inputNode)
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
        do {
            try installTapAndRun(generation: resumeToken)
            let name = if let inputDeviceUID {
                AudioInputDevices.available().first { $0.id == inputDeviceUID }?.name
            } else {
                AudioInputDevices.defaultDevice()?.name
            }
            continuation.yield(.deviceChanged(name: name))
        } catch { fail(error) }
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
        deviceChanges?.cancel(); deviceChanges = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Disabling the stopped voice-processing IO also releases its output attenuation.
        try? VoiceProcessingConfiguration.apply(.init(), to: engine.inputNode)
        onStopped()
    }
}
