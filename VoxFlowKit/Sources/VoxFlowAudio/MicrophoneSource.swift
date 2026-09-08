@preconcurrency import AVFoundation
import Foundation
import Synchronization
import VoxFlowCore

/// `AVAudioEngine` input tap → 16 kHz mono chunks with RMS (design §4 `MicrophoneSource`, ST-04n, FB-07).
public final class MicrophoneSource: MicrophoneCapturing, Sendable {
    private let chunkSeconds: Double

    public init(chunkSeconds: Double = 0.1) { self.chunkSeconds = chunkSeconds }

    public func start() -> AsyncThrowingStream<MicrophoneEvent, Error> {
        AsyncThrowingStream { continuation in
            let session = CaptureSession(chunkSeconds: chunkSeconds, continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }
}

/// Everything AVFoundation-side for one capture. All members are touched only on `queue` (setup, restart, stop)
/// or inside the tap block, which AVAudioEngine serialises on its own render thread — the same confinement
/// argument as `ContextBox` in `WhisperCppEngine`; hence the one permitted `@unchecked Sendable`.
///
/// One handoff is narrower than that confinement claim: `restart()` calls `removeTap` and then
/// `installTapAndRun()` reassigns `chunker` on `queue`, but a tap callback already in flight when
/// `removeTap` runs is still executing concurrently on the render thread and may still be reading the
/// old `chunker` — `removeTap` does not join it. The window is tiny (only opens on a device switch)
/// and the in-flight callback always finishes against the *old* chunker's state, never a torn one, so
/// nothing is corrupted — but it means "touched only on `queue` or inside the tap block" is not quite
/// "never touched from two places at once" across a `restart()`.
private final class CaptureSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.microphone")
    private let engine = AVAudioEngine()
    private let chunkSeconds: Double
    private let continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation
    private var observer: NSObjectProtocol?
    private var stopped = false
    private var chunker: AudioChunker

    init(chunkSeconds: Double, continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation) {
        self.chunkSeconds = chunkSeconds
        self.continuation = continuation
        self.chunker = AudioChunker(seconds: chunkSeconds)
    }

    func start() {
        queue.async { [self] in
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.restart() }
            }
            do { try installTapAndRun() } catch { fail(error) }
        }
    }

    private func installTapAndRun() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { throw MicrophoneError.noInputDevice }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioSamples.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else { throw MicrophoneError.engineFailed("no converter \(inputFormat) → 16 kHz mono") }
        chunker = AudioChunker(seconds: chunkSeconds)
        let continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [self] buffer, _ in
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
            for chunk in chunker.append(samples) { continuation.yield(.chunk(chunk)) }
        }
        engine.prepare()
        do { try engine.start() } catch { throw MicrophoneError.engineFailed(error.localizedDescription) }
    }

    private func restart() {
        guard !stopped else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { fail(MicrophoneError.noInputDevice); return }
        continuation.yield(.deviceChanged(name: AVCaptureDevice.default(for: .audio)?.localizedName))
        do { try installTapAndRun() } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        stopInternal()
        continuation.finish(throwing: (error as? MicrophoneError) ?? MicrophoneError.engineFailed(String(describing: error)))
    }

    func stop() { queue.async { [self] in stopInternal() } }

    private func stopInternal() {
        guard !stopped else { return }
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
